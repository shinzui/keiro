# 2. Replay-only edges are the sanctioned remedy for guard tightening

Date: 2026-07-23

Status: Accepted


## Context

keiki has no separate decide/evolve: one edge set serves both forward
execution and replay. Hydration re-inverts each stored event to a command and
re-checks the edge's guard against it, so *tightening a guard* is
replay-relevant — a stored event legally appended under the old guard may no
longer satisfy the new one, and the next command on any stream containing
such an event fails hydration with `HydrationReplayFailed
HydrationNoInvertingEdge`. The 2026-07 evolution review confirmed this end to
end (the "black-acuity" scenario), and until plan 143 the only mitigation was
the guarded-but-inert contortion: retain the old edge with its guard
conjoined onto a command flag operations never send — a hack that leaned on a
solver detail and polluted command types with unsendable fields.

A naive first-class design fails at the boundary: keiki's static
inversion-ambiguity check is deliberately guard-blind (it flags any
same-vertex edge pair sharing a first-output wire constructor, because it
cannot prove semantic guard disjointness), and keiro's `mkEventStream` runs
it default-on and fatal — so a live edge plus a retained twin emitting the
same event would be refused at startup regardless of their actually-disjoint
guards.


## Decision

keiki 0.3.0.0 gives `Edge` a mode: `EdgeMode = Live | ReplayOnly`. A
`ReplayOnly` edge is never taken by forward stepping and exists so events
emitted under a retired rule keep an inverting edge; its update defines how
those historical events fold today.

Inversion is **two-phase**: candidates are sought among `Live` edges first,
and only when no live edge matches (solve + guard) are `ReplayOnly` edges
tried; ambiguity is judged within the phase that produced candidates. This
needs no guard reasoning: an event attributable under the current rule
attributes there; only unattributable history falls through. It also makes
the pattern robust to imperfectly complemented twins (an overlap cannot
create cross-phase ambiguity, only a deterministic live-first preference) and
lets the static ambiguity check scope itself to same-mode pairs, which is
what allows a live edge and its twin through keiro's forced boundary checks.

Check-by-check treatment (keiki 0.3.0.0): the forward-determinism family
(`checkTransitionDeterminism*`, `determinismWarnings`, `isSingleValuedSym`)
considers only Live/Live pairs; `inversionAmbiguityWarnings` flags only
same-mode pairs; every other validator check — hidden-input,
head-recoverability, guard-implies-input-read, state-changing epsilon,
opaque-guard, both dead-edge analyses — applies to replay-only edges
unchanged. Structural reachability keeps traversing replay-only targets: a
vertex reachable only through a replay-only edge stays live for replay
continuation (an old stream replays through the twin, then serves new
commands from that vertex). Composition combines modes with `ReplayOnly`
absorbing (`Semigroup`/`Monoid` on `EdgeMode`): a composite edge may fire
forward only when every component may.

The DSL makes the remedy one keyword plus a paste. A `replay-only` prefix on
a transition line lowers to the keiki mode (`B.replayOnly` in the scaffolded
builder skeleton). Because the removed region of a tightening is computable —
`old-guard ∧ ¬new-guard`, with negation eliminable inside the guard grammar
(De Morgan, comparison flipping, `x == false` for bare boolean atoms;
`complementExpr`) — `keiro-dsl diff` computes and prints a paste-ready
replay-only twin (`AggGuardTightened` advisory) whenever a live guard changes
and no twin exists. The twin is printed, never auto-applied: whether history
should stay replayable (paste) or be truncated instead is a business
decision.

Discipline rules: a replay-only transition with no emit is an error
(`ReplayOnlyEmitsNothing`); one with no live sibling for its (source,
command) pair is a warning pointing at event retirement
(`ReplayOnlyCommandStillLive`); deprecated events may keep being emitted by
replay-only transitions, which are not the write path — this supersedes the
guarded-but-inert pattern as the sanctioned retained-edge shape for event
retirement (plan 139 aligns its wording when it lands).


## Consequences

- Guard tightening is now: advised at diff time with a computed remedy,
  refused loudly at hydration if ignored, resolved by pasting the twin or by
  audit-then-truncate (the replay audit of plan 142 is the checker for
  "does stored data exercise the removed region").
- Replay-only twins are a *scoped, explicit* reintroduction of the
  decide/evolve split — deliberately. A twin cannot drift (it still couples
  its event to its writes); it merely stops accepting new commands. The
  single-edge-set virtue (emit/update drift unrepresentable) is preserved for
  live behaviour.
- Twins end in retirement, mirroring upcasters: once every stream containing
  the removed region's events is terminal or truncated (provable by the
  replay audit), the twin can be deleted. Deleting it earlier re-creates
  exactly the hydration break it fixed — the rollback hazard is documented in
  the keiki and keiro CHANGELOGs.
- The keiki `Edge` record is five fields (`mode` added, PVP-major 0.3.0.0);
  every hand-written construction site must supply `mode = Live` to keep its
  prior semantics.
- Plan 138's fold fingerprint must include the transition mode in its
  canonical rendering when it lands (a mode flip changes replay attribution),
  and its transition-surface advisory shares the guard-change detection with
  `AggGuardTightened` — plan 138 should merge or subsume the code, keeping
  `DiagnosticCode` additions append-only.
