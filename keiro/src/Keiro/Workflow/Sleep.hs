{- | Durable @sleep@ for workflows, backed by the existing @keiro_timers@ table.

== What this gives you

A workflow author can insert a durable pause between steps:

@
demo :: ('Workflow' ':>' es, 'Store' ':>' es, IOE ':>' es) => Eff es (Int, Int)
demo = do
  a <- 'step' (StepName \"a\") (liftIO incr)   -- side effect #1
  'sleepNamed' (StepName \"cool\") 300          -- durable wait, survives a restart
  b <- 'step' (StepName \"b\") (liftIO incr)   -- side effect #2
  pure (a, b)
@

On the __first__ run, @demo@ executes @a@, journals it, arms a Postgres timer
for the sleep, and __suspends__ — 'Keiro.Workflow.runWorkflow' returns
'Suspended' and the journal @wf:demo-\<id\>@ holds only the @StepRecorded \"a\"@
event. The @b@ side effect has not run. The process can now crash, be
redeployed, or sit idle for the full delay: the only durable state of the pause
is a single row in 'keiro_timers', so the wait survives a restart with __no
external scheduler and no in-memory timer thread__.

When the timer becomes due, the existing timer worker
('Keiro.Timer.runTimerWorker') fires it through 'workflowSleepFireAction',
which recognises the row as a workflow sleep (by the JSON payload
discriminator), reconstructs the journal stream, and appends a
@StepRecorded \"sleep:cool\"@ completion. A later run replays: @step \"a\"@
short-circuits to its recorded result, @sleepNamed \"cool\"@ sees its completion
already journaled and returns immediately, and only @step \"b\"@ runs for real.

== 'sleepNamed' vs. 'sleep'

* 'sleepNamed' is the __stable primitive__. Replay matches the sleep on its
  (prefixed) 'StepName', so the name must be deterministic across replays. A
  user-supplied name is unconditionally stable: the same source always produces
  the same name regardless of how surrounding code is reordered between deploys.

* 'sleep' is an ordinal convenience built on 'sleepNamed' via
  'Keiro.Workflow.freshOrdinal' (the @N@th sleep in a run gets @sleep:N@). Its
  determinism is __conditional__: reordering or inserting sleeps between deploys
  shifts the ordinals and can make a resumed in-flight workflow re-arm a
  /different/ timer. Prefer 'sleepNamed' for anything that must survive a code
  change mid-flight.

== Operational contract

* __Payload discriminator.__ A workflow-sleep timer row carries
  @{\"kind\":\"keiro.workflow.sleep\",\"step\":\"sleep:\<suffix\>\"}@ in its
  @payload@ (see 'sleepTimerPayload' / 'parseSleepPayload'). This is how a
  single timer worker distinguishes workflow sleeps from ordinary
  process-manager timers and routes each correctly.

* __Deterministic timer id.__ The timer id is a v5 UUID over
  @(\"keiro\":\"workflow-sleep\":name:id:sleepStepName)@ ('sleepTimerId'),
  mirroring 'Keiro.ProcessManager.deterministicCommandId'. Because
  'Keiro.Timer.scheduleTimerTx' re-arms only a still-@Scheduled@ row, every
  resume that re-enters the not-yet-resolved sleep re-arms the same id and
  collapses to a no-op — exactly the idempotent arming
  'Keiro.Workflow.awaitStep' requires.

* __No @keiro_timers@ schema change.__ Routing is entirely a function of the
  caller-supplied fire action and the JSON payload; this module owns no
  migration.

* __A worker must drain the timers.__ A sleep only ever fires if some timer
  worker runs 'workflowSleepFireAction' (via 'runWorkflowTimerWorker', or by
  passing 'workflowSleepFireAction' directly to 'Keiro.Timer.runTimerWorker').
  A sleep whose timer is never drained — or one whose timer an operator
  'Keiro.Timer.cancelTimer's — stays suspended forever until an operator
  intervenes. Workflow sleeps otherwise inherit the timer subsystem's recovery
  surface ('Keiro.Timer.findStuckTimers' / 'Keiro.Timer.requeueStuckTimer' /
  'Keiro.Timer.deadLetterTimer') for free.
-}
module Keiro.Workflow.Sleep
  ( -- * Authoring surface
    sleepNamed
  , sleep

    -- * Firing and worker wiring
  , workflowSleepFireAction
  , runWorkflowTimerWorker

    -- * Timer id, payload, and step-name helpers
  , sleepTimerId
  , sleepStepName
  , sleepTimerPayload
  , parseSleepPayload
  , workflowSleepKind
  )
where

import Data.Aeson (Value (..), object)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, addUTCTime)
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, (:>))
import Keiro.Prelude
import Keiro.Telemetry (KeiroMetrics)
import Keiro.Timer
  ( TimerId (..)
  , TimerRequest (..)
  , TimerRow
  , runTimerWorker
  , scheduleTimerTx
  )
import Keiro.Workflow
  ( StepName (..)
  , Workflow
  , WorkflowId (..)
  , WorkflowJournalEvent (..)
  , WorkflowName (..)
  , appendJournalEntryReturningId
  , awaitStep
  , currentWorkflow
  , freshOrdinal
  , sleepStepPrefix
  )
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId)

-- ---------------------------------------------------------------------------
-- Discriminator and payload
-- ---------------------------------------------------------------------------

{- | The payload @"kind"@ tag that marks a 'keiro_timers' row as a workflow
sleep, distinguishing it from an ordinary process-manager timer so a single
timer worker can route each correctly.
-}
workflowSleepKind :: Text
workflowSleepKind = "keiro.workflow.sleep"

{- | Build the JSON payload carried on a workflow-sleep timer row. The argument
is the full @"sleep:\<suffix\>"@ journal step name the firing will record.
-}
sleepTimerPayload :: Text -> Value
sleepTimerPayload fullStep =
  object ["kind" Aeson..= workflowSleepKind, "step" Aeson..= fullStep]

{- | Recognise and extract a workflow-sleep payload: @Just fullStep@ for a
payload this module wrote, 'Nothing' for any other timer (e.g. a process
manager's). The full step name returned is what the fire action journals.
-}
parseSleepPayload :: Value -> Maybe Text
parseSleepPayload = \case
  Object o
    | KeyMap.lookup "kind" o == Just (String workflowSleepKind) ->
        case KeyMap.lookup "step" o of
          Just (String s) -> Just s
          _ -> Nothing
  _ -> Nothing

-- ---------------------------------------------------------------------------
-- Deterministic ids and step names
-- ---------------------------------------------------------------------------

{- | The deterministic timer id for a sleep: a v5 UUID over
@(\"keiro\":\"workflow-sleep\":name:id:fullStep)@. Stable across replays, so
re-arming the same sleep on every resume is an idempotent upsert. The step name
is part of the key so two distinct sleeps in one workflow get distinct timers.
-}
sleepTimerId :: WorkflowName -> WorkflowId -> Text -> TimerId
sleepTimerId name wid fullStep =
  TimerId $
    UUID.V5.generateNamed UUID.V5.namespaceURL $
      fmap (fromIntegral . fromEnum) $
        Text.unpack $
          Text.intercalate
            ":"
            [ "keiro"
            , "workflow-sleep"
            , unWorkflowName name
            , unWorkflowId wid
            , fullStep
            ]

{- | The durable journal step name for a sleep: the user's suffix prefixed with
'sleepStepPrefix'. @'sleepStepName' (StepName \"cool\") == \"sleep:cool\"@. The
prefix keeps the journal self-describing — an operator scanning it sees
@sleep:@ and knows the entry is a durable wait, not an ordinary step.
-}
sleepStepName :: StepName -> Text
sleepStepName (StepName suffix) = sleepStepPrefix <> suffix

-- ---------------------------------------------------------------------------
-- Authoring surface
-- ---------------------------------------------------------------------------

{- | 'awaitStep' specialised to a 'Value' result. The recorded sleep completion
carries JSON @null@; 'Value''s 'FromJSON' is the identity, so any recorded
result decodes, which decouples the sleep from a @FromJSON ()@ instance.
-}
awaitValue :: (Workflow :> es) => StepName -> Eff es () -> Eff es Value
awaitValue = awaitStep

{- | Durably pause the workflow for @delta@ under the stable name @userStep@.
On the first encounter this arms a deterministic 'keiro_timers' row and
suspends the run; the suspension resolves when a timer worker fires the row
(see 'workflowSleepFireAction') and journals the sleep's completion, after which
a later run replays past the sleep without re-arming.

The arming action is idempotent (a resumed workflow re-runs it until the sleep
resolves): it upserts on a deterministic 'sleepTimerId', and
'scheduleTimerTx' re-arms only a still-@Scheduled@ row.
-}
sleepNamed ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  StepName ->
  NominalDiffTime ->
  Eff es ()
sleepNamed userStep delta = do
  (name, wid) <- currentWorkflow
  let full = sleepStepName userStep
      armedStep = StepName full
  void . awaitValue armedStep $ do
    now <- liftIO getCurrentTime
    let request =
          TimerRequest
            { timerId = sleepTimerId name wid full
            , processManagerName = unWorkflowName name
            , correlationId = unWorkflowId wid
            , fireAt = addUTCTime delta now
            , payload = sleepTimerPayload full
            }
    runTransaction (scheduleTimerTx request)

{- | Durably pause the workflow for @delta@ under an ordinal name (the @N@th
sleep in a run becomes @sleep:N@). Convenient but its determinism is
conditional — see the module header. Prefer 'sleepNamed' for anything that must
survive a code change mid-flight.
-}
sleep :: (Workflow :> es, Store :> es, IOE :> es) => NominalDiffTime -> Eff es ()
sleep delta = do
  n <- freshOrdinal "sleep"
  sleepNamed (StepName (Text.pack (show n))) delta

-- ---------------------------------------------------------------------------
-- Firing and worker wiring
-- ---------------------------------------------------------------------------

{- | The fire action for workflow-sleep timers. For a 'TimerRow' whose payload
is a workflow-sleep discriminator, reconstruct the workflow identity from the
row's @processManagerName@ (= workflow name) and @correlationId@ (= workflow
id), append a @StepRecorded@ completion (@result = null@) to the workflow's
journal via 'appendJournalEntryReturningId', and return the appended 'EventId'
so the worker marks the timer @Fired@. Returns 'Nothing' for a row whose
payload is __not__ a workflow sleep, so a mixed worker can delegate that row to
its process-manager fire action.

Idempotent: 'appendJournalEntryReturningId' pre-checks the step and returns the
same deterministic id on a re-fire, so at-least-once timer firing yields
exactly-once journaling.
-}
workflowSleepFireAction ::
  (Store :> es, IOE :> es) => TimerRow -> Eff es (Maybe EventId)
workflowSleepFireAction row =
  case parseSleepPayload (row ^. #payload) of
    Nothing -> pure Nothing
    Just full -> do
      now <- liftIO getCurrentTime
      let name = WorkflowName (row ^. #processManagerName)
          wid = WorkflowId (row ^. #correlationId)
      eid <-
        appendJournalEntryReturningId
          name
          wid
          (StepRecorded {stepName = full, result = Null, recordedAt = now})
      pure (Just eid)

{- | A timer worker pass that handles __both__ workflow-sleep timers and
ordinary process-manager timers. For each claimed timer: if its payload is a
workflow sleep, wake the workflow; otherwise delegate to the supplied
process-manager fire action.

A deployment that runs only workflows can pass @\\_ -> pure Nothing@ as the
fallback (or use 'workflowSleepFireAction' directly with
'Keiro.Timer.runTimerWorker'). A deployment that mixes process-manager timers
and workflow sleeps passes its existing PM fire action so one worker drains
both kinds.
-}
runWorkflowTimerWorker ::
  (IOE :> es, Store :> es) =>
  Maybe KeiroMetrics ->
  UTCTime ->
  -- | Fallback fire action for non-sleep (process-manager) timers.
  (TimerRow -> Eff es (Maybe EventId)) ->
  Eff es (Maybe TimerRow)
runWorkflowTimerWorker metrics now pmFire =
  runTimerWorker metrics now $ \row -> do
    handled <- workflowSleepFireAction row
    case handled of
      Just eid -> pure (Just eid)
      Nothing -> pmFire row
