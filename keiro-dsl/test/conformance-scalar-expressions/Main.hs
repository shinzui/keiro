{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Control.Monad (forM, forM_, unless)
import Data.Text qualified as T
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), secondsToDiffTime)
import AggregateScalarExpressions.ScalarAccount.BehaviorHoles (behaviorWitnesses)
import Generated.AggregateScalarExpressions.ScalarAccount.BehaviorContract qualified as Behavior
import Generated.AggregateScalarExpressions.ScalarAccount.Codec (encodeScalarAccountEvent, parseScalarAccountEvent, scalarAccountCodec)
import Generated.AggregateScalarExpressions.ScalarAccount.Domain
import Generated.AggregateScalarExpressions.ScalarAccount.EventStream (scalarAccountEventStreamDef)
import Generated.AggregateScalarExpressions.ScalarAccount.Harness (harnessAssertions)
import Generated.AggregateScalarExpressions.ScalarAccount.Transducer
import Generated.AggregateScalarExpressions.StructuralProjections qualified as StructuralProjections
import Keiki.Core qualified as K
import Keiki.Generics (RegFieldsOf)
import Keiki.Symbolic qualified as S
import Keiro.Codec (eventType)
import Keiro.EventStream (EventStream (..), StateCodec (..))
import Keiro.Snapshot.Codec (defaultStateCodec, withFoldFingerprint)
import Numeric.Natural (Natural)
import ScalarExpressions.Domain qualified as Domain
import System.Exit (exitFailure)

main :: IO ()
main = do
  arithmeticAgreement <- scalarArithmeticAgreement
  repeatedPathAgreement <- repeatedPathUsesOneSymbol
  verificationReport <- scalarAccountPredicateVerifications
  let behaviorReport = Behavior.behaviorCoverageReport behaviorWitnesses
  let checks =
        harnessAssertions
          <> [ ("finite scalar oracle agrees with generated execution", finiteOracleAgreement)
             , ("Natural 2 - 5 is total monus zero", naturalMonusExample)
             , ("Integer/Natural oracle, concrete terms, and symbolic formulas agree", arithmeticAgreement)
             , ("one-way projected scalar paths remain conservatively unverified", repeatedPathAgreement)
             , ("one-way generated projection and opaque Hole remain unverified", verificationReport == expectedVerificationReport)
             , ("Keiki 0.7 detailed step and replay attribute the generated edge", detailedAttributionAgreement)
             , ("generated behavior contract reconciles its create-once pending rows", length (Behavior.reportPending behaviorReport) == 6 && null (Behavior.reportMissing behaviorReport))
             , ("Hole envelope preserves declared event and target", holeEnvelopeAgreement)
             , ("encoded replay and full replay after snapshot invalidation agree", fullReplayAgreement)
             , ("Hole fold version participates in snapshot identity", snapshotFingerprintAgreement)
             ]
  forM_ checks $ \(label, passed) ->
    putStrLn ((if passed then "PASS  " else "FAIL  ") <> label)
  unless (all snd checks) exitFailure

expectedVerificationReport :: [(T.Text, BehaviorOwnership, S.PredicateVerification)]
expectedVerificationReport =
  [ ("transition1OpenAdjust", GeneratedOwned, S.UnverifiedOpaque)
  , ("transition2ReviewedClose", HoleOwned, S.UnverifiedOpaque)
  ]

initialTime :: UTCTime
initialTime = UTCTime (fromGregorian 2026 1 1) 0

writtenTime :: UTCTime
writtenTime = UTCTime (fromGregorian 2026 2 3) (secondsToDiffTime 14706)

commandTime :: UTCTime
commandTime = UTCTime (fromGregorian 2026 1 2) (secondsToDiffTime 17)

mkAdjust :: Integer -> Natural -> Bool -> UTCTime -> Integer -> ScalarAccountCommand
mkAdjust balanceValue requestedValue activeValue observedAtValue minimumValue =
  Adjust
    AdjustData
      { balance = balanceValue
      , requested = requestedValue
      , machine = 41
      , label = "input-label"
      , active = activeValue
      , mode = Normal
      , requestId = RequestId "req_input"
      , observedAt = observedAtValue
      , limits = Domain.Limits minimumValue 13
      }

oracleAccepts :: Integer -> Natural -> Bool -> UTCTime -> Integer -> Bool
oracleAccepts balanceValue requestedValue activeValue observedAtValue minimumValue =
  balanceValue >= (-100)
    && requestedValue <= 5
    && observedAtValue >= initialTime
    && minimumValue >= 0
    && not activeValue

finiteOracleAgreement :: Bool
finiteOracleAgreement =
  and
    [ caseAgrees balanceValue requestedValue activeValue observedAtValue minimumValue
    | balanceValue <- [-101, -100, -1, 0, 50]
    , requestedValue <- [0, 2, 5, 6]
    , activeValue <- [False, True]
    , observedAtValue <- [UTCTime (fromGregorian 2025 12 31) 0, initialTime, commandTime]
    , minimumValue <- [-1, 0, 2]
    ]

caseAgrees :: Integer -> Natural -> Bool -> UTCTime -> Integer -> Bool
caseAgrees balanceValue requestedValue activeValue observedAtValue minimumValue =
  case K.step scalarAccountTransducer (ScalarAccountOpen, initialScalarAccountRegs) command of
    Nothing -> not accepted
    Just (vertex, registers, events) ->
      accepted
        && vertex == ScalarAccountReviewed
        && registers K.! #balance == balanceValue * 2
        && registers K.! #reserved == naturalMonus requestedValue 5
        && registers K.! #capacity == 5
        && registers K.! #machine == (-7)
        && registers K.! #label == "adjusted"
        && registers K.! #active
        && registers K.! #mode == Restricted
        && registers K.! #requestId == RequestId "req_00041061050r3gg28a1c60t3gf"
        && registers K.! #openedAt == writtenTime
        && registers K.! #limits == Domain.Limits minimumValue 13
        && events == expectedEvents
 where
  accepted = oracleAccepts balanceValue requestedValue activeValue observedAtValue minimumValue
  command = mkAdjust balanceValue requestedValue activeValue observedAtValue minimumValue
  expectedEvents =
    [ Adjusted
        AdjustedData
          { balance = balanceValue
          , requested = requestedValue
          , machine = 41
          , label = "input-label"
          , active = activeValue
          , mode = Normal
          , requestId = RequestId "req_input"
          , observedAt = observedAtValue
          , limits = Domain.Limits minimumValue 13
          }
    ]

naturalMonus :: Natural -> Natural -> Natural
naturalMonus left right
  | left >= right = left - right
  | otherwise = 0

naturalMonusExample :: Bool
naturalMonusExample =
  case K.step scalarAccountTransducer (ScalarAccountOpen, initialScalarAccountRegs) (mkAdjust 0 2 False commandTime 0) of
    Just (_, registers, _) -> registers K.! #reserved == 0
    Nothing -> False

scalarArithmeticAgreement :: IO Bool
scalarArithmeticAgreement = do
  integerResults <- forM [(left, right) | left <- [-4 .. 4], right <- [-4 .. 4]] $ \(left, right) -> do
    let terms =
          [ (K.tadd (K.lit left) (K.lit right) :: K.Term '[] () '[] Integer, left + right)
          , (K.tsub (K.lit left) (K.lit right), left - right)
          , (K.tmul (K.lit left) (K.lit right), left * right)
          ]
        concrete = all (\(term, expected) -> K.evalTerm term K.RNil () == expected) terms
    symbolic <- forM terms $ \(term, expected) ->
      S.verifyPredicate (K.PEq term (K.lit expected) :: K.HsPred '[] ())
    pure (concrete && all (== S.VerifiedSatisfiable) symbolic)
  naturalResults <- forM [(left, right) | left <- [0 .. 8], right <- [0 .. 8]] $ \(left, right) -> do
    let terms =
          [ (K.tadd (K.lit left) (K.lit right) :: K.Term '[] () '[] Natural, left + right)
          , (K.tsub (K.lit left) (K.lit right), naturalMonus left right)
          , (K.tmul (K.lit left) (K.lit right), left * right)
          ]
        concrete = all (\(term, expected) -> K.evalTerm term K.RNil () == expected) terms
    symbolic <- forM terms $ \(term, expected) ->
      S.verifyPredicate (K.PEq term (K.lit expected) :: K.HsPred '[] ())
    pure (concrete && all (== S.VerifiedSatisfiable) symbolic)
  pure (and integerResults && and naturalResults)

repeatedPathUsesOneSymbol :: IO Bool
repeatedPathUsesOneSymbol = do
  let projected :: K.Term ScalarAccountRegs ScalarAccountCommand (RegFieldsOf AdjustData) Integer
      projected =
        K.inpProj
          StructuralProjections.structuralProjectionC4cZC69ZC6dZC69ZC74ZC73ZC2fZC6dZC69ZC6eZC69ZC6dZC75ZC6dZWitness
          inCtorAdjust
          (#limits :: K.Index (RegFieldsOf AdjustData) Domain.Limits)
      contradiction :: K.HsPred ScalarAccountRegs ScalarAccountCommand
      contradiction = K.PAnd (K.PCmp K.CmpGe projected (K.lit 1)) (K.PCmp K.CmpLt projected (K.lit 1))
  (== S.UnverifiedOpaque) <$> S.verifyPredicate contradiction

holeEnvelopeAgreement :: Bool
holeEnvelopeAgreement =
  case K.step scalarAccountTransducer (ScalarAccountOpen, initialScalarAccountRegs) (mkAdjust 1 2 False commandTime 0) of
    Nothing -> False
    Just (reviewed, registers, _) ->
      case K.step scalarAccountTransducer (reviewed, registers) (Close (CloseData 77)) of
        Just (target, closedRegisters, events) ->
          target == ScalarAccountClosed
            && closedRegisters K.! #balance == registers K.! #balance
            && events == [ClosedEvent (ClosedEventData 77)]
        Nothing -> False

detailedAttributionAgreement :: Bool
detailedAttributionAgreement =
  case K.stepDetailedEither scalarAccountTransducer initialPair adjustCommand of
    Left _ -> False
    Right success ->
      K.stepSuccessEdge success == expectedEdge
        && K.stepSuccessMode success == K.Live
        && K.stepSuccessState success == ScalarAccountReviewed
        && case K.applyEventsDetailedEither scalarAccountTransducer initialPair (K.stepSuccessOutputs success) of
          Left _ -> False
          Right replay ->
            K.replaySuccessState replay == ScalarAccountReviewed
              && K.replaySuccessTrace replay
                == [ K.ReplayAttribution
                       { K.replayAttributionEdge = expectedEdge
                       , K.replayAttributionMode = K.Live
                       , K.replayAttributionSource = ScalarAccountOpen
                       , K.replayAttributionTarget = ScalarAccountReviewed
                       , K.replayAttributionSpan = K.ReplayEventSpan 0 1
                       , K.replayAttributionEventCount = 1
                       }
                   ]
 where
  initialPair = (ScalarAccountOpen, initialScalarAccountRegs)
  adjustCommand = mkAdjust 3 2 False commandTime 1
  expectedEdge = K.EdgeRef ScalarAccountOpen 0

fullReplayAgreement :: Bool
fullReplayAgreement =
  case K.step scalarAccountTransducer initialPair adjustCommand of
    Nothing -> False
    Just (reviewed, adjustedRegisters, adjustedEvents) ->
      case K.step scalarAccountTransducer (reviewed, adjustedRegisters) closeCommand of
        Nothing -> False
        Just (forwardVertex, forwardRegisters, closedEvents) ->
          case traverse codecRoundTrip (adjustedEvents <> closedEvents) of
            Left _ -> False
            Right decodedEvents ->
              case K.applyEventsEither scalarAccountTransducer initialPair decodedEvents of
                Left _ -> False
                Right (replayVertex, replayRegisters) ->
                  replayVertex == forwardVertex
                    && replayRegisters K.! #balance == forwardRegisters K.! #balance
                    && replayRegisters K.! #reserved == forwardRegisters K.! #reserved
                    && replayRegisters K.! #capacity == forwardRegisters K.! #capacity
                    && replayRegisters K.! #machine == forwardRegisters K.! #machine
                    && replayRegisters K.! #label == forwardRegisters K.! #label
                    && replayRegisters K.! #active == forwardRegisters K.! #active
                    && replayRegisters K.! #mode == forwardRegisters K.! #mode
                    && replayRegisters K.! #requestId == forwardRegisters K.! #requestId
                    && replayRegisters K.! #openedAt == forwardRegisters K.! #openedAt
                    && replayRegisters K.! #limits == forwardRegisters K.! #limits
 where
  initialPair = (ScalarAccountOpen, initialScalarAccountRegs)
  adjustCommand = mkAdjust 3 2 False commandTime 1
  closeCommand = Close (CloseData 77)
  codecRoundTrip event =
    parseScalarAccountEvent
      (eventType scalarAccountCodec event)
      (encodeScalarAccountEvent event)

snapshotFingerprintAgreement :: Bool
snapshotFingerprintAgreement =
  case stateCodec scalarAccountEventStreamDef of
    Nothing -> False
    Just currentCodec ->
      let changedCodec :: StateCodec (ScalarAccountVertex, K.RegFile ScalarAccountRegs)
          changedCodec = withFoldFingerprint (scalarAccountFoldFingerprint <> "-mutated") (defaultStateCodec 1)
       in "transition2ReviewedClose-fold-v1" `T.isSuffixOf` scalarAccountFoldFingerprint
            && scalarAccountFoldFingerprint `T.isInfixOf` stateShapeHash currentCodec
            && stateShapeHash currentCodec /= stateShapeHash changedCodec
