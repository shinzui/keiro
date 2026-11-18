{-# LANGUAGE OverloadedStrings #-}

-- | Executed rollout proof for ExecPlan 345, Milestone 5.
--
-- @Before@ and @After@ are the generated modules of
-- @test/fixtures/contract-rollout-before.keiro@ and
-- @test/fixtures/contract-rollout-after.keiro@, compiled into one program under
-- distinct module roots.  For each direction of each change the program runs
-- the old encoder against the new decoder and the new encoder against the old
-- decoder, then checks that the rollout @keiro-dsl diff@ reports for the same
-- pair of sources is the one that behaviour requires.  A reversed rollout
-- verdict therefore fails here even if the unit tests are edited to match it.
module Main (main) where

import After.Generated.ContractRollout.Growth.Contract qualified as AfterGrowth
import After.Generated.ContractRollout.Origin.Contract qualified as AfterOrigin
import After.Generated.ContractRollout.Presence.Contract qualified as AfterPresence
import Before.Generated.ContractRollout.Growth.Contract qualified as BeforeGrowth
import Before.Generated.ContractRollout.Origin.Contract qualified as BeforeOrigin
import Before.Generated.ContractRollout.Presence.Contract qualified as BeforePresence
import Data.Either (isLeft, isRight)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Keiro.Dsl.Diff (Change (..), ChangeKind (..), CompatibilityVector (..), RolloutConstraint (..), diffSources)
import Keiro.Dsl.LanguageVersion (renderParseFailure)
import Keiro.Dsl.Parser (parseSource)
import Keiro.Dsl.Validate (DiagnosticCode (..))
import System.Exit (exitFailure)

-- | What running both generated versions shows for one direction of change.
data Observed = Observed
  { -- | A still-running old consumer decodes what the new producer writes.
    oldReadsNew :: !Bool,
    -- | The new consumer decodes what a still-running old producer wrote.
    newReadsOld :: !Bool
  }
  deriving stock (Show)

-- | Whether a reported rollout is the one the observed behaviour requires.
--
-- * @producer-first@ is safe only when old consumers read the new output, and
--   it is required (with @drain-required@) when the new consumer rejects the
--   old output.
-- * @producer-last@ is safe only when the new consumer reads the old output,
--   and it is required when old consumers reject the new output.
rolloutMatches :: Observed -> Set RolloutConstraint -> Bool
rolloutMatches observed rollout =
  (not (has RolloutProducerFirst) || observed.oldReadsNew)
    && (not (has RolloutProducerLast) || observed.newReadsOld)
    && (observed.newReadsOld || (has RolloutProducerFirst && has RolloutDrainRequired))
    && (observed.oldReadsNew || has RolloutProducerLast)
  where
    has = (`Set.member` rollout)

-- Presence: Before declares `note: Optional text`, After declares `note: text`.

presenceBefore :: Maybe Text -> BeforePresence.PresencePayload
presenceBefore note = BeforePresence.Noted (BeforePresence.NotedData "subject-1" note)

presenceAfter :: AfterPresence.PresencePayload
presenceAfter = AfterPresence.Noted (AfterPresence.NotedData "subject-1" "a note")

-- Forward reads old = Before, new = After; backward reads old = After,
-- new = Before.
presenceForward, presenceBackward :: Observed
presenceForward =
  Observed
    { oldReadsNew = isRight (BeforePresence.parsePresencePayload (AfterPresence.encodePresencePayload presenceAfter)),
      newReadsOld = isRight (AfterPresence.parsePresencePayload (BeforePresence.encodePresencePayload (presenceBefore Nothing)))
    }
presenceBackward =
  Observed
    { oldReadsNew = isRight (AfterPresence.parsePresencePayload (BeforePresence.encodePresencePayload (presenceBefore Nothing))),
      newReadsOld = isRight (BeforePresence.parsePresencePayload (AfterPresence.encodePresencePayload presenceAfter))
    }

-- Origin: Before takes the event type from the envelope, After from a
-- messageType body key.

originBefore :: BeforeOrigin.OriginPayload
originBefore = BeforeOrigin.Signaled (BeforeOrigin.SignaledData "subject-1")

originAfter :: AfterOrigin.OriginPayload
originAfter = AfterOrigin.Signaled (AfterOrigin.SignaledData "subject-1")

-- The envelope always carries the event type the producer derived from
-- messageTypeOf, whichever version wrote the body.
readOriginBefore :: Text -> AfterOrigin.OriginPayload -> Bool
readOriginBefore eventType payload = isRight (BeforeOrigin.parseOriginPayloadAs eventType (AfterOrigin.encodeOriginPayload payload))

originForward, originBackward :: Observed
originForward =
  Observed
    { oldReadsNew = readOriginBefore (AfterOrigin.messageTypeOf originAfter) originAfter,
      newReadsOld = isRight (AfterOrigin.parseOriginPayload (BeforeOrigin.encodeOriginPayload originBefore))
    }
originBackward =
  Observed
    { oldReadsNew = isRight (AfterOrigin.parseOriginPayload (BeforeOrigin.encodeOriginPayload originBefore)),
      newReadsOld = readOriginBefore (AfterOrigin.messageTypeOf originAfter) originAfter
    }

-- Growth: After adds `reason: Optional text`.

growthBefore :: BeforeGrowth.GrowthPayload
growthBefore = BeforeGrowth.Grown (BeforeGrowth.GrownData "subject-1")

growthAfter :: Maybe Text -> AfterGrowth.GrowthPayload
growthAfter reason = AfterGrowth.Grown (AfterGrowth.GrownData "subject-1" reason)

growthForward, growthBackward :: Observed
growthForward =
  Observed
    { oldReadsNew = isRight (BeforeGrowth.parseGrowthPayload (AfterGrowth.encodeGrowthPayload (growthAfter (Just "a reason")))),
      newReadsOld = AfterGrowth.parseGrowthPayload (BeforeGrowth.encodeGrowthPayload growthBefore) == Right (growthAfter Nothing)
    }
growthBackward =
  Observed
    { oldReadsNew = AfterGrowth.parseGrowthPayload (BeforeGrowth.encodeGrowthPayload growthBefore) == Right (growthAfter Nothing),
      newReadsOld = isRight (BeforeGrowth.parseGrowthPayload (AfterGrowth.encodeGrowthPayload (growthAfter (Just "a reason"))))
    }

changeKindOf :: Change -> ChangeKind
changeKindOf (Additive kind) = kind
changeKindOf (Advisory kind) = kind
changeKindOf (Breaking kind) = kind

-- | The rollout `keiro-dsl diff` reports for the one finding with this code
-- on this contract, or 'Nothing' when there is not exactly one.
reportedRollout :: [Change] -> Text -> DiagnosticCode -> Maybe (Set RolloutConstraint)
reportedRollout changes contract code =
  case [kind | kind <- map changeKindOf changes, kind.node == contract, kind.code == code] of
    [kind] -> Just kind.vector.rollout
    _ -> Nothing

loadDiff :: FilePath -> FilePath -> IO [Change]
loadDiff oldPath newPath = do
  old <- parsed oldPath
  new <- parsed newPath
  either (fail . show) pure (diffSources old new)
  where
    parsed path = do
      source <- TIO.readFile path
      either (fail . T.unpack . renderParseFailure) pure (parseSource path source)

main :: IO ()
main = do
  let beforePath = "test/fixtures/contract-rollout-before.keiro"
      afterPath = "test/fixtures/contract-rollout-after.keiro"
  forward <- loadDiff beforePath afterPath
  backward <- loadDiff afterPath beforePath
  let verdict changes contract code observed = maybe False (rolloutMatches observed) (reportedRollout changes contract code)
      checks =
        [ -- Optional to required: producer-first, drain-required.
          ("optional to required: the old consumer reads the new producer's message", presenceForward.oldReadsNew),
          ("optional to required: the new consumer rejects an old message that omits the key", not presenceForward.newReadsOld),
          ("optional to required: the new consumer rejects it naming the key", either ("note" `T.isInfixOf`) (const False) (AfterPresence.parsePresencePayload (BeforePresence.encodePresencePayload (presenceBefore Nothing)))),
          ("optional to required: diff reports the rollout the behaviour requires", verdict forward "presence" ContractFieldChanged presenceForward),
          -- Required to optional: producer-last.
          ("required to optional: the new consumer reads the old producer's message", presenceBackward.newReadsOld),
          ("required to optional: the old consumer rejects a new message that omits the key", not presenceBackward.oldReadsNew),
          ("required to optional: diff reports the rollout the behaviour requires", verdict backward "presence" ContractFieldChanged presenceBackward),
          -- Envelope to body key: producer-first, drain-required.
          ("envelope to body key: the old consumer reads the new producer's message", originForward.oldReadsNew),
          ("envelope to body key: the new consumer rejects an old message without the key", not originForward.newReadsOld),
          ("envelope to body key: diff reports the rollout the behaviour requires", verdict forward "origin" ContractDiscriminatorChanged originForward),
          -- Body key to envelope: producer-last.
          ("body key to envelope: the new consumer reads the old producer's message", originBackward.newReadsOld),
          ("body key to envelope: the old consumer rejects a new message without the key", not originBackward.oldReadsNew),
          ("body key to envelope: diff reports the rollout the behaviour requires", verdict backward "origin" ContractDiscriminatorChanged originBackward),
          -- Added optional field: any order.
          ("optional field added: the old consumer reads a new message carrying the key", growthForward.oldReadsNew),
          ("optional field added: the new consumer reads an old message as Nothing", growthForward.newReadsOld),
          ("optional field added: diff reports no rollout constraint", reportedRollout forward "growth" ContractOptionalFieldAdded == Just Set.empty),
          ("optional field removed: diff reports a rollout the behaviour admits", verdict backward "growth" ContractFieldChanged growthBackward),
          -- The checks above are meaningful only if a reversed verdict fails them.
          ("a reversed verdict is detected", not (rolloutMatches presenceForward (Set.singleton RolloutProducerLast)) && not (rolloutMatches presenceBackward (Set.fromList [RolloutDrainRequired, RolloutProducerFirst]))),
          ("an absent body key is rejected, not defaulted", isLeft (AfterOrigin.parseOriginPayload (BeforeOrigin.encodeOriginPayload originBefore)))
        ]
  mapM_ (\(label, ok) -> putStrLn ((if ok then "PASS  " else "FAIL  ") <> label)) checks
  if all snd checks then pure () else exitFailure
