module Keiro.Snapshot.Policy
  ( shouldSnapshot
  )
where

import Keiro.EventStream (SnapshotPolicy (..))
import Keiro.Prelude
import Kiroku.Store.Types (StreamVersion (..))
import Prelude qualified

shouldSnapshot :: SnapshotPolicy state -> Bool -> state -> StreamVersion -> Bool
shouldSnapshot Never _ _ _ = False
shouldSnapshot (Every interval) _ _ (StreamVersion version)
  | interval <= 0 = False
  | otherwise = version `Prelude.mod` Prelude.fromIntegral interval == 0
shouldSnapshot OnTerminal terminal _ _ = terminal
shouldSnapshot (Custom decide) _ state version = decide state version
