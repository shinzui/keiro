{-# LANGUAGE OverloadedRecordDot #-}

module Main (main) where

import Control.Monad (unless)
import Generated.KeywordSegments.Inspection (aggregateInspectorCatalog, aggregateInspectors, inspectionAuditTargets, inspectionProjectionCatalog)
import Generated.KeywordSegments.JobType.Queue (JobTypePayload)
import Generated.KeywordSegments.JobType.QueueCodec (jobTypeJobCodec, jobTypePayloadCodec)
import Generated.KeywordSegments.JobType.QueuePolicy (JobTypeOutcome (..), jobOutcomeFor)
import Generated.KeywordSegments.ProjectionCatalog (validatedProjectionCatalog)
import Generated.KeywordSegments.ValidateCustomType.ReadModel (validateCustomTypeReadModel)
import Generated.KeywordSegments.ValidateCustomType.ReadModelHarness (readModelFacts, runReadModelFacts)
import Keiro.Codec (Codec)
import Keiro.PGMQ.Codec (JobCodec)
import Keiro.PGMQ.Job (JobOutcome (..), RetryDelay (..))
import Keiro.Projection.Catalog (catalogFingerprint, catalogFingerprintText)
import Keiro.ReadModel (ReadModel (..))
import System.Exit (exitFailure)

main :: IO ()
main = do
  factsOk <- runReadModelFacts
  let recordOk =
        validateCustomTypeReadModel.name == "keyword-segments-validate-custom-type"
          && validateCustomTypeReadModel.tableName == "validate_custom_type"
          && validateCustomTypeReadModel.schema == "billing"
      policyOk = case jobOutcomeFor StoreFailure of
        Retry (RetryDelay 1) -> True
        _ -> False
      -- A projections-only context still emits the Inspection module, with
      -- empty aggregate sections and the generated projection catalog.
      aggregatesEmpty = null aggregateInspectors && null aggregateInspectorCatalog
      auditTargetsEmpty = null inspectionAuditTargets
      sameCatalog = catalogFingerprintText (catalogFingerprint inspectionProjectionCatalog) == catalogFingerprintText (catalogFingerprint validatedProjectionCatalog)
      allOk = factsOk && all (\(_, expected, actual) -> expected == actual) readModelFacts && recordOk && policyOk && aggregatesEmpty && auditTargetsEmpty && sameCatalog
  putStrLn ("read-model facts: " <> show factsOk)
  putStrLn ("runtime record: " <> show recordOk)
  putStrLn ("queue policy: " <> show policyOk)
  putStrLn ("inspection aggregates empty: " <> show aggregatesEmpty)
  putStrLn ("inspection audit targets empty: " <> show auditTargetsEmpty)
  putStrLn ("inspection projection catalog is the generated catalog: " <> show sameCatalog)
  unless allOk exitFailure

_usesPayloadCodec :: Codec JobTypePayload
_usesPayloadCodec = jobTypePayloadCodec

_usesJobCodec :: JobCodec JobTypePayload
_usesJobCodec = jobTypeJobCodec
