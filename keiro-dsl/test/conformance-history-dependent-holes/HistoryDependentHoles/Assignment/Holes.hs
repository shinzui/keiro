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
module HistoryDependentHoles.Assignment.Holes
  ( transition1ActiveSetPropertyHole
  , transition1ActiveSetPropertyHoleFoldVersion
  , transition2ActiveClearPropertyHole
  , transition2ActiveClearPropertyHoleFoldVersion
  , transition4ActiveClearPropertyHole
  , transition4ActiveClearPropertyHoleFoldVersion
  ) where

import Generated.HistoryDependentHoles.Assignment.Domain
import Keiki.Builder ((=:))
import Keiki.Builder qualified as B
import Keiki.Generics (RegFieldsOf)


import Conformance.HistoryDependentHoles.Domain (PropertyValues (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Keiki.Core qualified as K
import Keiro.Snapshot.Codec (FoldVersion (..))

-- HOLE: add the predicate and ordered register updates for this transition.
-- The generated transducer still owns command matching, mode, emits, and goto.
transition1ActiveSetPropertyHole :: B.PayloadProj AssignmentRegs AssignmentCommand (RegFieldsOf SetPropertyData) -> B.EdgeBuilder AssignmentRegs AssignmentCommand AssignmentEvent AssignmentVertex ('Just (RegFieldsOf SetPropertyData)) '[] '["values"] ()
transition1ActiveSetPropertyHole d = B.do
  B.requireGuard K.PTop
  B.slot @"values" =: K.TApp2 insertValue (B.reg @"values") (K.TApp2 (,) d.key d.value)

-- Bump this token whenever the Hole predicate or updates change.
transition1ActiveSetPropertyHoleFoldVersion :: FoldVersion
transition1ActiveSetPropertyHoleFoldVersion = FoldVersion "transition1ActiveSetProperty-fold-v1"

-- HOLE: add the predicate and ordered register updates for this transition.
-- The generated transducer still owns command matching, mode, emits, and goto.
transition2ActiveClearPropertyHole :: B.PayloadProj AssignmentRegs AssignmentCommand (RegFieldsOf ClearPropertyData) -> B.EdgeBuilder AssignmentRegs AssignmentCommand AssignmentEvent AssignmentVertex ('Just (RegFieldsOf ClearPropertyData)) '[] '["values"] ()
transition2ActiveClearPropertyHole d = B.do
  B.requireGuard (K.PEq (K.TApp2 memberValue d.key (B.reg @"values")) (K.TLit True))
  B.slot @"values" =: K.TApp2 deleteValue (B.reg @"values") d.key

-- Bump this token whenever the Hole predicate or updates change.
transition2ActiveClearPropertyHoleFoldVersion :: FoldVersion
transition2ActiveClearPropertyHoleFoldVersion = FoldVersion "transition2ActiveClearProperty-fold-v1"

-- HOLE: add the predicate and ordered register updates for this transition.
-- The generated transducer still owns command matching, mode, emits, and goto.
transition4ActiveClearPropertyHole :: B.PayloadProj AssignmentRegs AssignmentCommand (RegFieldsOf ClearPropertyData) -> B.EdgeBuilder AssignmentRegs AssignmentCommand AssignmentEvent AssignmentVertex ('Just (RegFieldsOf ClearPropertyData)) '[] '["values"] ()
transition4ActiveClearPropertyHole d = B.do
  B.requireGuard K.PTop
  B.slot @"values" =: K.TApp2 deleteValue (B.reg @"values") d.key

-- Bump this token whenever the Hole predicate or updates change.
transition4ActiveClearPropertyHoleFoldVersion :: FoldVersion
transition4ActiveClearPropertyHoleFoldVersion = FoldVersion "transition4ActiveClearProperty-fold-v1"


insertValue :: PropertyValues -> (Text, Text) -> PropertyValues
insertValue (PropertyValues values) (key, value) = PropertyValues (Map.insert key value values)

memberValue :: Text -> PropertyValues -> Bool
memberValue key (PropertyValues values) = Map.member key values

deleteValue :: PropertyValues -> Text -> PropertyValues
deleteValue (PropertyValues values) key = PropertyValues (Map.delete key values)
