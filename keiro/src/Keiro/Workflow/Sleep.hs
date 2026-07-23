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
  @{\"kind\":\"keiro.workflow.sleep\",\"step\":\"sleep:\<suffix\>\",\"gen\":0}@
  in its @payload@ (see 'sleepTimerPayload' / 'parseSleepPayload'). This is how
  a single timer worker distinguishes workflow sleeps from ordinary
  process-manager timers, routes each correctly, and pins a fire to the
  generation that armed it. Legacy payloads without @gen@ remain supported.

* __Deterministic timer id.__ The timer id is a v5 UUID over
  @(\"keiro\":\"workflow-sleep\":name:id:generation:sleepStepName)@ for
  generation 1 and later, while generation 0 keeps the legacy
  @(\"keiro\":\"workflow-sleep\":name:id:sleepStepName)@ shape. The workflow
  sleep arm uses 'Keiro.Timer.scheduleTimerOnceTx', so the first arm's
  @fire_at@ wins and every resume that re-enters the not-yet-resolved sleep
  leaves the row untouched. The sleep duration is measured from the first arm,
  not from the latest resume pass.

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
module Keiro.Workflow.Sleep (
    -- * Authoring surface
    sleepNamed,
    sleep,

    -- * Firing and worker wiring
    workflowSleepFireAction,
    runWorkflowTimerWorker,

    -- * Timer id, payload, and step-name helpers
    sleepTimerId,
    sleepStepName,
    sleepTimerPayload,
    parseSleepPayload,
    matchSleepTimerGeneration,
    workflowSleepKind,
)
where

import Data.Aeson (Value (..), object)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (find)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, addUTCTime)
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, (:>))
import Effectful.Exception (throwIO)
import Keiro.Prelude
import Keiro.Telemetry (KeiroMetrics)
import Keiro.Timer (
    TimerId (..),
    TimerRequest (..),
    TimerRow,
    runTimerWorker,
    scheduleTimerOnceTx,
 )
import Keiro.Workflow (
    JournalAppendOutcome (..),
    StepName (..),
    Workflow,
    WorkflowError (..),
    WorkflowId (..),
    WorkflowJournalEvent (..),
    WorkflowName (..),
    awaitStep,
    currentGeneration,
    currentRunGeneration,
    currentWorkflow,
    deterministicJournalId,
    freshOrdinal,
    prepareJournalAppend,
    setWorkflowWakeAfterTx,
    sleepStepPrefix,
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

{- | Build the JSON payload carried on a workflow-sleep timer row. The first
argument is the generation that armed the timer; the second is the full
@"sleep:\<suffix\>"@ journal step name the firing will record.
-}
sleepTimerPayload :: Int -> Text -> Value
sleepTimerPayload gen fullStep =
    object
        [ "kind" Aeson..= workflowSleepKind
        , "step" Aeson..= fullStep
        , "gen" Aeson..= gen
        ]

{- | Recognise and extract a workflow-sleep payload. The result contains the
full step name and the generation when the payload records one. 'Nothing' in
the generation slot denotes a legacy workflow-sleep payload written before
generation pinning; an overall 'Nothing' denotes any other timer (for example,
a process manager's).
-}
parseSleepPayload :: Value -> Maybe (Text, Maybe Int)
parseSleepPayload = \case
    Object o
        | KeyMap.lookup "kind" o == Just (String workflowSleepKind) ->
            case KeyMap.lookup "step" o of
                Just (String s) ->
                    case KeyMap.lookup "gen" o of
                        Nothing -> Just (s, Nothing)
                        Just value ->
                            case Aeson.fromJSON value of
                                Aeson.Success gen -> Just (s, Just gen)
                                Aeson.Error{} -> Nothing
                _ -> Nothing
    _ -> Nothing

-- ---------------------------------------------------------------------------
-- Deterministic ids and step names
-- ---------------------------------------------------------------------------

{- | The deterministic timer id for a sleep. Generation 0 keeps the legacy v5
UUID over @(\"keiro\":\"workflow-sleep\":name:id:fullStep)@ so in-flight
pre-change timers remain signalable. Generations 1 and later include the
generation component so a sleep after 'Keiro.Workflow.continueAsNew' never
collides with a prior generation's terminal timer row.
-}
sleepTimerId :: WorkflowName -> WorkflowId -> Int -> Text -> TimerId
sleepTimerId name wid gen fullStep =
    TimerId $
        UUID.V5.generateNamed UUID.V5.namespaceURL $
            fmap (fromIntegral . fromEnum) $
                Text.unpack $
                    Text.intercalate
                        ":"
                        components
  where
    components
        | gen <= 0 =
            [ "keiro"
            , "workflow-sleep"
            , unWorkflowName name
            , unWorkflowId wid
            , fullStep
            ]
        | otherwise =
            [ "keiro"
            , "workflow-sleep"
            , unWorkflowName name
            , unWorkflowId wid
            , Text.pack (show gen)
            , fullStep
            ]

{- | Recover the generation represented by a deterministic workflow-sleep
timer id. Candidate generations from @currentGen@ down to zero are tested
against 'sleepTimerId'; this lets a new worker pin legacy payloads that do not
carry an explicit generation. Returns 'Nothing' only for an operator-crafted
or otherwise non-matching timer id.
-}
matchSleepTimerGeneration ::
    WorkflowName ->
    WorkflowId ->
    Int ->
    Text ->
    TimerId ->
    Maybe Int
matchSleepTimerGeneration name wid currentGen fullStep timerId =
    find
        (\gen -> sleepTimerId name wid gen fullStep == timerId)
        (reverse [0 .. max 0 currentGen])

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
resolves): it inserts with a deterministic 'sleepTimerId' only when the row is
absent, so the first @fire_at@ persists across every resume pass.
-}
sleepNamed ::
    (Workflow :> es, Store :> es, IOE :> es) =>
    StepName ->
    NominalDiffTime ->
    Eff es ()
sleepNamed userStep delta = do
    (name, wid) <- currentWorkflow
    gen <- currentRunGeneration
    let full = sleepStepName userStep
        armedStep = StepName full
    void . awaitValue armedStep $ do
        now <- liftIO getCurrentTime
        let request =
                TimerRequest
                    { timerId = sleepTimerId name wid gen full
                    , processManagerName = unWorkflowName name
                    , correlationId = unWorkflowId wid
                    , fireAt = addUTCTime delta now
                    , payload = sleepTimerPayload gen full
                    }
        -- Re-arms can only happen once discovery has found this instance again,
        -- which means any existing wake_after has already self-expired. A later
        -- overwrite is therefore bounded by the requested delay and suppresses
        -- only future not-yet-due resume passes.
        runTransaction (scheduleTimerOnceTx request >> setWorkflowWakeAfterTx name wid (request ^. #fireAt))

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
id), resolve the generation that armed the timer, append a @StepRecorded@
completion (@result = null@) to that generation's journal, and return the
deterministic 'EventId' so the worker marks the timer @Fired@. Returns
'Nothing' for a row whose payload is __not__ a workflow sleep, so a mixed
worker can delegate that row to its process-manager fire action.

Idempotent: 'prepareJournalAppend' pre-checks the generation-scoped step and
the event id is deterministic, so at-least-once timer firing yields
exactly-once journaling even after the workflow has rotated.
-}
workflowSleepFireAction ::
    (Store :> es, IOE :> es) => TimerRow -> Eff es (Maybe EventId)
workflowSleepFireAction row =
    case parseSleepPayload (row ^. #payload) of
        Nothing -> pure Nothing
        Just (full, payloadGen) -> do
            let name = WorkflowName (row ^. #processManagerName)
                wid = WorkflowId (row ^. #correlationId)
            targetGen <-
                case payloadGen of
                    Just gen -> pure gen
                    Nothing -> do
                        currentGen <- currentGeneration name wid
                        pure $
                            fromMaybe
                                currentGen
                                (matchSleepTimerGeneration name wid currentGen full (row ^. #timerId))
            now <- liftIO getCurrentTime
            appendTx <-
                prepareJournalAppend
                    name
                    wid
                    targetGen
                    (StepRecorded{stepName = full, result = Null, recordedAt = now})
            runTransaction appendTx >>= \case
                JournalAppended{} ->
                    pure (Just (deterministicJournalId name wid targetGen full))
                JournalAlreadyPresent{} ->
                    pure (Just (deterministicJournalId name wid targetGen full))
                JournalAppendConflict err ->
                    throwIO (WorkflowJournalAppendError (Text.pack (show err)))

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
