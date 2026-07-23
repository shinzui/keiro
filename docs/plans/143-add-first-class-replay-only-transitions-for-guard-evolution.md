---
id: 143
slug: add-first-class-replay-only-transitions-for-guard-evolution
title: "Add first-class replay-only transitions for guard evolution"
kind: exec-plan
created_at: 2026-07-23T12:58:14Z
intention: intention_01ky7hw0hdehzstvt0ec42jbaz
master_plan: "docs/masterplans/24-close-the-evolution-and-replayability-gate-gaps-surfaced-by-the-2026-07-evolution-review.md"
---

# Add first-class replay-only transitions for guard evolution

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

In keiki, one edge set serves both forward execution and replay: hydration re-inverts
each stored event to a command and **re-checks the edge's guard** against it
(`keiki/src/Keiki/Core.hs:1222-1229`). The consequence — verified in the 2026-07
evolution review and worked as the "black-acuity" example in
`docs/guides/adopting-keiro-from-tan-event-source.md` — is that *tightening a guard* is
replay-relevant: a stored event that was legally appended under the old guard may no
longer satisfy the new one, and the next command on any stream containing such an event
fails `HydrationReplayFailed HydrationNoInvertingEdge`. Today the only sanctioned
mitigation is the guarded-but-inert contortion (retain the old edge with its guard
conjoined onto a command flag operations never send —
docs/plans/139-validate-codecs-and-deprecated-event-replayability-at-the-stream-boundary.md,
Decision Log), which works but is a hack wearing a convention.

After this plan, the pattern is first-class and one keyword. keiki gains an edge mode:
a **replay-only** edge participates in inversion (so history stays replayable) and is
excluded from forward stepping (so the tightened rule governs all new traffic). The DSL
gains a `replay-only transition` marker that lowers to it. And because the removed guard
region is *computable* — `old-guard ∧ ¬new-guard` — `keiro-dsl diff` does the work for
the developer: when it detects a guard tightening on an edge whose event types have
stored history, its advisory prints the exact replay-only twin transition to paste into
the spec. The black-acuity change becomes:

```text
transition Held -- ConfirmReservation
  guard  divertStatus == open && patientAcuity != black   # the new rule
  emits  TransferReservationConfirmed
  ...

replay-only transition Held -- ConfirmReservation
  guard  divertStatus == open && patientAcuity == black   # exactly the removed region
  emits  TransferReservationConfirmed
  ...                                                     # same writes/target
```

— new commands in the removed region are rejected; every stored event still inverts;
the retired rule remains visible in the spec as a record of what was once allowed. This
also supersedes the guarded-but-inert hack as the sanctioned retained-edge shape for
event retirement (docs/plans/139's `retiring event` ladder points here once landed).

You can see it working in a keiro test that reproduces the black-acuity scenario end to
end: history written under the old guard, machine redeployed with the tightened live
guard plus the replay-only twin → replay succeeds and a forward command in the removed
region is rejected; the same machine without the twin → `HydrationNoInvertingEdge`.


## Progress

- [x] M1 (2026-07-23, keiki commit `a8d6377`): keiki `EdgeMode` (`Live` /
      `ReplayOnly`) landed: excluded from forward stepping, included in
      (two-phase) inversion, dead-edge-clean by construction (see Surprises —
      no reachability change was needed), same-mode-scoped ambiguity checks;
      new `ReplayOnlySpec` (22 examples) reproduces black-acuity at the keiki
      level; all four repo suites green (keiki-test 520, jitsurei 122,
      keiki-codec-json 102+13); version 0.3.0.0 (PVP-major: `Edge` record
      change), sibling packages rebound to `^>=0.3`; `Keiki.Builder.replayOnly`
      shipped alongside.
- [ ] M2: keiro black-acuity end-to-end test green (with-twin replays, without-twin
      fails, forward command in removed region rejected); `EventStream` construction
      surface passes the mode through; keiro-test green against local keiki.
- [ ] M3: DSL `replay-only transition` marker (grammar/parser/pretty-print/validator/
      scaffold lowering); diff advisory on guard tightening prints the computed
      replay-only twin; fixtures + 24-suite bar green.
- [ ] Close-out: docs/plans/139 retained-edge wording reconciled; guide + adoption doc
      flipped to present tense; master plan 24 boxes ticked; CHANGELOGs; ADR
      distillation (replay-only semantics into the evolution-gate inventory).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The dead-edge check needed **no code change** for M1, contrary to the plan's
  step-5 instruction to "skip ReplayOnly edges". `checkDeadEdges` flags only
  (a) edges whose *source vertex* is unreachable by target-pointer traversal
  and (b) literal-`PBot` guards — it never tests forward-firability of the
  edge itself — and `reachableVertices` already traverses replay-only edges'
  targets. Both flags remain *correct* for replay-only edges: an
  unreachable-source replay-only edge is dead for replay too (replay starts
  from the same `initial`), and a `PBot` guard can never model a solved
  command, so it cannot invert. The planned test ("a machine whose only path
  to a vertex is a replay-only edge passes") passes on the unchanged check —
  `ReplayOnlySpec` pins it. Keeping the traversal unchanged is load-bearing:
  a vertex reachable only through a replay-only edge stays live for replay
  continuation (an old stream replays through the twin, then serves new
  commands from that vertex).
- The plan's M1 step-6 test list says "an ambiguous live/replay-only pair is
  still flagged", contradicting its own two-phase Decision Log entry (cross-
  mode pairs are resolved by phase order and must NOT be flagged — flagging
  them is precisely what would refuse every live+twin machine at keiro's
  boundary). The Decision Log governs; the shipped tests assert cross-mode
  pairs are unflagged and *same-mode* pairs (live/live and
  replay-only/replay-only) are still flagged.
- keiki's test tree constructs `Edge` at 60+ sites (record and positional
  syntax mixed), and `-Wmissing-fields` is a warning, not an error, under the
  repo's `-Wall`. The record change was driven to completeness by building
  everything with `--ghc-options=-Werror=missing-fields`; positional
  construction sites (`Edge g u o t`) fail loudly as arity errors either way.
  The keiki repo also runs a `treefmt` pre-commit hook that reformats and
  fails the commit if anything changed — commit twice (the second commit sees
  stable formatting).


## Decision Log

- Decision: The mechanism is a keiki-native edge mode, not DSL sugar over the
  guarded-but-inert phantom-flag pattern.
  Rationale: The phantom flag depends on inversion treating an output-unconstrained
  command field as satisfiable — a solver detail (`solveOutput` then
  `models (guard e)`, `keiki/src/Keiki/Core.hs:1223-1229`) that the semantics should
  not hang on; it also pollutes command types with fields that exist only to be unsent,
  and the dead-edge exemption falls out of a mode naturally while the flag hack merely
  evades the check. A native mode is honest about what the edge *is* — an
  evolve-only arm for historical facts — and both engines already share `edgesOut`, so
  the filter has single choke points on each path (forward: the `delta`/`step` family,
  `Core.hs:916,939,1017,1079`; replay: `applyEventStreamingEither`, `Core.hs:1222`).
  Fallback if the keiki change stalls: the phantom-flag lowering behind the same DSL
  keyword, recorded here with the solver-behaviour proof.
  Date: 2026-07-23

- Decision: Replay-only edges are a scoped, explicit reintroduction of the
  decide/evolve split — and that is the point, not a contradiction.
  Rationale: The single edge set exists to make emit/update drift unrepresentable for
  *live* behaviour. A replay-only edge cannot drift either — it still couples its
  event to its writes; it merely stops accepting new commands. What it reintroduces is
  the classic framework's virtue (history folds under rules that no longer accept new
  facts) without its vice (silent divergence between write path and replay path).
  Validation keeps it disciplined: mode is explicit in the spec, forward-unreachable is
  its definition rather than a warning to suppress, and ambiguity checks still apply so
  a replay-only twin cannot shadow a live edge.
  Date: 2026-07-23

- Decision: `diff` computes and prints the replay-only twin (guard =
  pretty-printed `old ∧ ¬new`, same emits/writes/target) in its guard-tightening
  advisory, but does not auto-apply it to the spec.
  Rationale: The twin is mechanical, so the tool should write it; whether the
  historical region *should* remain replayable (vs. truncating affected streams) is a
  business decision, so a human should paste it. Auto-application also collides with
  hole-owned formatting and with docs/plans/142's replay-impact verdict, which already
  tells the developer whether stored data actually exercises the removed region —
  paste the twin, or audit and truncate; the advisory names both paths.
  Date: 2026-07-23

- Decision: Inversion becomes **two-phase**: candidates are sought among `Live` edges
  first, and only when no live edge matches (solve + guard) are `ReplayOnly` edges
  tried; ambiguity is judged per phase. The static `inversionAmbiguityWarnings` check
  is correspondingly scoped to same-mode pairs.
  Rationale: Discovered during plan verification (2026-07-23): the static ambiguity
  check is deliberately guard-blind — it flags any same-vertex pair whose first
  outputs share a wire constructor, documented as unable to prove semantic guard
  disjointness (`keiki/src/Keiki/Core.hs:2180-2221`), and it is default-on and fatal
  at keiro's boundary — so a live edge plus its replay-only twin would be refused at
  startup under a single-phase design, regardless of their actually-disjoint guards.
  Two-phase attribution needs no guard reasoning at all: an event attributable under
  the current rule attributes there; only unattributable history falls through to the
  replay-only arms. This also makes the twin robust to imperfectly complemented
  guards (an overlap cannot create ambiguity across phases, only a deterministic
  live-first preference).
  Date: 2026-07-23

- Decision: The computed twin guard is expressed in the existing DSL grammar via a
  total `complementExpr` — no `ENot` grammar extension.
  Rationale: `Expr` is `EOr | EAnd | ECmp | EAtom` with no negation constructor
  (`keiro-dsl/src/Keiro/Dsl/Grammar.hs:238-246`), but negation is eliminable:
  De Morgan over `EOr`/`EAnd`, comparison-operator flipping (`OpEq`↔`OpNeq`,
  `OpLt`↔`OpGe`, `OpLe`↔`OpGt`), boolean-literal flip, and `x == false` for a bare
  boolean atom. So `old ∧ ¬new` is printable as a parse-valid guard today, keeping
  the advisory paste-ready without touching the expression grammar (and keeping the
  fold-fingerprint and validator surfaces unchanged for unrelated specs).
  Date: 2026-07-23

- Decision: M1 validator audit table (plan step 5's include/exempt call per
  check, as shipped in keiki 0.3.0.0):
  `delta`/`omega`/`step`/`stepEither` — filter `mode e == Live` (forward path);
  `applyEvent`/`applyEventStreamingEither` — two-phase live-then-replay-only,
  ambiguity judged per phase, rejection summaries enumerate all edges;
  `checkTransitionDeterminism`/`checkTransitionDeterminismPure`/
  `determinismWarnings`/`isSingleValuedSym` — Live/Live pairs only (only live
  edges compete in forward dispatch; a replay-only overlap cannot cause
  forward ambiguity);
  `inversionAmbiguityWarnings` — same-mode pairs only (cross-mode resolved by
  phase order);
  `hiddenInputWarnings`/`checkHiddenInputs`/`headRecoverabilityWarnings` —
  unchanged (recovering inputs from outputs is a replay-only edge's whole job);
  `guardImpliesInputReadWarnings` — unchanged (guard/update/output input reads
  are evaluated during inversion too; crash-safety still applies);
  `stateChangingEpsilonWarnings` — unchanged (an ε replay-only edge can never
  be selected by inversion either — the Settled arm requires a head output —
  so it is inert on both paths; the DSL-level `ReplayOnlyEmitsNothing` error
  in M3 is the proper gate for that authoring mistake);
  `opaqueGuardWarnings` — unchanged (opaque guards under-verify replay-only
  edges identically);
  `checkDeadEdges`/`reachableVertices`/`checkDeadEdgesSym` — unchanged (see
  Surprises: both flag reasons remain genuine defects for replay-only edges,
  and traversal must keep following replay-only targets).
  Also shipped: `EdgeMode` `Semigroup`/`Monoid` (`Live` identity, `ReplayOnly`
  absorbing) as the composition rule — `compose`'s product/chain edges,
  `alternative`'s arm lifts, the profunctor rewrites, and `withSymPred` all
  propagate mode; `Keiki.Builder` gained a `peMode` field on `PartialEdge` and
  the `replayOnly` body combinator (chosen over a smart constructor: existing
  sites set `mode = Live` explicitly, keeping the diff mechanical and grep-able).
  Date: 2026-07-23

- Decision: The plan's red-then-green checkpoint (write the keiro B-bad test
  before M1) was resequenced: M1 landed first, and the B-bad failing evidence
  is captured during M2 before the twin is wired. Machine B-bad uses no new
  keiki feature, so the failing transcript is byte-identical either way, and
  the keiki-level `ReplayOnlySpec` already pins the same reproduction
  (`machineBBad` → `ReplayNoInvertingEdge`) upstream.
  Date: 2026-07-23

- Decision: Replay-only edges do not stack indefinitely by default guidance — the
  documented lifecycle ends in retirement.
  Rationale: Each tightening can add a twin; over years a state could accrete
  replay-only history arms. The guide text this plan ships states the endgame: once
  every stream containing the region's events is terminal or truncated (the same
  condition as event retirement, docs/plans/139), the replay-only edge can be deleted —
  and the replay audit (docs/plans/142) is the tool that proves the condition. This
  mirrors upcasters: rungs are forever *while payloads at their version persist*, not
  forever absolutely.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation. At completion, feed the replay-only
semantics into the evolution-gate inventory ADR: guard tightening — advised at diff
with a computed remedy, checked by the targeted audit, resolved by a replay-only twin
or truncation.)


## Context and Orientation

Repositories: keiro at `/Users/shinzui/Keikaku/bokuno/keiro` (packages `keiro-core`,
`keiro`, `keiro-dsl`, `jitsurei`); keiki — the pure symbolic state-machine library —
at `/Users/shinzui/Keikaku/bokuno/keiki`, consumed as a released package
(`keiki >=0.2 && <0.3` in `keiro/keiro.cabal` and `keiro-core/keiro-core.cabal`).
Upstream keiki work is in scope for keiro plans when the fix belongs upstream (master
plan 9 precedent; master plan 24 restates it).

The keiki facts this plan builds on (verified 2026-07-23 against source):

* `Edge` is a four-field GADT record — `guard :: phi`,
  `update :: Update rs w ci` (existential `w`), `output :: [OutTerm rs ci co]`,
  `target :: s` (`keiki/src/Keiki/Core.hs:656-663`). `SymTransducer` exposes
  `edgesOut :: s -> [Edge phi rs ci co s]` (`Core.hs:667-672`), and **every** engine
  path iterates `edgesOut`: forward stepping (`delta`/`step`/`stepEither`,
  `Core.hs:916,939,951,1010-1017`), inversion
  (`applyEventStreamingEither`, `Core.hs:1222`), and the static checks
  (`Core.hs:1514,1932`).
* Inversion is solve-then-check: candidates are edges whose first output solves the
  stored event (`solveOutput o regs co`) *and* whose guard models the solved command
  (`models (guard e) (regs, ci)`) — `Core.hs:1223-1229`. Exactly one candidate applies
  its writes; zero is `ReplayNoInvertingEdge`; several is
  `ReplayAmbiguousInversions` (`Core.hs:1191-1220`).
* The dead-edge check (`PossiblyDeadEdge`) is structural reachability plus a
  literal-false-guard test, enabled by default and fatal at keiro's boundary
  (`Core.hs:1853-1864,1888-1891`; forced-check context in
  docs/plans/139's Context section).
* The static inversion-ambiguity check is guard-blind by design: any same-vertex
  edge pair sharing a first-output wire constructor is flagged, with the haddock
  stating it "cannot prove semantic guard disjointness"
  (`Core.hs:2180-2225`; `checkInversionAmbiguity = True` default at
  `Core.hs:1840,1861`). This is why inversion must be two-phase (Decision Log) —
  a single-phase design would have every live/twin pair refused at startup.
* The DSL guard grammar has no negation constructor — `Expr` is
  `EOr | EAnd | ECmp | EAtom`, comparisons carry `OpEq/OpNeq/OpLt/OpLe/OpGt/OpGe`
  (`keiro-dsl/src/Keiro/Dsl/Grammar.hs:238-258`) — but complement is total by
  structural elimination (Decision Log), so the printed twin re-parses today.

The keiro facts:

* Aggregates and process-manager sagas share one hydrate path
  (`keiro/src/Keiro/Command.hs:286-338`; `keiro/src/Keiro/ProcessManager.hs:471-477`),
  so the edge mode automatically serves both keiki use cases (commands and actions).
* Replay failures surface as `HydrationReplayFailed` with reasons including
  `HydrationNoInvertingEdge` (`Command.hs:199-208,457-462`).

The DSL facts:

* `Transition` carries `tSource`, `tCommand`, `tGuard`, `tWrites`, `tEmits`, `tGoto`
  (`keiro-dsl/src/Keiro/Dsl/Grammar.hs`, cited in docs/plans/138's fingerprint
  milestone). The scaffolder lowers transitions to keiki edges in `Scaffold.hs`
  (aggregate path around the codec/stream emission, `Scaffold.hs:1529-1700` region —
  the exact lowering site is located during M3; it is the function that builds the
  generated `edgesOut`).
* Sibling ownership (master plan 24, Integration Points): `Scaffold.hs` shares are
  split between docs/plans/138 (`stateCodecExpr`), docs/plans/140 (upcaster lowering,
  workqueue), docs/plans/142 (audit-target emission) — this plan adds the transition
  lowering's mode argument and must not reformat neighbours. `Diff.hs` shares:
  docs/plans/138 (`AggFoldSurfaceChanged` transition-surface advisory — this plan
  *extends that advisory's text* with the computed twin, coordinating directly with
  138's `transitionSurfaceDiff`), docs/plans/139 (deprecation/upcaster),
  docs/plans/142 (decide-surface). `DiagnosticCode` additions stay append-only.
* docs/plans/139's Decision Log sanctions the guarded-but-inert retained edge for
  event retirement; its wording explicitly anticipates reconciliation ("the sanctioned
  retained-edge shape") — this plan's close-out updates that guidance to prefer
  `replay-only` once available, in whichever plan lands second.

Relevant guides: `docs/guides/evolution-and-replayability.md` ("Changing decisions"
section documents the hazard; this plan adds the remedy and flips its "no gate"
wording); `docs/guides/adopting-keiro-from-tan-event-source.md` (the black-acuity
worked example and the engineer-facing framing; cites this plan as planned).

Relevant ADRs: only `docs/adr/0001-…pgmq…` exists (unrelated). The evolution-gate
inventory ADR may exist by execution time (docs/plans/139); add this plan's rows to it
at close-out.

Term definitions. "Guard tightening" — a spec change where the new guard's region is a
strict subset of the old (some previously accepted (registers, command) valuations are
now rejected). "Removed region" — `old-guard ∧ ¬new-guard`, the valuations that were
legal and no longer are. "Replay-only twin" — a transition carrying the removed region
as its guard with the original emits/writes/target, marked `replay-only`. "Live edge" —
an ordinary edge (mode `Live`), served by forward stepping.


## Plan of Work

### Milestone 1 — the keiki edge mode

Scope: keiki learns `EdgeMode`; forward stepping skips `ReplayOnly` edges; inversion
and ambiguity checks keep them; reachability exempts them. At the end, the semantics
exist and are proven at the keiki level.

Working tree `/Users/shinzui/Keikaku/bokuno/keiki`. In `src/Keiki/Core.hs`:

1. Add `data EdgeMode = Live | ReplayOnly` (derive `Eq`, `Show`) with haddocks stating
   the contract: a `ReplayOnly` edge is never taken by forward stepping — it exists so
   events emitted under a retired rule keep an inverting edge; its writes define how
   those historical events fold *today*.
2. Add `mode :: EdgeMode` to the `Edge` record (`Core.hs:656-663`). This is a breaking
   record change; fix every construction site the compiler flags (default existing
   sites to `Live`; provide a `liveEdge` smart constructor or pattern synonym if the
   sites are numerous — pick whichever keeps the diff smallest and record the choice).
3. Forward stepping: in the `delta`/`step`/`stepEither` candidate comprehensions
   (`Core.hs:916,939,1017,1079` — follow every forward consumer of `edgesOut` found by
   grep; the static forward-behaviour checks that model "which edge fires next" count
   as forward consumers) add `mode e == Live` to the candidate filter.
4. Inversion: `applyEventStreamingEither` (`Core.hs:1191-1229`) becomes two-phase per
   the Decision Log: compute `matched` over `Live` edges; if empty, recompute over
   `ReplayOnly` edges; ambiguity (`ReplayAmbiguousInversions`) is judged within the
   phase that produced candidates. The `ReplayNoInvertingEdge` rejection summary
   reports both phases' rejections so diagnostics stay complete.
5. Checks: the dead-edge/reachability check (`Core.hs:1853-1891` region) skips
   `ReplayOnly` edges (forward-unreachable is their definition, not a defect); the
   static `inversionAmbiguityWarnings` (`Core.hs:2188-2225`) adds a same-mode
   condition to its pair comprehension — cross-mode pairs are resolved by phase order,
   same-mode pairs stay flagged exactly as today. The hidden-input analysis
   (`checkHiddenInputs`, `Core.hs:1503-1516`) applies to replay-only edges unchanged
   (their outputs must still recover their inputs — that is their whole job). Audit
   the remaining validator checks one by one and decide include/exempt with a
   one-line rationale each; record the table in this plan's Decision Log.
6. Tests (keiki suite): forward stepping never selects a `ReplayOnly` edge even when
   its guard models the command (command in the removed region is rejected/unmatched);
   inversion selects it for a historical event; an ambiguous live/replay-only pair is
   still flagged; the dead-edge check passes a machine whose only path to an event is
   a replay-only edge.
7. Version: `Edge` gained a field — PVP-major. Bump `keiki.cabal` accordingly
   (0.3.0.0 if still on 0.2.x at execution time — verify against the registry, which
   may have moved for docs/plans/138's 0.2.1.0), CHANGELOG entry. Coordinate with
   docs/plans/138's keiki release: if both are in flight, land as one release train.

Acceptance: `cabal test keiki-test` green from the keiki repo root with the new
examples.

### Milestone 2 — keiro end-to-end proof

Scope: keiro consumes the new keiki; the black-acuity scenario is a pinned regression
test. During development point keiro at the local keiki checkout via
`cabal.project.local` (`packages: ../keiki`, not checked in; delete after the keiki
release is published — same procedure as docs/plans/138 M1).

Follow the compile errors from the keiki bump through keiro: `EventStream`
construction sites build edges — supply `Live` everywhere except where a test wants
otherwise (keiro-core's `EventStream` wraps keiki's transducer; if keiro-core exposes
its own edge-building helpers, thread the mode with a `Live` default so existing
services compile unchanged).

Add the regression test in `keiro/test/Main.hs` (store-backed, `withMigratedSuite`
fixture, same conventions as docs/plans/142's audit tests): build machine A (guard
`open`), append a history including a black-acuity confirmation; build machine B-bad
(guard tightened, no twin) and machine B-good (tightened live edge + `ReplayOnly` twin
carrying the removed region). Assert: hydration under B-bad fails with
`HydrationNoInvertingEdge`; hydration under B-good succeeds and equals machine
B-good's full replay; a *new* command in the removed region is rejected under B-good
(the twin does not resurrect the old behaviour); and the replay audit of
docs/plans/142 — if landed — reports B-bad `ReplayFailed` and B-good `ReplayOk` over
the same store (soft dependency; skip the audit assertions if 142 has not landed and
note it in Progress).

Acceptance: `cabal test keiro-test` green against the local keiki; the four
assertions listed are present and pass.

### Milestone 3 — the DSL marker and the diff-computed twin

Scope: the pattern becomes one keyword plus a paste. At the end, `keiro-dsl` parses,
validates, prints, scaffolds, and *suggests* replay-only transitions.

Grammar/parse/print: add `tMode :: !TransitionMode` (`Live` default / `ReplayOnly`)
to `Transition` in `keiro-dsl/src/Keiro/Dsl/Grammar.hs`; accept `replay-only
transition …` in the parser where `transition` is accepted; round-trip in
`PrettyPrint.hs`; fix construction sites the compiler flags.

Validator (`Validate.hs`, append-only codes as usual): `ReplayOnlyEmitsNothing`
(Error — a replay-only transition with no emits inverts nothing and is dead weight);
`ReplayOnlyCommandStillLive` (Warning — a replay-only transition whose
(source, command) pair has no live sibling: the command has been retired entirely;
legitimate, but the message points at event retirement — docs/plans/139 — as the
fuller procedure). The fold fingerprint of docs/plans/138 includes the mode in its
canonical transition rendering (coordinate: if 138 lands first, extend its rendering
here; if this plan lands first, note the field for 138 to include).

Scaffold: the transition-lowering site emits the keiki mode (`ReplayOnly` for marked
transitions); regenerate conformance fixtures; confirm generated `edgesOut` carries
the mode.

Diff (coordinating with docs/plans/138's `transitionSurfaceDiff`, which owns the
guard-change advisory): when a paired transition's guard *strictly tightens* — detect
conservatively: guard text changed AND the new spec does not already contain a
replay-only twin for the pair — extend the `AggFoldSurfaceChanged` advisory detail
with the computed remedy, pretty-printed and paste-ready:

```text
guard changed on Held -- ConfirmReservation. If stored events were written under
the old guard, they will no longer invert. Either confirm via the replay audit
that no stored stream exercises the removed region, or keep history replayable
by adding:

  replay-only transition Held -- ConfirmReservation
    guard (divertStatus == open) && !(divertStatus == open && patientAcuity != black)
    ...same emits/writes/goto as the previous version...
```

(The twin's guard is the mechanical `old ∧ complement(new)`, where `complementExpr`
eliminates negation inside the existing grammar — De Morgan, comparison-operator
flip, `x == false` for bare boolean atoms; see the Decision Log. Simplification of
the printed predicate is nice-to-have, not required — correctness over beauty. The
"same emits/writes/goto" line is filled with the *old* spec's actual clauses, which
diff has. The printed guard shown above is illustrative; the real output is whatever
`complementExpr` yields, and a test asserts it re-parses.) Fixtures: a tightened-guard pair asserting the advisory contains
`replay-only transition`; a pair where the twin is already present asserting the
advisory omits the remedy; a `replay-only`-marked spec scaffolding to a machine whose
generated code carries the mode.

Docs shipped with this milestone (this plan owns its own remedy docs; docs/plans/141
owns the four legacy documents): update
`docs/guides/evolution-and-replayability.md`'s "Changing decisions" section — the
"keep an edge that inverts them" prescription becomes the `replay-only` procedure
with the lifecycle endgame (delete the twin once affected streams are terminal or
truncated; the audit proves it) — and flip
`docs/guides/adopting-keiro-from-tan-event-source.md`'s plan-143 citations to present
tense. Reconcile docs/plans/139's guarded-but-inert wording per its Decision Log
(whichever plan lands second performs the edit).

Acceptance: all 24 keiro-dsl suites green; the diff spot check prints the paste-ready
twin; `cabal test keiro-test` and keiki suite green; CHANGELOG entries (keiki, keiro,
keiro-dsl).


## Concrete Steps

```bash
# M1 — keiki
cd /Users/shinzui/Keikaku/bokuno/keiki
cabal build keiki && cabal test keiki-test

# M2 — keiro against local keiki
cd /Users/shinzui/Keikaku/bokuno/keiro
printf 'packages: ../keiki\n' > cabal.project.local
cabal build keiro-core keiro
cabal test keiro-test

# M3 — DSL
cabal build keiro-dsl
cabal test keiro-dsl-test
cabal run -v0 keiro-dsl -- diff <tightened-guard-fixture>.keiro --since <ref>   # shows the twin
cabal test keiro-dsl          # all 24 suites
```

Red-then-green checkpoints: write the M2 black-acuity test against machine B-bad
*before* M1 exists (it fails with `HydrationNoInvertingEdge` — that failing transcript
is the reproduction of the concern this plan exists for; paste it into Surprises &
Discoveries); after M1/M2, B-good turns it green. In M3, run the guard-tightening
diff before the advisory extension and record that today it prints no remedy.


## Validation and Acceptance

(1) keiki: forward stepping never fires a `ReplayOnly` edge; inversion uses it;
ambiguity and dead-edge checks behave per the M1 table. (2) keiro: the black-acuity
regression — history under the old guard replays under the twin-bearing machine,
fails without the twin, and new removed-region commands are rejected. (3) DSL: the
marker round-trips parse→print; scaffolding carries the mode into generated code; the
tightening advisory prints a paste-ready twin exactly when no twin exists. (4) The
combined bar: keiki suite, `keiro-test`, and all 24 keiro-dsl suites green. (5) The
guide's "Changing decisions" section describes the procedure in present tense and the
adoption doc's citations are flipped.


## Idempotence and Recovery

All code changes are additive-in-behaviour (existing edges default to `Live`; a spec
with no `replay-only` marker generates byte-identical semantics), so partial landing
is safe: keiki's mode can ship with nothing using it. The keiki record change is the
one breaking edit — it lands behind a PVP-major bump and keiro adopts it explicitly;
`cabal.project.local` keeps development unblocked while the release is pending, and
must be deleted before merge (same discipline as docs/plans/138). If the DSL milestone
stalls, M1+M2 already deliver the semantics for hand-written services; record the
split in Progress. Rolling back a deployed replay-only twin re-creates exactly the
break it fixed (stored events lose their inverting edge) — the twin's lifecycle rule
(delete only when affected streams are terminal/truncated, proven by the audit) is
the guard against that, and the CHANGELOG entry states it.


## Interfaces and Dependencies

At the end of M1, keiki exports `EdgeMode (..)` and `Edge` carries `mode :: EdgeMode`;
forward stepping filters `Live`, inversion does not filter. At the end of M3,
`Keiro.Dsl.Grammar.Transition` carries `tMode :: TransitionMode`, the parser accepts
`replay-only transition`, `DiagnosticCode` gains `ReplayOnlyEmitsNothing` and
`ReplayOnlyCommandStillLive`, and the `AggFoldSurfaceChanged` advisory prints the
computed twin. Dependencies: keiki PVP-major release (coordinate with
docs/plans/138's keiki work — one release train if concurrent); no new third-party
packages. Coordination: docs/plans/138 (fingerprint includes mode; shared advisory),
docs/plans/139 (retained-edge wording reconciliation), docs/plans/142 (the audit is
both the checker for "does stored data exercise the removed region" and the prover
for the twin-deletion endgame; its black-acuity audit assertions activate when both
plans are landed). Guides owned: the two documents named in M3.
