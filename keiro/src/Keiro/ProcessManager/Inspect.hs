-- | Process-manager inspection contracts. Instance reads extend this module
-- after the pending-timer read is available.
module Keiro.ProcessManager.Inspect
  ( ReactionProvenance (..),
    encodeReactionProvenance,
    decodeReactionProvenance,
  )
where

import Keiro.ProcessManager.Provenance
