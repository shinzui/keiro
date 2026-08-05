-- | Resolved field identities shared by validation and generation.
--
-- A direct aggregate or contract field has three independent namespaces: its
-- logical DSL identity, its generated Haskell selector, and its serialized wire
-- key. Resolution is total; validation of spelling and collisions belongs to
-- "Keiro.Dsl.Validate".
module Keiro.Dsl.FieldIdentity
  ( ResolvedFieldIdentity (..),
    resolveAggregateFieldIdentity,
    resolveContractFieldIdentity,
  )
where

import Data.Text (Text)
import Keiro.Dsl.Grammar

data ResolvedFieldIdentity = ResolvedFieldIdentity
  { fieldDslName :: !Name,
    fieldSelector :: !Text,
    fieldWireKey :: !Text,
    fieldLoc :: !Loc
  }
  deriving stock (Eq, Show)

resolveAggregateFieldIdentity :: AggregateField -> ResolvedFieldIdentity
resolveAggregateFieldIdentity field =
  ResolvedFieldIdentity
    { fieldDslName = aggregateFieldName field,
      fieldSelector = maybe (aggregateFieldName field) id (aggregateFieldSelector field),
      fieldWireKey = maybe (aggregateFieldName field) id (aggregateFieldWireKey field),
      fieldLoc = aggregateFieldLoc field
    }

resolveContractFieldIdentity :: ContractField -> ResolvedFieldIdentity
resolveContractFieldIdentity field =
  ResolvedFieldIdentity
    { fieldDslName = cfName field,
      fieldSelector = maybe (cfName field) id (cfSelector field),
      fieldWireKey = maybe (cfName field) id (cfWireKey field),
      fieldLoc = cfLoc field
    }
