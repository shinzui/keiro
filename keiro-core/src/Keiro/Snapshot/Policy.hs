{- | Evaluation of a stream's 'SnapshotPolicy'.

This is the single decision procedure command handling consults after an
append to decide whether to persist a snapshot of the folded state. It
keeps the 'SnapshotPolicy' constructors purely declarative — the meaning
of each constructor lives here.
-}
module Keiro.Snapshot.Policy (
    shouldSnapshot,
    shouldSnapshotSpan,
)
where

import Keiro.EventStream (SnapshotPolicy (..), Terminality (..))
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
shouldSnapshot :: SnapshotPolicy state -> Terminality -> state -> StreamVersion -> Bool
shouldSnapshot Never _ _ _ = False
shouldSnapshot (Every interval) _ _ (StreamVersion version)
    | interval <= 0 = False
    | otherwise = version > 0 Prelude.&& version `Prelude.mod` Prelude.fromIntegral interval == 0
shouldSnapshot OnTerminal terminality _ _ = terminality == Terminal
shouldSnapshot (Custom decide) terminality state version = decide terminality state version

{- | Like 'shouldSnapshot', but evaluated over the half-open stream-version
span @(preVersion, postVersion]@ that one append covered.

For 'Every' @n@, this fires when any positive multiple of @n@ lies inside
the span, so a batch append that jumps over a boundary still snapshots at
the post-append version. The other policies ignore the span and behave like
'shouldSnapshot'.
-}
shouldSnapshotSpan ::
    SnapshotPolicy state ->
    Terminality ->
    state ->
    StreamVersion ->
    StreamVersion ->
    Bool
shouldSnapshotSpan Never _ _ _ _ = False
shouldSnapshotSpan (Every interval) _ _ (StreamVersion preVersion) (StreamVersion postVersion)
    | interval <= 0 = False
    | postVersion <= 0 = False
    | otherwise = postVersion `Prelude.div` n > preVersion `Prelude.div` n
  where
    n = Prelude.fromIntegral interval
shouldSnapshotSpan OnTerminal terminality _ _ _ = terminality == Terminal
shouldSnapshotSpan (Custom decide) terminality state _ postVersion = decide terminality state postVersion
