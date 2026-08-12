{-# OPTIONS_GHC -Wno-deprecations #-}

-- | Compile-only coverage for the Keiro 0.11 read-model surface. This module
-- deliberately uses every misleading legacy spelling so the 0.12 migration
-- window cannot accidentally become a source break.
module Compatibility.ReadModel011
  ( legacyDirectRecord,
    legacyPositionalRecord,
    legacyPattern,
    legacyModes,
    legacyDefaultOptions,
    legacyRunQueryWith,
  )
where

import Data.Text (Text)
import Effectful (Eff, IOE, (:>))
import Keiro.ReadModel
  ( ConsistencyMode (..),
    PositionWaitOptions (..),
    ReadModel (..),
    ReadModelError,
    StrongScope (..),
    defaultStrongWaitOptions,
    runQueryWith,
  )
import Keiro.Telemetry (KeiroMetrics)
import Kiroku.Store.Effect (Store)

legacyDirectRecord :: ReadModel () ()
legacyDirectRecord =
  ReadModel
    { name = "compatibility-legacy-record",
      tableName = "legacy_record",
      schema = "public",
      subscriptionName = "legacy-subscription",
      version = 1,
      shapeHash = "legacy-v1",
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \() -> pure ()
    }

legacyPositionalRecord :: ReadModel () ()
legacyPositionalRecord =
  ReadModel
    "compatibility-legacy-positional"
    "legacy_positional"
    "public"
    "legacy-subscription"
    1
    "legacy-v1"
    Strong
    (CategoryHead "legacy")
    (\() -> pure ())

legacyPattern :: ReadModel q r -> (Text, Text, Text, Text, Int, Text, ConsistencyMode, StrongScope)
legacyPattern (ReadModel modelName table schemaName subscription modelVersion shape consistency scope _) =
  (modelName, table, schemaName, subscription, modelVersion, shape, consistency, scope)

legacyModes :: [ConsistencyMode]
legacyModes =
  [ Eventual,
    Strong,
    PositionWait
      PositionWaitOptions
        { target = Nothing,
          timeoutMicros = 5000000,
          pollMicros = 10000
        }
  ]

legacyDefaultOptions :: PositionWaitOptions
legacyDefaultOptions = defaultStrongWaitOptions

legacyRunQueryWith ::
  (IOE :> es, Store :> es) =>
  Maybe KeiroMetrics ->
  ConsistencyMode ->
  ReadModel q r ->
  q ->
  Eff es (Either ReadModelError r)
legacyRunQueryWith = runQueryWith
