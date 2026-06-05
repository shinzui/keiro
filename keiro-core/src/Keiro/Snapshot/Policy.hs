{- | Evaluation of a stream's 'SnapshotPolicy'.

This is the single decision procedure command handling consults after an
append to decide whether to persist a snapshot of the folded state. It
keeps the 'SnapshotPolicy' constructors purely declarative — the meaning
of each constructor lives here.
-}
module Keiro.Snapshot.Policy (
    shouldSnapshot,
)
where

import Keiro.EventStream (SnapshotPolicy (..))
import Keiro.Prelude
import Kiroku.Store.Types (StreamVersion (..))
import Prelude qualified

{- | Decide whether to snapshot given a policy, a terminality flag, the
folded state, and the post-append stream version.

* 'Never' is always 'False'.
* 'Every' @n@ is 'True' when the version is a positive multiple of @n@
  (a non-positive interval never fires).
* 'OnTerminal' mirrors the @terminal@ flag — snapshot exactly when the
  machine has reached a final state.
* 'Custom' defers to the caller-supplied predicate over state and version.
-}
shouldSnapshot :: SnapshotPolicy state -> Bool -> state -> StreamVersion -> Bool
shouldSnapshot Never _ _ _ = False
shouldSnapshot (Every interval) _ _ (StreamVersion version)
    | interval <= 0 = False
    | otherwise = version `Prelude.mod` Prelude.fromIntegral interval == 0
shouldSnapshot OnTerminal terminal _ _ = terminal
shouldSnapshot (Custom decide) _ state version = decide state version
