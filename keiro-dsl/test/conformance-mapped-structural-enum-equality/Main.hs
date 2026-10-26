{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}
module Main (main) where

import Conformance.MappedStructuralEnumEquality.Domain
import Control.Monad (forM, forM_, unless)
import Data.Aeson (Value (..), object, (.=))
import Data.Maybe (isJust)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Generated.MappedStructuralEnumEquality.ScopeGate.Codec
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
         ("generated events decode and replay to forward state", replayAgreement)]
  forM_ checks $ \(label, passed) -> putStrLn ((if passed then "PASS  " else "FAIL  ") <> label)
  unless (all snd checks) exitFailure

scopes :: [(RequiredScope, Text)]
scopes = [(PipelineScope, "pipeline"), (DiagnosticScope, "diagnostic")]

regs :: RequiredScope -> K.RegFile ScopeGateRegs
regs scope = K.RCons (Proxy @"requiredScope") scope K.RNil

command :: Bool -> RequiredScope -> ScopeGateCommand
command True scope = Match (MatchData scope (Request scope))
command False scope = Differ (DifferData scope (Request scope))

concreteMatrix :: Bool
concreteMatrix = and
  [ isJust (K.step scopeGateTransducer (ScopeGateReady, regs owner) (command equal input)) == (equal == (owner == input))
  | equal <- [True, False], (owner, _) <- scopes, (input, _) <- scopes ]

expectedWire :: Bool
expectedWire = and [encodeRequiredScopeMapped owner == String key | (owner, key) <- scopes]

eventWire :: Bool
eventWire = and
  [ encodeScopeGateEvent (Matched (MatchedData owner (Request owner))) ==
      object ["kind" .= ("Matched" :: Text), "requiredScope" .= key, "request" .= object ["requiredScope" .= key]]
  | (owner, key) <- scopes ]

replayAgreement :: Bool
replayAgreement = and
  [ case K.step scopeGateTransducer initial (command equal input) of
      Nothing -> True
      Just (vertex, registers, events) ->
        case traverse (\event -> parseScopeGateEvent (eventType scopeGateCodec event) (encodeScopeGateEvent event)) events of
          Left _ -> False
          Right decoded -> case K.applyEventsEither scopeGateTransducer initial decoded of
            Left _ -> False
            Right (replayedVertex, replayedRegisters) -> vertex == replayedVertex && registers K.! #requiredScope == replayedRegisters K.! #requiredScope
  | equal <- [True, False], (owner, _) <- scopes, (input, _) <- scopes, let initial = (ScopeGateReady, regs owner) ]

scopeTerm :: K.Term ScopeGateRegs ScopeGateCommand '[] Text
scopeTerm = K.regProj Projections.requiredScopeWitness (#requiredScope :: K.Index ScopeGateRegs RequiredScope)

symbolicChecks :: IO [(String, Bool)]
symbolicChecks = do
  models <- forM scopes $ \(owner, key) -> do
    result <- S.verifyPredicateDetailed (K.PEq scopeTerm (K.lit key))
    pure ("exact finite reconstruction: " <> show owner, case result of
      S.PredicateSatisfiable strength values -> S.predicateTranslationExact (K.PEq scopeTerm (K.lit key)) && not (null values) && all (\value -> S.projectionModelKeyAs @Text value == Just key && S.projectionModelOwnerAs @RequiredScope value == Just owner) values && strength == S.ExactTranslation
      _ -> False)
  outside <- S.verifyPredicateDetailed (K.PAnd (K.PNot (K.PEq scopeTerm (K.lit "pipeline"))) (K.PNot (K.PEq scopeTerm (K.lit "diagnostic"))))
  pure (models <> [("finite domain excludes every undeclared key", case outside of S.PredicateUnsatisfiable _ -> True; _ -> False)])
