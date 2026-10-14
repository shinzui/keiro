{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Control.Monad (foldM, forM_, unless)
import Conformance.MappedRegisterConstruction.Bindings (noTime)
import Conformance.MappedRegisterConstruction.Domain (MaybeTime (..))
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..))
import Generated.MappedRegisterConstruction.Lifecycle.BehaviorContract qualified as Behavior
import Generated.MappedRegisterConstruction.Lifecycle.Codec
import Generated.MappedRegisterConstruction.Lifecycle.Domain
import Generated.MappedRegisterConstruction.Lifecycle.EventStream (lifecycleEventStreamDef)
import Generated.MappedRegisterConstruction.Lifecycle.Harness (harnessAssertions)
import Generated.MappedRegisterConstruction.Lifecycle.Transducer
import Generated.MappedRegisterConstruction.StructuralConformance (structuralConformanceAssertions)
import Keiki.Core qualified as K
import Keiki.Symbolic qualified as S
import Keiro.Codec (eventType)
import Keiro.EventStream (EventStream (..), StateCodec (..))
import Keiro.Snapshot.Codec (defaultStateCodec, withFoldFingerprint)
import MappedRegisterConstruction.Lifecycle.BehaviorHoles (behaviorWitnesses)
import System.Exit (exitFailure)

main :: IO ()
main = do
  verifications <- lifecyclePredicateVerifications
  source <- TIO.readFile "test/conformance-mapped-register-construction/Generated/MappedRegisterConstruction/Lifecycle/Transducer.hs"
  let checks = harnessAssertions
        <> [("structural/" <> label, passed) | (label, passed) <- structuralConformanceAssertions]
        <> [ ("generated guarded initial write selects no timestamp", scenario [(Create (CreateData True), LifecycleAwake, noTime, True)]),
             ("generated mapped lift writes the command timestamp", scenario [(Create (CreateData True), LifecycleAwake, noTime, True), (Mark (MarkData time), LifecycleDormant, MaybeTime (Just time), True)]),
             ("automatic awakening clears the timestamp", automaticPath),
             ("dormant complement retains a freshly lifted timestamp", dormantPath),
             ("explicit awakening and reopening clear the timestamp", explicitPath),
             ("complementary guard verification remains disjoint", null (S.checkTransitionDeterminismSym lifecycleTransducer)),
             ("every predicate retains generated ownership and verification", all (\(_, owner, verdict) -> owner == GeneratedOwned && verdict == S.VerifiedSatisfiable) verifications),
             ("forward, encoded replay, and full replay agree", automaticPath && dormantPath && explicitPath),
             ("all consumer behavior witnesses pass", Behavior.behaviorConformancePassed (Behavior.behaviorCoverageReport behaviorWitnesses)),
             ("lift version participates in fold and snapshot identity", snapshotAgreement),
             ("snapshot codec preserves the complete lifted register file", snapshotRoundTrip),
             ("mapped lift occurs only inside declared register slots", all (\line -> not ("K.TApp1" `T.isInfixOf` line) || "B.slot @\"dormantSince\" =:" `T.isInfixOf` line) (T.lines source))
           ]
  forM_ checks $ \(label, passed) -> putStrLn ((if passed then "PASS  " else "FAIL  ") <> label)
  unless (all snd checks) exitFailure

time :: UTCTime
time = UTCTime (fromGregorian 2026 10 14) 12345

later :: UTCTime
later = UTCTime (fromGregorian 2026 10 15) 9876

initialPair :: (LifecycleVertex, K.RegFile LifecycleRegs)
initialPair = (LifecycleEmpty, initialLifecycleRegs)

observe :: (LifecycleVertex, K.RegFile LifecycleRegs) -> (LifecycleVertex, MaybeTime, Bool)
observe (vertex, registers) = (vertex, registers K.! #dormantSince, registers K.! #automatic)

-- Both registers form the complete file. Compare every prefix to encoded and
-- full replay, so a later clear cannot mask an incorrect earlier lifted write.
scenario :: [(LifecycleCommand, LifecycleVertex, MaybeTime, Bool)] -> Bool
scenario rows = case foldM advance (initialPair, []) rows of
  Nothing -> False
  Just _ -> True
  where
    advance (pair, history) (command, vertex, timestamp, automatic) = do
      (nextVertex, nextRegisters, events) <- K.step lifecycleTransducer pair command
      let next = (nextVertex, nextRegisters)
          allEvents = history <> events
          expected = (vertex, timestamp, automatic)
      decoded <- either (const Nothing) Just (traverse roundTrip allEvents)
      encodedReplay <- either (const Nothing) Just (K.applyEventsEither lifecycleTransducer initialPair decoded)
      fullReplay <- K.reconstitute lifecycleTransducer allEvents
      if observe next == expected && observe encodedReplay == expected && observe fullReplay == expected
        then Just (next, allEvents)
        else Nothing
    roundTrip event = parseLifecycleEvent (eventType lifecycleCodec event) (encodeLifecycleEvent event)

automaticPath :: Bool
automaticPath = scenario
  [ (Create (CreateData True), LifecycleAwake, noTime, True),
    (Mark (MarkData time), LifecycleDormant, MaybeTime (Just time), True),
    (Ping (PingData later), LifecycleAwake, noTime, True)
  ]

dormantPath :: Bool
dormantPath = scenario
  [ (Create (CreateData False), LifecycleAwake, noTime, False),
    (Mark (MarkData time), LifecycleDormant, MaybeTime (Just time), False),
    (Ping (PingData later), LifecycleDormant, MaybeTime (Just later), False)
  ]

explicitPath :: Bool
explicitPath = scenario
  [ (Create (CreateData False), LifecycleAwake, noTime, False),
    (Mark (MarkData time), LifecycleDormant, MaybeTime (Just time), False),
    (Awaken (AwakenData time), LifecycleAwake, noTime, False),
    (Close (CloseData time), LifecycleClosed, noTime, False),
    (Reopen (ReopenData time), LifecycleAwake, noTime, False)
  ]

snapshotAgreement :: Bool
snapshotAgreement = case stateCodec lifecycleEventStreamDef of
  Nothing -> False
  Just current ->
    let changed :: StateCodec (LifecycleVertex, K.RegFile LifecycleRegs)
        changed = withFoldFingerprint (lifecycleFoldFingerprint <> ":lift-version-2") (defaultStateCodec 1)
     in lifecycleFoldFingerprint == "36d736d8808e56273d8ad11b24937942"
          && lifecycleFoldFingerprint `T.isInfixOf` current.stateShapeHash
          && current.stateShapeHash /= changed.stateShapeHash
          && current.shapeHash == changed.shapeHash

snapshotRoundTrip :: Bool
snapshotRoundTrip = case stateCodec lifecycleEventStreamDef of
  Nothing -> False
  Just codec -> case K.step lifecycleTransducer initialPair (Create (CreateData True)) of
    Nothing -> False
    Just (vertex, registers, _) -> case K.step lifecycleTransducer (vertex, registers) (Mark (MarkData time)) of
      Nothing -> False
      Just (target, written, _) ->
        case codec.decode (codec.encode (target, written)) of
          Left _ -> False
          Right decoded -> observe decoded == (LifecycleDormant, MaybeTime (Just time), True)
