{-# LANGUAGE NoFieldSelectors #-}

-- | Pure domain-decision values that need ordinary record labels without
-- adding selector functions which collide with the established command API.
module Keiro.Command.Domain
  ( SilentCommandContext (..),
    SilentDomainDecision (..),
  )
where

import Keiki.Core (EdgeRef, RegFile)
import Keiro.Prelude

-- | Pre-command values supplied to the pure classifier for an already-selected
-- output-free live edge. The edge reference is local to this exact transducer
-- construction and must not be persisted as an application identifier.
data SilentCommandContext rs s ci = SilentCommandContext
  { state :: !s,
    registers :: !(RegFile rs),
    command :: !ci,
    selectedEdge :: !(EdgeRef s)
  }
  deriving stock (Generic)

-- | Total classification of one explicitly selected output-free edge.
data SilentDomainDecision rejection noOp
  = SilentRejected !rejection
  | SilentNoOp !noOp
  deriving stock (Generic, Eq, Show)
