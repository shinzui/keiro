module Keiro.Ops.Http.Config
  ( MutationPolicy (..),
    SchemaDriftPolicy (..),
    InspectionLimits (..),
    defaultInspectionLimits,
    OpsHttpConfig (..),
    defaultOpsHttpConfig,
    OpsHttpServerConfig (..),
    defaultOpsHttpServerConfig,
  )
where

import Data.Text (Text)

data MutationPolicy = MutationsDisabled | MutationsEnabled
  deriving stock (Eq, Show)

data SchemaDriftPolicy = RefuseOnDrift | AllowDrift
  deriving stock (Eq, Show)

-- | All limits must be positive. Deadlines cover verification, execution, and
-- encoding. A mutation timeout has an unknown commit outcome and is not retried.
data InspectionLimits = InspectionLimits
  { maxConcurrentReads :: !Int,
    readDeadlineSeconds :: !Int,
    mutationDeadlineSeconds :: !Int,
    statementTimeoutMillis :: !Int,
    maxResponseBytes :: !Int,
    maxRequestBytes :: !Int
  }
  deriving stock (Eq, Show)

defaultInspectionLimits :: InspectionLimits
defaultInspectionLimits = InspectionLimits 4 5 30 2000 1048576 16384

data OpsHttpConfig = OpsHttpConfig
  { mutations :: !MutationPolicy,
    schemaDrift :: !SchemaDriftPolicy,
    allowedOrigins :: ![Text],
    inspectionLimits :: !InspectionLimits
  }
  deriving stock (Eq, Show)

defaultOpsHttpConfig :: OpsHttpConfig
defaultOpsHttpConfig = OpsHttpConfig MutationsDisabled RefuseOnDrift [] defaultInspectionLimits

data OpsHttpServerConfig = OpsHttpServerConfig
  { bindHost :: !Text,
    port :: !Int,
    requestTimeoutSeconds :: !Int
  }
  deriving stock (Eq, Show)

defaultOpsHttpServerConfig :: OpsHttpServerConfig
defaultOpsHttpServerConfig = OpsHttpServerConfig "127.0.0.1" 9092 300
