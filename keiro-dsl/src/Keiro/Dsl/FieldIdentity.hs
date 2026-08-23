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
  { dslName :: !Name,
    selector :: !Text,
    wireKey :: !Text,
    loc :: !Loc
  }
  deriving stock (Eq, Show)

resolveAggregateFieldIdentity :: AggregateField -> ResolvedFieldIdentity
resolveAggregateFieldIdentity field =
  ResolvedFieldIdentity
    { dslName = (.name) field,
      selector = maybe ((.name) field) id ((.selector) field),
      wireKey = maybe ((.name) field) id ((.wireKey) field),
      loc = (.loc) field
    }

resolveContractFieldIdentity :: ContractField -> ResolvedFieldIdentity
resolveContractFieldIdentity field =
  ResolvedFieldIdentity
    { dslName = (.name) field,
      selector = maybe ((.name) field) id ((.selector) field),
      wireKey = maybe ((.name) field) id ((.wireKey) field),
      loc = (.loc) field
    }
