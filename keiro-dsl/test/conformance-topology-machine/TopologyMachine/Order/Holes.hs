{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TypeApplications #-}
-- This is a HAND-OWNED version-2 hook module. keiro-dsl creates it once
-- and never overwrites it. Generated code owns every transition envelope
-- and every declared guard/write. This module supplies explicit event-field
-- mappings and explicitly selected Hole behavior only; fields(Command)
-- identity mappings are generated directly and have no hook.
module TopologyMachine.Order.Holes
  ( transition3DraftNoteOrderHole
  , transition3DraftNoteOrderHoleFoldVersion
  ) where

import Generated.TopologyMachine.Order.Domain
import Keiki.Builder qualified as B
import Keiki.Generics (RegFieldsOf)


import Keiki.Core qualified as K
import Keiro.Snapshot.Codec (FoldVersion (..))

-- HOLE: add the predicate and ordered register updates for this transition.
-- The generated transducer still owns command matching, mode, emits, and goto.
transition3DraftNoteOrderHole :: B.PayloadProj OrderRegs OrderCommand (RegFieldsOf NoteOrderData) -> B.EdgeBuilder OrderRegs OrderCommand OrderEvent OrderVertex ('Just (RegFieldsOf NoteOrderData)) writes writes ()
transition3DraftNoteOrderHole _d = B.requireGuard K.PTop

-- Bump this token whenever the Hole predicate or updates change.
transition3DraftNoteOrderHoleFoldVersion :: FoldVersion
transition3DraftNoteOrderHoleFoldVersion = FoldVersion "transition3DraftNoteOrder-fold-v1"

