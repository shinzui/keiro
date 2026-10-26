{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}
module Main (main) where

import Conformance.MappedStructuralEnumEquality.Domain
import Control.Monad (forM, forM_, unless)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Maybe (isJust)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Generated.MappedStructuralEnumEquality.ScopeGate.Codec
import Generated.MappedStructuralEnumEquality.ScopeGate.EventStream (scopeGateEventStreamDef)
import Keiro.EventStream qualified as EventStream
import Keiro.Snapshot.Codec (withFoldFingerprint)
import Generated.MappedStructuralEnumEquality.ScopeGate.Domain
import Generated.MappedStructuralEnumEquality.ScopeGate.Harness (harnessAssertions)
import Generated.MappedStructuralEnumEquality.ScopeGate.Transducer (scopeGateTransducer)
import Generated.MappedStructuralEnumEquality.StructuralConformance (structuralConformanceAssertions)
import Generated.MappedStructuralEnumEquality.StructuralProjections qualified as Projections
import Keiki.Core qualified as K
import Keiki.Symbolic qualified as S
import Keiro.Codec (eventType)
import System.Exit (exitFailure)

main :: IO ()
main = do
  symbolic <- symbolicChecks
  let checks = structuralConformanceAssertions <> harnessAssertions <> symbolic <>
        [("concrete equality and inequality truth tables", concreteMatrix),
         ("expected enum wire meanings", expectedWire),
         ("nested and direct event JSON stays canonical", eventWire),
         ("event JSON bytes preserve declared spellings", exactEventBytes),
         ("generated events decode and replay to forward state", replayAgreement),
         ("compatible snapshot agrees with full replay and changed folds have a different discriminator", snapshotAgreement)]
  forM_ checks $ \(label, passed) -> putStrLn ((if passed then "PASS  " else "FAIL  ") <> label)
  unless (all snd checks) exitFailure

scopes :: [(RequiredScope, Text)]
scopes = [(PipelineScope, "pipeline"), (DiagnosticScope, "diagnostic")]

regs :: RequiredScope -> K.RegFile ScopeGateRegs
regs scope = K.RCons (Proxy @"requiredScope") scope K.RNil

command :: Int -> RequiredScope -> ScopeGateCommand
command 0 scope = Match (MatchData scope (Request scope))
command 1 scope = Differ (DifferData scope (Request scope))
command 2 scope = EqRight (EqRightData scope (Request scope))
command 3 scope = EqLeft (EqLeftData scope (Request scope))
command 4 scope = NeRight (NeRightData scope (Request scope))
command 5 scope = NeLeft (NeLeftData scope (Request scope))
command 6 scope = Self (SelfData scope (Request scope))
command _ _ = error "unknown fixture command"

accepts :: Int -> RequiredScope -> RequiredScope -> Bool
accepts 0 owner input = owner == input
accepts 1 owner input = owner /= input
accepts 2 _ input = input == PipelineScope
accepts 3 _ input = input == PipelineScope
accepts 4 _ input = input /= DiagnosticScope
accepts 5 _ input = input /= DiagnosticScope
accepts 6 _ _ = True
accepts _ _ _ = error "unknown fixture command"

concreteMatrix :: Bool
concreteMatrix = and
  [ isJust (K.step scopeGateTransducer (ScopeGateReady, regs owner) (command index input)) == accepts index owner input
  | index <- [0..6], (owner, _) <- scopes, (input, _) <- scopes ]

expectedWire :: Bool
expectedWire = and [encodeRequiredScopeMapped owner == String key | (owner, key) <- scopes]

eventWire :: Bool
eventWire = and
  [ encodeScopeGateEvent (Matched (MatchedData owner (Request owner))) ==
      object ["kind" .= ("Matched" :: Text), "requiredScope" .= key, "request" .= object ["requiredScope" .= key]]
  | (owner, key) <- scopes ]

exactEventBytes :: Bool
exactEventBytes =
  Aeson.encode (encodeScopeGateEvent (Matched (MatchedData PipelineScope (Request PipelineScope)))) == "{\"kind\":\"Matched\",\"request\":{\"requiredScope\":\"pipeline\"},\"requiredScope\":\"pipeline\"}"
    && Aeson.encode (encodeScopeGateEvent (Matched (MatchedData DiagnosticScope (Request DiagnosticScope)))) == "{\"kind\":\"Matched\",\"request\":{\"requiredScope\":\"diagnostic\"},\"requiredScope\":\"diagnostic\"}"

replayAgreement :: Bool
replayAgreement = and
  [ case K.step scopeGateTransducer initial (command index input) of
      Nothing -> True
      Just (vertex, registers, events) ->
        case traverse (\event -> parseScopeGateEvent (eventType scopeGateCodec event) (encodeScopeGateEvent event)) events of
          Left _ -> False
          Right decoded -> case K.applyEventsEither scopeGateTransducer initial decoded of
            Left _ -> False
            Right (replayedVertex, replayedRegisters) -> vertex == replayedVertex && registers K.! #requiredScope == replayedRegisters K.! #requiredScope
  | index <- [0..6], (owner, _) <- scopes, (input, _) <- scopes, let initial = (ScopeGateReady, regs owner) ]

scopeTerm :: K.Term ScopeGateRegs ScopeGateCommand '[] Text
scopeTerm = K.regProj Projections.requiredScopeWitness (#requiredScope :: K.Index ScopeGateRegs RequiredScope)

symbolicChecks :: IO [(String, Bool)]
symbolicChecks = do
  matrix <- forM [(index, owner, ownerKey, input, inputKey) | index <- [0..6], (owner, ownerKey) <- scopes, (input, inputKey) <- scopes] $ \(index, owner, ownerKey, input, inputKey) -> do
    let generated = case drop index (K.edgesOut scopeGateTransducer ScopeGateReady) of
          K.Edge edgePredicate _ _ _ _ : _ -> edgePredicate
          _ -> error "generated edge missing"
        predicate = K.PAnd generated (K.PAnd (K.PEq scopeTerm (K.lit ownerKey)) (K.PEq (inputTerm index) (K.lit inputKey)))
    result <- S.verifyPredicateDetailed predicate
    pure ("generated concrete/symbolic matrix: " <> show (index, owner, input), case result of
      S.PredicateSatisfiable S.ExactTranslation values -> accepts index owner input && not (null values) && all modelRoundTrip values
      S.PredicateUnsatisfiable S.ExactTranslation -> not (accepts index owner input)
      _ -> False)
  models <- forM scopes $ \(owner, key) -> do
    result <- S.verifyPredicateDetailed (K.PEq scopeTerm (K.lit key))
    pure ("exact finite reconstruction: " <> show owner, case result of
      S.PredicateSatisfiable strength values -> S.predicateTranslationExact (K.PEq scopeTerm (K.lit key)) && not (null values) && all (\value -> S.projectionModelKeyAs @Text value == Just key && S.projectionModelOwnerAs @RequiredScope value == Just owner) values && strength == S.ExactTranslation
      _ -> False)
  outside <- S.verifyPredicateDetailed (K.PAnd (K.PNot (K.PEq scopeTerm (K.lit "pipeline"))) (K.PNot (K.PEq scopeTerm (K.lit "diagnostic"))))
  pure (matrix <> models <> [("finite domain excludes every undeclared key", case outside of S.PredicateUnsatisfiable _ -> True; _ -> False)])

inputTerm :: Int -> K.Term ScopeGateRegs ScopeGateCommand '[ '("requiredScope", RequiredScope), '("request", Request)] Text
inputTerm index = K.inpProj Projections.requiredScopeWitness constructor #requiredScope
  where
    constructor = case index of
      0 -> inCtorMatch
      1 -> inCtorDiffer
      2 -> inCtorEqRight
      3 -> inCtorEqLeft
      4 -> inCtorNeRight
      5 -> inCtorNeLeft
      6 -> inCtorSelf
      _ -> error "unknown fixture command"

modelRoundTrip :: S.ProjectionModel -> Bool
modelRoundTrip value = case (S.projectionModelKeyAs @Text value, S.projectionModelOwnerAs @RequiredScope value) of
  (Just key, Just owner) -> (owner, key) `elem` scopes && Projections.requiredScopeGet owner == key
  _ -> False

snapshotAgreement :: Bool
snapshotAgreement = case EventStream.stateCodec scopeGateEventStreamDef of
  Nothing -> False
  Just codec ->
    let initial = (ScopeGateReady, regs PipelineScope)
        events = [Matched (MatchedData PipelineScope (Request PipelineScope))]
        full = K.applyEventsEither scopeGateTransducer initial events
        fromSnapshot = do
          decoded <- EventStream.decode codec (EventStream.encode codec initial)
          either (Left . T.pack . show) Right (K.applyEventsEither scopeGateTransducer decoded events)
        changed = withFoldFingerprint "changed-scope-fold" codec
    in EventStream.stateCodecVersion changed == EventStream.stateCodecVersion codec
       && EventStream.shapeHash changed == EventStream.shapeHash codec
       && EventStream.stateShapeHash changed /= EventStream.stateShapeHash codec
       && case (full, fromSnapshot) of
         (Right (leftVertex, leftRegs), Right (rightVertex, rightRegs)) -> leftVertex == rightVertex && leftRegs K.! #requiredScope == rightRegs K.! #requiredScope
         _ -> False
