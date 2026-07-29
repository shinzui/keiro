---
id: 153
slug: add-the-service-workspace-manifest-loader-composed-graph-and-whole-service-check-to-keiro-dsl
title: "Add the service workspace manifest, loader, composed graph, and whole-service check to keiro-dsl"
kind: exec-plan
created_at: 2026-07-29T14:09:13Z
intention: "intention_01kyq39tsbepwt43q6db89h0d7"
master_plan: "docs/masterplans/26-composable-multi-file-service-workspaces-for-keiro-dsl.md"
---

# Add the service workspace manifest, loader, composed graph, and whole-service check to keiro-dsl

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today every `keiro-dsl` command takes exactly one `.keiro` file. A service that keeps each
aggregate in its own file — the way the Kotei repository keeps one aggregate per
`kdsl/*.keiro` file, all declaring `context kotei` — has no way to validate those files as
one service. Separate invocations do not share ID declarations, enums, mapped structural
types, or a resolved type graph, so nothing can catch a duplicate aggregate name across
files, a shared `ProjectId` declared twice, or an aggregate in one file referencing an enum
declared in another.

After this plan, a user can write a small **workspace manifest** — a `.keiro-workspace`
file naming the service and listing its member `.keiro` files — and run:

```bash
cabal run keiro-dsl -- check path/to/service.keiro-workspace
```

and get one whole-service validation: every member parses with the unchanged `.keiro`
grammar, shared declarations resolve once across all members, cross-file references (an
aggregate in file A using an enum, id, or mapped type declared in file B; a read model in
file A feeding from an aggregate in file B) resolve exactly as if the files were one spec,
and every conflict — context disagreement, duplicate declarations even when textually
identical, an aggregate defined in two files, case-folded generated-path collisions across
members — is refused with a diagnostic that cites every relevant file and line.
`keiro-dsl parse` on the manifest pretty-prints it back in canonical form, proving the
round trip. A single `.keiro` file continues to behave exactly as today.

This is EP-1 of MasterPlan 26
(`docs/masterplans/26-composable-multi-file-service-workspaces-for-keiro-dsl.md`), the
foundation the other three child plans compile against: EP-2 (plan 154, workspace
scaffolding) consumes the composed `WorkspaceSpec` and its per-declaration/per-node
ownership; EP-3 (plan 155, workspace diff) consumes the same graph plus this plan's
content-source abstraction so it can load a workspace from `git show` blobs; EP-4
(plan 156) proves fleet adoption end to end. This plan implements exactly the first three
Progress milestones of the MasterPlan and nothing from the later plans: **no scaffold
changes, no diff changes, no adoption/migration work.**


## Progress

- [x] M1: `Keiro.Dsl.Workspace` module created with the manifest AST, megaparsec parser,
      and canonical pretty-printer; module added to `exposed-modules` in
      `keiro-dsl/keiro-dsl.cabal`. (2026-07-29)
- [x] M1: `keiro-dsl parse` dispatches on the `.keiro-workspace` extension and round-trips
      the manifest canonically; `check`, `scaffold`, and `diff` on a manifest print explicit
      staged-refusal messages naming plans 154/155 (check's refusal is replaced in M3).
      (2026-07-29)
- [x] M1: Manifest unit and property tests green (round trip, canonical sorting, duplicate
      member refusal, invalid path refusal, missing `service` refusal) — 13 refusal cases
      plus the round-trip property; suite at 319 examples, 0 failures. (2026-07-29)
- [x] M1: Workspace ADR allocated with `okf id next` (`ADR-14`, confirmed by the command,
      never guessed), written as
      `docs/adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md`,
      `docs/adr/log.md` advanced with `okf log add`, `just adr-validate` green
      (`OK: 14 concepts`). (2026-07-29)
- [x] M1: Positive fixture workspace authored at `keiro-dsl/test/fixtures/workspace/`
      (manifest plus `domain/shared.keiro`, `domain/project.keiro`,
      `domain/project-artifact.keiro`); each member parses standalone and its residual
      standalone diagnostics are exactly the cross-file references the workspace must
      resolve. (2026-07-29)
- [x] M2: `ContentSource` abstraction plus `fileContentSource`; `loadWorkspace` reads the
      manifest and all members through it, collecting every member read/parse failure
      rather than failing fast. (2026-07-29)
- [x] M2: Pure `composeWorkspace` producing `WorkspaceSpec` (merged spec, line map,
      ownership index, effective context/module-root/layout) or multi-location refusals for
      every refusal class listed in Milestone 2. (2026-07-29)
- [x] M2: Generic `Loc` relocation and line map land; merged-spec `validateSpec`
      diagnostics resolve back to member `file:line`. Completeness is compiler-enforced:
      the `HasLocs` instance list covers all 96 `Grammar` types and a new AST type is a
      build error until listed. (2026-07-29)
- [x] M2: Cross-member case-folded generated-path collision refusal at compose/check time
      (fixture `workspace-path-collision/`, aggregates `Run` and `RUn` in different
      members). (2026-07-29)
- [x] M2: API-level tests green: cross-file reference resolution on the positive fixture,
      one-member-workspace equivalence property, member-order permutation determinism,
      relocation completeness, and one test per refusal class asserting the exact
      `DiagnosticCode` and the exact set of cited files. Suite at 334 examples, 0
      failures. (2026-07-29)
- [x] M3: `keiro-dsl check <manifest>` wired through the dispatch with multi-file
      diagnostic rendering; `--emit`, `--explain-bindings`, and coverage flags work against
      the merged graph. (2026-07-29)
- [x] M3: Positive fixture workspace and one negative fixture workspace per refusal class
      under `keiro-dsl/test/fixtures/`, each asserted by exact `DiagnosticCode` (the two
      manifest-boundary fixtures by exact refusal message — see the M2 Decision Log entry
      on why those carry no code). (2026-07-29)
- [x] M3: Full existing suite green with zero changes to existing fixtures or golden bytes
      (`git diff --name-status b0a4875 -- keiro-dsl/test/` shows `M` only for the test
      driver `Main.hs`; every fixture line is an addition); `CHANGELOG.md` updated;
      MasterPlan 26 registry row and Progress entries ticked. (2026-07-29)
- [ ] Final: ADR distillation pass done; Outcomes & Retrospective written.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **`okf log add` does not accept `--profile`.** This plan's Concrete Steps quoted
  `okf log add docs/adr --profile docs/adr/profile.dhall <file> "<message>"`; the real
  interface is `okf log add BUNDLE [CONCEPT_ID] [--kind KIND] (-m|--message MESSAGE)
  [--date YYYY-MM-DD]`. The working invocation is below; Concrete Steps has been corrected.

  ```text
  $ okf log add docs/adr --kind Added -m "Record the service workspace identity, …"
  Wrote log.md for 2026-07-29
  $ just adr-validate
  OK: 14 concepts
  ```

  Note `just adr-validate` fails with `timestamp date … is newer than log.md newest entry`
  until the log is advanced, so the two steps are not independently skippable.
  (2026-07-29)

- **The positive fixture's members are individually invalid in exactly the right way.**
  Checking each member alone leaves precisely the diagnostics that only the workspace can
  resolve, which is direct evidence that M3's composed check is doing real cross-file work
  rather than re-running three independent checks:

  ```text
  $ cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workspace/domain/project.keiro
  …project.keiro:16: error[GuardAtomOutOfScope]: atom 'Active' … resolves to no register, command field, enum constructor, or rule
  …project.keiro:21: error[GuardAtomOutOfScope]: atom 'Retired' … resolves to no register, command field, enum constructor, or rule
  …project.keiro:28: warning[RmProjectionWithoutNode]: projection 'project_activity' has no readmodel node…
  $ cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workspace/domain/project-artifact.keiro
  …project-artifact.keiro:3: error[RmInlineFeedUnreferenced]: readmodel 'project_activity' declares feed = inline but no aggregate projection references it
  …project-artifact.keiro:25: error[GuardAtomOutOfScope]: atom 'Active' … resolves to no register, command field, enum constructor, or rule
  ```

  `domain/shared.keiro` alone prints `OK` — a declarations-only member is self-contained.
  (2026-07-29)

- **Two distinct "no service" refusals, not one.** An empty manifest cannot name an
  offending clause, so it gets `workspace manifest must begin with a 'service <name>'
  clause`, while a manifest that starts with any other clause gets `the first clause of a
  workspace manifest must be 'service <name>'` positioned at that clause. Both are pinned
  by tests. (2026-07-29)


## Decision Log

- Decision: The workspace manifest is a line-oriented file with extension
  `.keiro-workspace` and four clause kinds — `service <name>` (mandatory, first),
  optional `module <Prefix>` and `layout prefixed|collocated`, and one or more
  `spec <relative-path>` member lines — with `#` comments and blank lines as whitespace,
  in the spirit of the existing DSL's keyword-driven notation. Membership is a set:
  the loader canonically sorts member paths (codepoint order on the normalized relative
  path) before composing, and the pretty-printer emits them sorted, so declaration order
  never changes semantics or bytes. Duplicate member paths — including two paths equal
  under Unicode case folding — are refused.
  Rationale: MasterPlan 26's Decision Log already fixes "manifest file, not flags"
  (because `diff --since <rev>` must reconstruct membership from git alone and the
  scaffold record needs one durable identity). A line-oriented grammar keeps the manifest
  reviewable in one glance and trivially parseable at any git revision; canonical sorting
  implements IR-2's determinism principle ("source order must not change its meaning or
  generated bytes") at the earliest possible point; case-folded member duplicates are
  refused for the same reason generated paths are — macOS's default filesystem is
  case-insensitive, so two such paths can silently be one file.
  Date: 2026-07-29

- Decision: CLI input dispatch is extension-based: a `FILE` argument ending in
  `.keiro-workspace` is a workspace manifest; anything else takes the existing single-file
  code path, which this plan does not modify. In M1, `scaffold` and `diff` given a
  manifest print an explicit refusal naming the owning plan
  ("workspace scaffolding lands in docs/plans/154-…", "workspace diff lands in
  docs/plans/155-…") and exit non-zero; `check` gets the same staged refusal in M1 and
  the real implementation in M3.
  Rationale: the MasterPlan's Integration Points fix that all commands share one dispatch
  on the same positional `FILE` with no parallel flags or subcommands, and propose
  extension dispatch. Content sniffing was rejected: a file's role must not depend on
  which parser happens to succeed, and a corrupted manifest must produce a manifest parse
  error, not a confusing `.keiro` parse error. Keeping the single-file branch untouched
  is the strongest possible guarantee of "existing behavior unchanged"; the one-member
  equivalence claim is proven at the API level instead (see the equivalence decision
  below). Explicit staged refusals prevent the misleading megaparsec error a manifest
  would otherwise produce when handed to `parseSpec`.
  Date: 2026-07-29

- Decision: Authority rule for `module` and `layout`: the manifest clause, when present,
  is the workspace authority, and each member's clause must be **absent or exactly
  equal** to it; any disagreement is a refusal citing the manifest clause line and the
  member clause line. When the manifest is silent on a clause, all members that declare
  it must agree unanimously (refusal cites every disagreeing member), and the unanimous
  value (or absence) is the effective value. `context` has no manifest clause: it is
  mandatory in every member's grammar already, so the effective context is the members'
  unanimous `context` declaration, and any mismatch is a refusal citing every member's
  context clause.
  Rationale: "absent or exactly equal" never silently overrides a clause an author wrote
  (the no-silent-merge stance from MasterPlan 26's Decision Log, applied to policy
  clauses), while not forcing existing members to be edited during adoption: Kotei's
  members carry no module/layout clauses (authority can live wholly in the manifest) and
  Danwa's single file declares `layout collocated` (the clause may stay when the file
  becomes a member). A manifest `context` clause would be pure duplication of a fact the
  member grammar makes mandatory, creating a second authority that can only ever agree
  or conflict — so it is deliberately omitted. The effective values are stored in the
  merged spec's `specModuleRoot`/`specLayout` fields, so `mkContext` in
  `keiro-dsl/app/Main.hs` (precedence: CLI flag > spec clause > built-in default) keeps
  working unchanged when EP-2 retargets `scaffold`.
  Date: 2026-07-29

- Decision: Composition builds one **merged `Spec`** (workspace context/module/layout
  plus all members' declarations and nodes concatenated in canonical member order) and
  runs the existing `validateSpec` on it once. Multi-file attribution works by **`Loc`
  relocation**: each member's AST has every `Loc` shifted into a disjoint line range
  (member *i*'s lines 1..nᵢ map to baseᵢ+1..baseᵢ+nᵢ, baseᵢ = the sum of earlier
  members' line counts), recorded in a line map; any diagnostic line from the merged
  spec resolves uniquely back to `(member file, original line)`. Lines that fall in no
  member range (e.g. `noLoc` = 0) resolve to the manifest path. The `context`, `module`,
  and `layout` clause spans, which the `Spec` AST does not record (`specContext` is a
  bare `Name` with no `Loc`), are found for refusal diagnostics by a textual scan of the
  member source for the first non-comment line beginning with the clause keyword —
  diagnostics-only, never semantics. `Keiro.Dsl.Validate` and its `Diagnostic` type are
  not modified.
  Rationale: this resolves cross-file references for free (validation is name-based over
  one `Spec`), guarantees whole-service check runs **all** existing node-specific
  validation with zero divergence risk, and avoids churning the 1600-line `Validate.hs`
  and every `mkErr` call site. It is semantic composition, not textual inclusion (IR-2
  design principle 3): only the AST's line numbers move, exactly like a compiler line
  map. `Loc`'s `Eq` instance deliberately ignores the line
  (`keiro-dsl/src/Keiro/Dsl/Grammar.hs` line 156), so relocation cannot change any
  equality-based behavior. Extending `Spec` with clause `Loc`s was rejected as
  needless churn across every `Spec` construction site for a diagnostics-only need.
  Date: 2026-07-29

- Decision: Compose-time refusals reuse the existing append-only `DiagnosticCode`
  registry in `keiro-dsl/src/Keiro/Dsl/Validate.hs` (new constructors appended at the
  end), carried by a new `WorkspaceDiagnostic` type in `Keiro.Dsl.Workspace` whose
  location is a non-empty list of `(FilePath, line)` pairs. Rendering keeps the
  established single-line `<file>:<line>: error[<Code>]: <message>` shape for the
  primary location, with each additional location on an indented continuation line
  `  <file>:<line>: note: <role>`.
  Rationale: ADR-4 makes the shared machine-checkable code registry the correlation
  point between gates; inventing a parallel workspace code enum would break that.
  `Workspace` importing `Validate` creates no cycle (`Validate` never imports
  `Workspace`). The rendering extends, rather than replaces, the format every existing
  consumer and test greps for.
  Date: 2026-07-29

- Decision: At compose/check time the generated-path collision refusal covers only
  collisions **across members** (two colliding planned modules owned by nodes in
  different member files). A collision entirely within one member remains scaffold-time
  behavior, exactly as today.
  Rationale: IR-2 requires cross-file collisions to surface at composition (per ADR-4,
  the earliest boundary with enough evidence — both owning files are only visible to the
  composer), but a single `.keiro` file with an intra-file collision passes `check`
  today and fails at `scaffold`; pulling that forward would change existing single-file
  behavior, which this plan is forbidden to do. One-member workspaces therefore have no
  cross-member pairs and are unchanged by construction.
  Date: 2026-07-29

- Decision: `check --emit`, `check --explain-bindings`, and `check --coverage-report`
  (with `--fail-on-opaque`) all work against the merged graph in M3; none are deferred.
  `--emit` prints `renderSpec` of the merged spec (the canonical whole-service view);
  `--explain-bindings` runs `bindingObligations` on the merged spec (its output is
  context- and symbol-oriented, with no file/line rendering); coverage runs
  `Coverage.coverageReport` with the **manifest path** as the report's spec path.
  Rationale: all three are pure functions of `Spec` and are correct on the merged spec
  by the same argument as `validateSpec`. Coverage attribution is honest without any
  change to `Coverage.hs`: verified 2026-07-29 that `CoverageFinding`
  (`keiro-dsl/src/Keiro/Dsl/Coverage.hs`, line 124) carries root names
  (`findingRoots`) and no line numbers, so naming the manifest as the report subject
  misleads nobody. Per ADR-13, coverage stays reporting-first: the merged report
  aggregates; no new gate is invented.
  Date: 2026-07-29

- Decision: Member paths in the manifest must be relative, use forward slashes, end in
  `.keiro`, and resolve inside the manifest's directory tree (no absolute paths, no
  `..` segments, no drive letters). A manifest may not list another manifest.
  Rationale: EP-3 must reconstruct members at a git revision from
  `git show <rev>:<repo-relative-path>`; a path escaping the repository cannot be
  reconstructed at all, and one escaping the manifest directory complicates the
  identity story for no fleet need (Kotei and Danwa both keep specs under one
  directory). Nesting manifests is order-sensitive include machinery by another name,
  which IR-2 excludes. All four rules can be relaxed additively later; none can be
  tightened later without breaking users.
  Date: 2026-07-29

- Decision: A single `.keiro` file is provably a one-member workspace via an exported
  `oneMemberWorkspace :: FilePath -> Spec -> WorkspaceSpec` constructor plus a test
  asserting `checkWorkspace (oneMemberWorkspace fp spec)` yields exactly
  `validateSpec spec` (same codes, severities, messages, and lines, attributed to
  `fp`) — while the CLI keeps routing bare `.keiro` files through the untouched
  existing branch.
  Rationale: this satisfies IR-2's "single-file use remains valid ... as a one-member
  service workspace" as a checked semantic property, gives EP-2/EP-3 the uniform
  input type they need for the fallback, and still guarantees byte-identical behavior
  for every existing user because the old code path literally did not change.
  Date: 2026-07-29

- Decision (M2, revising this plan's Interfaces list): manifest **syntax and structure**
  errors carry no `DiagnosticCode`; only **composition** refusals do. The
  `DiagnosticCode` enum therefore gains seven constructors — `WorkspaceMemberUnreadable`,
  `WorkspaceMemberParseFailed`, `WorkspaceContextMismatch`, `WorkspaceAuthorityConflict`,
  `WorkspaceDuplicateDeclaration`, `WorkspaceDuplicateNodeName`, `WorkspacePathCollision`
  — and **not** the originally listed `WorkspaceDuplicateMember` and
  `WorkspaceInvalidMemberPath`.
  Rationale: a malformed `.keiro` file produces a megaparsec parse error with no
  `DiagnosticCode` and never reaches `validateSpec`; a malformed manifest is exactly the
  same situation one level up, and it never reaches the composer. Adding codes for
  constructors nothing can ever emit would put dead entries in an append-only registry
  that can never be removed. The two refusals remain fully tested (M1 pins their messages
  and positions) and remain honest CLI failures; they are simply not *graph* diagnostics.
  Consequence for later plans: EP-2 and EP-3 must not expect those two codes.
  Date: 2026-07-29

- Decision (M2): a workspace diagnostic's locations store the **manifest-relative** member
  path, with an explicit `WorkspaceFile` sum distinguishing the manifest from a member,
  and the manifest's directory is joined on only at render time.
  Rationale: the manifest-relative path is the canonical identity EP-2 keys scaffold
  record ownership on and EP-3 compares across revisions — a display path baked with
  whatever the user typed on the command line is not stable. Rendering still produces the
  clickable `dirname(manifest)/member:line` the plan fixes, via
  `workspaceDisplayPath`. Without the sum, rendering could not tell a manifest citation
  (join nothing) from a member citation (join the directory).
  Date: 2026-07-29

- Decision (M2): the cross-member generated-path collision check runs the existing pure
  planner once on the merged spec and resolves each `PathCollision`'s origin strings back
  to owning members by parsing the `(line N)` suffix that
  `Keiro.Dsl.Scaffold.nodeOrigin` emits, then looking that merged line up in the line map.
  It is skipped entirely when an earlier compose stage refused, or when
  `validateSpec` on the merged spec reports any error.
  Rationale: the planner's `origin` is the only existing seam from a planned module back
  to the node that produced it, and because the merged spec's lines are already relocated
  the embedded line resolves uniquely to one member. Running the planner once (rather than
  once per member) is what makes context-level modules — the `StructuralProjections`
  facade and the replay-audit assembly, which have no line in their origin and are emitted
  exactly once for the whole context — incapable of producing a false collision. The
  validity guard exists because the scaffolder is only ever fed specs that passed
  validation; feeding it an invalid merged spec would be a new and unproven code path, and
  `checkWorkspace` reports those errors anyway.
  Date: 2026-07-29

- Decision (M2): `relocateLocs` and `collectLocs` are two uses of one generic
  `HasLocs` class whose method is an `Applicative` traversal
  (`traverseLocs :: Applicative f => (Loc -> f Loc) -> a -> f a`), instantiated at
  `Identity` for relocation and `Const [Int]` for collection.
  Rationale: one traversal cannot drift from the other, which is precisely the risk a
  separate collector would carry — the collector exists to *prove* the relocator misses
  nothing, so they must walk identically by construction. Completeness across the AST is
  enforced by the compiler rather than by review: the generic default demands a `HasLocs`
  instance for every field type, so the 96-line instance list fails to build the moment
  `Grammar` grows a type.
  Date: 2026-07-29

- Decision: Detecting "a source file assigned to two workspaces" (IR-2's cross-manifest
  rejection) is deferred out of EP-1. The composer refuses a member listed twice within
  the manifest it was given; it does not scan the repository for other manifests.
  Rationale: one invocation sees one manifest; repo-wide manifest discovery is the kind
  of dynamic discovery IR-2 itself excludes. EP-2's workspace-keyed scaffold records are
  the natural place where double assignment becomes observable (two workspaces claiming
  one member's generated modules), and the MasterPlan's Integration Points already route
  record-ownership semantics there. Recorded here so the gap is deliberate, not
  forgotten.
  Date: 2026-07-29


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

**Completed 2026-07-29.** The Purpose section's headline command works: a
`.keiro-workspace` manifest naming three member files is checked as one service, and
`cabal run keiro-dsl -- check keiro-dsl/test/fixtures/workspace/service.keiro-workspace`
prints `OK`. Every member of that fixture is individually *invalid* — `project.keiro`
uses enum constructors declared in `shared.keiro`, `project-artifact.keiro` declares an
inline-feed read model that only `project.keiro`'s projection references — so the green
result is direct evidence that composition, not three independent checks, is doing the
work. `check --explain-bindings` makes the same point in one line: a single binding
obligation lists use sites from both aggregate members against a mapped type declared in
a third.

What exists that did not before: `Keiro.Dsl.Workspace` (manifest AST, parser, canonical
renderer, `ContentSource` loader, pure `composeWorkspace`, `WorkspaceSpec` with line map
and ownership index, `checkWorkspace`, multi-file diagnostics and their rendering,
generic `Loc` relocation); seven appended `DiagnosticCode` constructors and an exported
`nodeIdentity`; extension-based CLI dispatch on all four file-taking commands with a real
`check` and honest staged refusals for `scaffold`/`diff`; twelve fixture workspaces; 39
new tests (302 → 341 examples, 0 failures); and ADR-14.

Measured against the plan's Validation and Acceptance list, all seven items hold. The one
substantive divergence is recorded in the Decision Log: manifest-boundary refusals carry
no `DiagnosticCode`, so the enum gained seven constructors rather than nine, and the two
manifest-level fixtures are asserted by exact message rather than by code. That is a
narrowing of the interface EP-2/EP-3 were told to expect and is flagged in MasterPlan 26's
Surprises section for them.

Lessons worth carrying forward:

- **Compiler-enforced completeness beat reviewed completeness.** The `HasLocs` generic
  traversal has 96 hand-listed instances, which looks like the kind of list that rots.
  It cannot: the generic default demands an instance for every field type, so a new
  `Grammar` type is a build error until listed. That is a much stronger guarantee than
  the `collectLocs`-based test alone, which only samples the fixtures it is given.

- **Merging into one `Spec` was the highest-leverage decision in the plan.** Whole-service
  validation, type-graph resolution, coverage, and binding analysis all came for free and
  are structurally incapable of diverging from the single-file path, because they are
  literally the same call. The entire multi-file story then reduces to one line map. The
  1600-line `Validate.hs` was not touched.

- **Building the positive fixture *before* the composer paid off.** Running `check` on
  each member alone produced exactly the diagnostics the workspace must resolve
  (`GuardAtomOutOfScope` for cross-file enum constructors, `RmInlineFeedUnreferenced` for
  the cross-file read-model feed), which turned "does composition work?" into a concrete,
  falsifiable list before a line of the composer existed.

- **The scaffold planner's `origin` string is load-bearing and shouldn't stay that way.**
  Recovering module ownership by parsing `(line N)` out of a display string works and is
  tested, but EP-2 owns per-module source ownership and should give it a real field;
  see MasterPlan 26's Surprises section.

Deliberate gaps, all owned elsewhere and none of them silent: workspace `scaffold` (plan
154) and workspace `diff` (plan 155) refuse with messages naming those plans; a source
file assigned to two different manifests is not detected (EP-2's record ownership is
where it becomes observable); an intra-member generated-path collision remains
scaffold-time behavior, unchanged.


## Context and Orientation

### The repository and the toolchain

This repository (`keiro`) is a Haskell cabal multi-package project (`cabal.project` at the
root lists the packages, including `keiro-dsl` and its test package `keiro-dsl/test`). The
package this plan touches is `keiro-dsl` (directory `keiro-dsl/`): the toolchain over a
typed `.keiro` specification of a keiro service — parser, checker, differ, scaffolder, and
harness emitter. A "spec" is the parsed form of one `.keiro` file. The modules that matter
here, with facts verified on 2026-07-29 (re-verify line numbers as you work; they drift):

- `keiro-dsl/app/Main.hs` — the CLI. Every command takes exactly **one** positional `FILE`
  (`fileArg`, line 143: "Path to a .keiro spec"). The commands are `parse`, `check`
  (`--emit`, `--explain-bindings`, `--coverage-report`/`--fail-on-opaque`), `scaffold`,
  `diff`, and `new` (lines 57–75). `mkContext` (lines 332–341) folds the spec's
  `module`/`layout` clauses with CLI overrides into a scaffold `Context` with precedence
  **CLI flag > spec clause > built-in default** — this precedence must survive this plan
  untouched, which is why the workspace's effective module/layout values are stored in the
  merged spec's clause fields (see Decision Log).
- `keiro-dsl/src/Keiro/Dsl/Grammar.hs` — the AST. `Spec` (line 1160) carries
  `specContext :: !Name` (one context name, no `Loc`), `specModuleRoot :: !(Maybe Text)`,
  `specLayout :: !(Maybe Placement)` (`GeneratedPrefix` | `CollocatedLeaf`), the shared
  declarations `specIds :: ![IdDecl]`, `specEnums :: ![EnumDecl]`,
  `specRules :: ![RuleDecl]`, `specMapped :: ![MappedDecl]`, and `specNodes :: ![Node]`
  (a closed sum of twelve node families). Every declaration and node carries a
  `Loc` — `newtype Loc = Loc { unLoc :: Int }` (line 156) whose `Eq` instance ignores the
  line (`_ == _ = True`), which is what makes this plan's line relocation safe. All AST
  types derive `Generic`.
- `keiro-dsl/src/Keiro/Dsl/Parser.hs` — megaparsec parser.
  `parseSpec :: FilePath -> Text -> Either ParseError Spec` (line 35; the `FilePath` is
  only the diagnostic source name). `pSpec` (line 241) parses `context <word>`, optional
  `module`/`layout` clauses, then `many pTopItem`. `reservedWords` (lines 112–194)
  contains **no** `import`, `include`, `workspace`, `service`, or `spec` keyword — and
  this plan adds none, because the manifest is a separate file format with its own
  parser. The member-file grammar does not change at all.
- `keiro-dsl/src/Keiro/Dsl/Validate.hs` — `validateSpec :: Spec -> [Diagnostic]`
  (line 301). `Diagnostic` (line 267) carries **one** line, a severity, an append-only
  machine-readable `DiagnosticCode`, and a message; `renderDiagnostic` (line 278) is
  given a single file path at render time and prints
  `<file>:<line>: error[<Code>]: <message>`. Multi-file diagnostics do not exist yet —
  creating them is this plan's job. Useful internals: `nodeIdentity :: Node -> (Text,
  Name, Loc)` (kind, name, location — export it for the composer), and
  `specLevelRules`'s duplicate-node rule which keys duplicates by `(kind, name)` — the
  cross-file duplicate-node refusal must use the same key so workspace semantics match
  single-file semantics.
- `keiro-dsl/src/Keiro/Dsl/TypeGraph.hs` —
  `resolveTypeGraph :: Spec -> Either (NonEmpty TypeGraphError) TypeGraph` builds the
  mapped-type graph once **per `Spec`** from `specMapped` and the node use sites. Because
  this plan composes one merged `Spec`, the merged workspace automatically gets one
  resolved type graph with cross-file nominal references — no `TypeGraph` change is
  needed or allowed.
- `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` — the plan-then-write scaffolder.
  `planScaffold :: Context -> Spec -> Either [Refusal] [ScaffoldModule]` (line 107) and
  `planScaffoldWithGoldens` (line 110) are **pure**. `collisionRefusals` (lines 168–178)
  groups planned modules by `T.toCaseFold` of their path and refuses when a group has
  more than one member — the case-folded collision semantics this plan reuses at compose
  time for the cross-member check. EP-2 owns all scaffold behavior changes; this plan
  only *reads* the pure planner.
- `keiro-dsl/src/Keiro/Dsl/Coverage.hs` — `coverageReport :: FilePath -> Spec -> …`;
  `CoverageFinding` (line 124) carries root names and no line numbers (verified — this
  is what makes merged-graph coverage attribution honest without touching this module).
- `keiro-dsl/src/Keiro/Dsl/ExplainBindings.hs` — `bindingObligations :: Spec -> …`,
  rendered by context name and symbols, no file/line.

Note there is already a `Keiro.Dsl.Manifest` module — it is the **scaffold build
manifest** (the record of emitted modules), unrelated to this plan's workspace manifest.
Do not touch it; avoid the bare word "manifest" in code identifiers without the
`Workspace` prefix.

Tests live in `keiro-dsl/test/`. `Main.hs` (test-suite `keiro-dsl-test`, hspec +
QuickCheck, ~2900 lines) contains per-feature `describe` blocks, the
`parse . pretty` round-trip property, and helpers such as
`specOf :: FilePath -> IO Spec` (fixture paths are given relative to the `keiro-dsl/`
package directory, e.g. `"test/fixtures/consumer-types.keiro"`). Fixture `.keiro` files
live flat under `keiro-dsl/test/fixtures/` (~180 files); this plan introduces the first
directory-shaped fixtures (a workspace is inherently a directory), which is fine — the
suite addresses fixtures by explicit path.

Build and test commands, quoted exactly as this repository runs them (working directory:
the repository root, the directory containing `cabal.project`; enter the dev shell with
`nix develop` or direnv if the tools are not on PATH):

```bash
cabal build keiro-dsl        # library + CLI
cabal test keiro-dsl-test    # the unit/property suite this plan extends
just adr-validate            # strict OKF enforcement for docs/adr
just verify                  # full repository gate (haskell build/tests, adr-validate, research-validate)
```

Note `just verify`'s `haskell-test` recipe does not run `keiro-dsl-test`; always run
`cabal test keiro-dsl-test` explicitly.

### The normative sources this plan implements

Read both in full before implementing; this plan restates their binding content but they
remain the authority on intent:

- **IR-2** —
  `docs/improvement-requests/support-composable-multi-file-service-specifications-in-keiro-dsl.md`.
  This plan implements its "The Request" identity bullets, the whole "Composition and
  name resolution" section, and the `check` line of "Whole-service commands". The
  scaffold and diff sections belong to plans 154 and 155. IR-2's illustrative
  `service … specs { … }` block "is semantic, not a commitment to grammar"; the concrete
  grammar is fixed in this plan's Milestone 1 and recorded in the new ADR.
- **MasterPlan 26** —
  `docs/masterplans/26-composable-multi-file-service-workspaces-for-keiro-dsl.md`. Its
  Decision Log is binding on this plan: the workspace input is a manifest **file** (not
  flags or globs); member files remain complete `.keiro` specs and the composer rejects
  duplicate declarations even when textually identical (single-owner, no silent merge);
  whole-workspace atomicity means detection-before-write, never filesystem transactions.
  Its Integration Points fix what this plan must deliver to EP-2/EP-3: the manifest
  format and identity, the `WorkspaceSpec` graph and loader API with source-abstract
  loading, the CLI dispatch, and the multi-file diagnostic shape. One clarification this
  plan records (Decision Log above): "member files remain complete, independently valid
  specs" means every member is a complete, independently **parseable** spec in the
  unchanged grammar with whole-aggregate ownership — a member that references a shared
  declaration owned by another member is, by design, only fully checkable through the
  workspace; a self-contained member remains checkable alone exactly as today.

### The fleet motivation (read-only; do not modify these repositories)

- Kotei (`/Users/shinzui/Keikaku/bokuno/kotei/kdsl/*.keiro`) keeps one aggregate per
  file, every file declaring `context kotei` — the exact shape the composer must accept.
  Note a real single-owner consequence: `id RunId prefix=run` is declared independently
  in `forge.keiro`, `rule-execution.keiro`, and `run.keiro`. Under this plan's
  no-silent-merge rule those textually identical duplicates are refused, so Kotei's
  eventual adoption (EP-4's job, not this plan's) will move shared IDs to one owning
  member. This is by design — IR-2: "Identical repeated declarations should not silently
  merge."
- Danwa (`/Users/shinzui/Keikaku/bokuno/danwa/domain/danwa.keiro`) puts three aggregates
  in one file (`context danwa`, `layout collocated`) — the shape that must keep working
  unchanged, and later a valid one-member workspace.

### Relevant ADRs

Scanned `docs/adr/` filenames and headings; the three records that constrain this design
(each cited by repository-relative path, with why it matters here):

- [ADR-4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
  (`docs/adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md`) — every
  hazard is checked at the earliest boundary with enough evidence, and diagnostic codes
  form one shared machine-checkable registry; this is why cross-file conflicts are
  refused at compose time (only the composer sees both owning files) rather than
  surfacing later as scaffold collisions, and why workspace refusals append to
  `DiagnosticCode` instead of inventing a parallel enum.
- [ADR-12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
  (`docs/adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md`)
  — one schema authority per structural mapping; this forces a shared declaration such as
  `ProjectId` to have exactly one owning member file producing one nominal generated
  type, which is the single-owner refusal's deeper justification.
- [ADR-13](../adr/0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md)
  (`docs/adr/0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md`)
  — coverage is reporting-first and opacity gates are opt-in; the whole-service coverage
  report therefore aggregates the merged graph's findings without inventing new gates.

No existing ADR covers workspaces, multi-file input, or manifest identity; this plan
creates that record in Milestone 1. `docs/adr/` is a profile-governed OKF bundle
(`docs/adr/profile.dhall`); handles are allocated with `okf id next`, never derived by
counting files (the workflow is `agents/skills/exec-plan/ADR.md`). Cross-repository
context: IR-2 originates from the Mori project (`origin: mori://shinzui/mori`, Mori
MasterPlan 22); per MasterPlan 26, no cross-repository ADR governs this design.

### Terms used in this plan

- **Workspace manifest**: the `.keiro-workspace` file naming the service and listing the
  member `.keiro` files. Its grammar is fixed in Milestone 1.
- **Member**: one `.keiro` file listed by a manifest. Members are complete specs in the
  unchanged grammar; each declares its own `context`.
- **Workspace identity**: the `service <name>` value — the stable identity that outlives
  member renames. EP-2 keys scaffold records by it; EP-3 stamps it into reports. In this
  plan it appears in `WorkspaceSpec` and in diagnostics.
- **Composed / merged spec**: the single `Spec` value built from all members in canonical
  order, with relocated line numbers, on which all existing validation runs.
- **Line map**: the table mapping merged-spec line ranges back to `(member path, original
  line)`; the mechanism behind multi-file diagnostics.
- **Ownership index**: the map from each declaration name and node identity to its owning
  member file and original span. EP-2 consumes it for per-module source ownership; EP-3
  for ownership-move reporting.
- **Content source**: the loading abstraction (`FilePath -> IO Text`, in effect) that
  lets the same loader read members from the filesystem now and from `git show` blobs in
  EP-3.
- **Refusal**: a compose-time error diagnostic that prevents a `WorkspaceSpec` from being
  produced at all, citing every relevant file and span.


## Plan of Work

Three milestones, matching MasterPlan 26's three EP-1 Progress entries exactly. Sequence:
the manifest form and its durable ADR first (nothing else is expressible without it),
then the loader and composed graph (the artifact everything downstream consumes), then
the CLI `check` with fixtures. Each milestone ends with `cabal test keiro-dsl-test` green
and a demonstrable CLI or API behavior, and each is committed with the trailers listed in
Concrete Steps.

Constraints that bind all three milestones: the member-file grammar does not change (no
new keywords, no new clauses — `keiro-dsl/src/Keiro/Dsl/Parser.hs` and
`Grammar.hs` gain nothing member-visible); generated bytes for existing single-file
scaffolds are untouched (this plan changes no scaffold code, and the `WorkspaceSpec`
must carry per-declaration and per-node ownership so EP-2 can preserve that guarantee);
no new package dependencies.

### Milestone 1 — Workspace manifest grammar, parser, and the identity ADR

Scope: the manifest file format exists, parses, and round-trips through `keiro-dsl
parse`; the durable design decision is recorded as a new ADR. At the end, a user can
write a manifest, run `parse` on it, and get the canonical form back; `check`/`scaffold`/
`diff` on a manifest fail with honest staged messages instead of grammar noise.

**The concrete manifest syntax this plan commits to.** A `.keiro-workspace` file is
line-oriented in the spirit of the existing DSL: `#` starts a comment to end of line,
blank lines are ignored, and clause keywords drive structure. The canonical example this
plan's positive fixture mirrors (shaped after IR-2's Mori service):

```text
# The demo-project service workspace.
service demo-project
module Demo.Modules.Project
layout collocated
spec domain/project-artifact.keiro
spec domain/project.keiro
spec domain/shared.keiro
```

Grammar rules, fixed here:

- `service <name>` — mandatory, exactly once, and the first clause. `<name>` uses the
  existing `wireWord` spelling (ASCII letter/digit start, then letters, digits, `_`,
  `-`), e.g. `mori-project`. This is the stable workspace identity.
- `module <Prefix>` — optional, at most once, after `service`. `<Prefix>` follows the
  member grammar's module-prefix rule: dot-separated PascalCase segments
  (`Demo.Modules.Project`).
- `layout prefixed` or `layout collocated` — optional, at most once, after `service`.
- `spec <path>` — one or more member lines. `<path>` is a relative path token
  (characters `A–Z a–z 0–9 . _ - /`, no spaces), must end in `.keiro`, must not be
  absolute, must not contain `..` segments, and `./` prefixes are normalized away.
  Paths are resolved relative to the manifest's own directory.
- Duplicate clauses (`service` twice, `module` twice), a duplicate member path, or two
  member paths equal under `T.toCaseFold` after normalization are **parse/compose
  errors** at the manifest boundary, reported with the manifest path and line.
- Canonical form: clauses in the order `service`, `module`, `layout`, then `spec` lines
  sorted by codepoint order of the normalized path. `parseWorkspaceManifest` accepts
  `spec` lines in any order (membership is a set); `renderWorkspaceManifest` always
  emits the canonical order, so `parse . render` is identity on the AST and `render .
  parse . render` is identity on bytes. Comments are not preserved (same as the member
  pretty-printer).

Edits:

1. New module `keiro-dsl/src/Keiro/Dsl/Workspace.hs`, added to `exposed-modules` in
   `keiro-dsl/keiro-dsl.cabal` (alphabetical position, after `Keiro.Dsl.Validate` per
   the existing sorted list — check the list's actual ordering convention when editing).
   In this milestone it contains: the manifest AST (`WorkspaceManifest` with per-clause
   `Loc`s — this file format is owned here, so unlike `Spec` it records clause spans),
   `parseWorkspaceManifest :: FilePath -> Text -> Either ParseError WorkspaceManifest`
   (its own small megaparsec parser; the member parser's lexer is not exported and the
   ~20 lines of lexeme machinery are simpler duplicated than entangled),
   `renderWorkspaceManifest :: WorkspaceManifest -> Text`, and
   `isWorkspacePath :: FilePath -> Bool` (case-insensitive extension test for
   `.keiro-workspace`).
2. `keiro-dsl/app/Main.hs` — in each of the four file-taking command handlers, branch on
   `isWorkspacePath fp` first. `parse`: read the manifest, parse, print
   `renderWorkspaceManifest` (errors to stderr, exit 1). `check`, `scaffold`, `diff`:
   print the staged refusal to stderr and exit 1 —
   `scaffold`: `workspace scaffolding is not yet supported; it lands with docs/plans/154-scaffold-whole-workspaces-atomically-with-workspace-keyed-records-and-adoption-from-per-context-records.md`;
   `diff`: `workspace diff is not yet supported; it lands with docs/plans/155-diff-whole-workspaces-with-shared-declaration-impact-classification-and-unified-compatibility-reports.md`;
   `check`: `whole-service check lands in a later milestone of
   docs/plans/153-add-the-service-workspace-manifest-loader-composed-graph-and-whole-service-check-to-keiro-dsl.md`
   (replaced in M3; the message names the plan document rather than saying "this plan"
   so it is meaningful to a user who is not reading the plan). Update `fileArg`'s help
   text to `"Path to a .keiro spec or .keiro-workspace manifest (use /dev/stdin for
   stdin)"`. The four dispatch clauses are added as new leading equations of `run`, so
   every existing single-file branch stays textually unchanged.
3. `keiro-dsl/test/Main.hs` — a new `describe "service workspace (EP-153)"` block:
   round-trip unit tests for the canonical example; a QuickCheck property over a small
   `WorkspaceManifest` generator (`parse . render == Right`, and `render . parse .
   render == render` on bytes); rejection tests for a missing `service` line, duplicate
   `service`/`module`/`layout` clauses, a duplicate member path, a case-folded duplicate
   member path, an absolute member path, a `..` path, and a non-`.keiro` member.
4. The ADR. Allocate the handle — never guess it:

   ```bash
   okf id list docs/adr --profile docs/adr/profile.dhall
   okf id next docs/adr --profile docs/adr/profile.dhall ADR
   ```

   The expected result is `ADR-14`, but the command's output is authoritative. Create
   `docs/adr/00NN-<slug>.md` (following the existing `00NN-` filename convention) with
   the profile's frontmatter (`type: Architecture Decision Record`, `title`,
   one-sentence `description`, `timestamp`, `docId` from `okf id next`, `status:
   Accepted`, `date`). The record's content is the durable half of this plan's Decision
   Log: the workspace identity is the manifest's `service` name in a versioned
   `.keiro-workspace` file; membership is an explicit, canonically sorted member list;
   shared declarations have exactly one owning member and identical duplicates are
   refused (no silent merge, citing ADR-12's one-authority stance); the manifest is the
   module/layout authority with the absent-or-exactly-equal member rule; context is
   member-declared and must be unanimous; CLI dispatch is by file extension; a single
   `.keiro` file is a one-member workspace. Then advance the reserved log and validate:

   ```bash
   okf log add docs/adr --kind Added -m "Record the service workspace identity, single-owner member composition, and manifest authority rules (plan 153)"
   just adr-validate
   ```

   (Verified 2026-07-29: `okf log add` takes `BUNDLE [CONCEPT_ID] [--kind KIND]
   (-m|--message MESSAGE) [--date YYYY-MM-DD]` and does **not** accept `--profile`. The
   non-negotiable outcome is that `just adr-validate` — which runs
   `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce
   --log-enforce` — passes; it fails with `timestamp date … is newer than log.md newest
   entry` until the log is advanced.)

Acceptance: `cabal test keiro-dsl-test` green including the new block;
`cabal run keiro-dsl -- parse <manifest>` prints the canonical manifest and re-parsing
that output is byte-stable (transcript in Concrete Steps); `just adr-validate` green
with the new record present.

### Milestone 2 — Loader and the composed `WorkspaceSpec` graph

Scope: `Keiro.Dsl.Workspace` grows the loader, the pure composer, and the
`WorkspaceSpec` type — the artifact EP-2 and EP-3 compile against. Everything in this
milestone is exercised at the API level from the test suite; the CLI wiring is
Milestone 3. At the end, a two-aggregate workspace with shared declarations composes
into one graph whose cross-file references resolve, and every refusal class fires with
multi-location evidence.

**The content-source abstraction** (the EP-3 integration point — plan
`docs/plans/155-diff-whole-workspaces-with-shared-declaration-impact-classification-and-unified-compatibility-reports.md`
depends on this exact seam, so treat its shape as a published interface):

```haskell
-- | How the loader obtains file contents. 'csRead' receives a path relative to
-- the workspace root (the manifest's directory); Left is a human-readable
-- read-failure reason. EP-1 ships 'fileContentSource'; EP-3 adds a git-blob
-- source ('git show <rev>:<path>') without touching the loader.
data ContentSource = ContentSource
    { csRead :: FilePath -> IO (Either Text Text)
    }

fileContentSource :: FilePath -> ContentSource  -- rooted at a directory
```

**The loader and composer.** `loadWorkspace source manifestPath` reads and parses the
manifest through the source, reads and parses every member (collecting **all** failures,
not failing fast — a workspace with two unreadable members reports both), and hands the
parsed members to the pure composer. The composer is pure so tests and EP-3 can drive it
without IO:

```haskell
loadWorkspace :: ContentSource -> FilePath -> IO (Either WorkspaceFailure WorkspaceSpec)

composeWorkspace ::
    FilePath ->                    -- manifest path, for diagnostics
    WorkspaceManifest ->
    [(FilePath, Text, Spec)] ->    -- normalized member path, source text, parsed spec
    Either (NonEmpty WorkspaceDiagnostic) WorkspaceSpec
```

(`WorkspaceFailure` wraps the three failure stages — manifest unreadable, manifest
unparseable, member/compose diagnostics — with one render function; exact constructors
in Interfaces and Dependencies.) The member source text is passed in because the
composer needs it for two things: counting lines for the line map, and the textual scan
that locates `context`/`module`/`layout` clause lines for refusal spans (the `Spec` AST
does not record them; see Decision Log).

**Composition, in order.** Members are sorted canonically (already guaranteed by the
manifest AST). Then:

1. *Effective context.* Every member's `specContext` must be identical; otherwise emit
   one `WorkspaceContextMismatch` refusal citing every member's context-clause line
   (majority/first-wins is exactly the silent behavior IR-2 forbids).
2. *Effective module root and layout.* Apply the authority rule from the Decision Log.
   Disagreement emits `WorkspaceAuthorityConflict` citing the manifest clause line (when
   present) and every conflicting member clause line.
3. *Single-owner declarations.* Build the ownership index over all four shared
   declaration namespaces (`specIds`, `specEnums`, `specRules`, `specMapped`). Any name
   declared by two **different members** — same kind or different kind, and **even when
   the declarations are textually identical** — emits `WorkspaceDuplicateDeclaration`
   citing every declaring member and line. (Cross-kind duplicates are what IR-2 calls
   "ambiguous references": after the single-owner rule holds, every reference has
   exactly one candidate, and any residual single-spec ambiguity is caught by the merged
   `validateSpec` exactly as today.) Same-member duplicates are *not* refused here —
   they flow through the merged validation and keep their existing single-file
   diagnostics.
4. *Single-owner nodes.* Using `nodeIdentity` (export it from
   `keiro-dsl/src/Keiro/Dsl/Validate.hs`), any `(kind, name)` node identity owned by two
   different members — an aggregate defined, or partially defined, in two files is
   exactly this case, since the grammar has no partial-aggregate form — emits
   `WorkspaceDuplicateNodeName` citing both definition sites.
5. *Merged spec and line map.* Assign each member its base offset (cumulative line
   counts), relocate every `Loc` in each member's AST by its base, and concatenate
   declarations and nodes in canonical member order into one `Spec` whose
   `specContext`/`specModuleRoot`/`specLayout` are the effective values. Relocation is a
   generic traversal (`GHC.Generics`; every AST type already derives `Generic`; no new
   dependency) that rewrites every `Loc` field — write it once as
   `relocateLocs :: (Int -> Int) -> Spec -> Spec` with a companion generic
   `collectLocs :: Spec -> [Int]` used by the test that proves no `Loc` is missed
   (parse a fixture, relocate by +1000, assert the collected line multiset shifted
   exactly).
6. *Cross-member generated-path collisions.* Run the pure planner
   (`planScaffoldWithGoldens [] ctx mergedSpec` with the effective `Context`) and group
   the planned module paths with the same `T.toCaseFold` grouping as
   `collisionRefusals`. For every colliding group whose owning nodes (via the ownership
   index) span more than one member, emit `WorkspacePathCollision` citing each owning
   node's member and line. If the planner itself refuses for unrelated reasons, skip
   this step silently — those refusals remain scaffold-owned (EP-2), and `check` must
   not grow new single-member gates (Decision Log).

**The result type.** `WorkspaceSpec` carries everything EP-2 and EP-3 need, read-only:

```haskell
data WorkspaceSpec = WorkspaceSpec
    { wsService :: !Text                     -- the stable workspace identity
    , wsManifestPath :: !FilePath
    , wsContext :: !Name                     -- effective context
    , wsModuleRoot :: !(Maybe Text)          -- effective module root
    , wsLayout :: !(Maybe Placement)         -- effective layout
    , wsMembers :: ![WorkspaceMember]        -- canonical order
    , wsMergedSpec :: !Spec                  -- relocated; specContext/ModuleRoot/Layout = effective
    , wsLineMap :: !LineMap
    , wsOwnership :: !OwnershipIndex         -- decl name / node identity -> (member, original Loc)
    }

data WorkspaceMember = WorkspaceMember
    { wmPath :: !FilePath                    -- normalized, manifest-relative
    , wmSpec :: !Spec                        -- as parsed, unrelocated
    , wmLineBase :: !Int
    , wmLineCount :: !Int
    }
```

plus `resolveWorkspaceLine :: WorkspaceSpec -> Int -> Maybe (FilePath, Int)` (Nothing
means "outside every member" — render against the manifest),
`oneMemberWorkspace :: FilePath -> Spec -> WorkspaceSpec` (base offset 0, identity line
map, service name = the file's base name, effective clauses = the spec's own), and
`checkWorkspace :: WorkspaceSpec -> [WorkspaceDiagnostic]` which runs `validateSpec
wsMergedSpec` and maps every diagnostic through the line map into a single-location
`WorkspaceDiagnostic` with the owning member's path and original line.

Tests (API level, in the new describe block): the positive fixture workspace (built in
this milestone under `keiro-dsl/test/fixtures/workspace/`, contents specified in
Milestone 3) composes; an aggregate in `domain/project.keiro` referencing an id, an
enum, and a mapped declaration owned by `domain/shared.keiro` produces **zero**
unresolved-name diagnostics, and a read model in `domain/project-artifact.keiro`
feeding from the `Project` aggregate resolves; each refusal class fires on a
purpose-built in-memory member set with the exact expected code and the exact expected
multi-location list; the one-member equivalence property holds
(`checkWorkspace (oneMemberWorkspace fp s)` equals `validateSpec s` mapped to `fp`, run
over several existing fixtures including at least one with error diagnostics);
permutation determinism holds (composing the same members from manifests listing them
in different orders yields equal `WorkspaceSpec`s — field-by-field, and
`renderWorkspaceManifest` bytes are identical); the relocation-completeness generic
test passes.

Acceptance: `cabal test keiro-dsl-test` green; no CLI behavior change beyond M1's.

### Milestone 3 — Whole-service `check` through the CLI

Scope: replace M1's staged `check` refusal with the real thing; multi-file rendering;
fixtures for every refusal class; prove existing behavior is untouched. At the end, the
Purpose section's headline command works.

**The `check` flow for a workspace input** (in `keiro-dsl/app/Main.hs`, a new
`runWorkspaceCheck` beside the existing single-file branch, which is not modified):

1. `loadWorkspace (fileContentSource (takeDirectory fp)) fp`. On `Left`, render every
   failure/refusal (manifest parse errors carry the manifest path; member parse errors
   already carry the member path because `parseSpec`'s `FilePath` argument is the
   megaparsec source name — pass the path the user can click, i.e. the manifest's
   directory joined with the member path) and exit 1.
2. `checkWorkspace ws` — render every diagnostic; if any has `Error` severity, exit 1.
3. On success: `--emit` prints `renderSpec (wsMergedSpec ws)`; `--explain-bindings`
   prints `renderBindingObligations (wsContext ws)` of `bindingObligations
   (wsMergedSpec ws)`; coverage options run `Coverage.coverageReport fp (wsMergedSpec
   ws)` with the manifest path as the report subject (and `--fail-on-opaque` behaves
   exactly as the single-file path). Otherwise print `OK`, mirroring the single-file
   contract.

**Rendering.** `renderWorkspaceDiagnostic :: FilePath -> WorkspaceDiagnostic -> Text`
(the `FilePath` is the manifest path as the user typed it; member locations render as
`dirname(manifest)/member:line` so they are terminal-clickable). Format, fixed here —
primary location first in the established shape, additional locations as indented
notes:

```text
keiro-dsl/test/fixtures/workspace-dup-decl/domain/project.keiro:3: error[WorkspaceDuplicateDeclaration]: duplicate declaration 'ProjectId': a shared declaration has exactly one owning member (identical duplicates do not merge)
  keiro-dsl/test/fixtures/workspace-dup-decl/domain/shared.keiro:3: note: also declared here, as id 'ProjectId'
```

(The primary location is the member that comes first in canonical member order —
`project` sorts before `shared` — not the "original" declaration, because under the
single-owner rule neither duplicate is privileged.)

**Fixtures.** All under `keiro-dsl/test/fixtures/`, one directory per workspace. The
positive fixture `workspace/` (built in M2, exercised end-to-end here):

- `workspace/service.keiro-workspace` — the canonical example from Milestone 1
  (`service demo-project`, `module Demo.Modules.Project`, `layout collocated`, three
  `spec domain/….keiro` lines).
- `workspace/domain/shared.keiro` — `context demo-project`; owns `id ProjectId`, an
  enum, a rule, and one `mapped structural record` (copy the ingredient style from
  `test/fixtures/consumer-types.keiro` so the mapped declaration is complete).
- `workspace/domain/project.keiro` — `context demo-project`; the `Project` aggregate
  whose commands/events/registers use the shared id, enum, and mapped type nominally.
- `workspace/domain/project-artifact.keiro` — `context demo-project`; the
  `ProjectArtifact` aggregate, plus a read model feeding from `Project` (the cross-file
  node reference).

Negative fixtures, one refusal class each, asserted by exact code and by the exact set
of files cited in the rendered output: `workspace-context-mismatch/` (two members,
different contexts), `workspace-authority-conflict/` (manifest `layout collocated`,
member `layout prefixed`), `workspace-dup-decl/` (textually identical `id ProjectId` in
two members — the no-silent-merge proof), `workspace-dup-node/` (aggregate `Project`
defined in two members, with distinct id declarations so the node rule fires alone),
`workspace-missing-member/` (listed member absent — `WorkspaceMemberUnreadable`),
`workspace-member-parse-failed/` (a member that is not a valid spec —
`WorkspaceMemberParseFailed`, with the member's own parse error nested in the message),
`workspace-path-collision/` (aggregates `Run` and `RUn` in different members —
case-folds to one generated path), and `workspace-unresolved/` (an aggregate using an
atom no member declares — this one is *not* a compose refusal: it proves the merged
`validateSpec` catches cross-file unresolved references and that the line map
attributes the diagnostic to the right member file and line).

Two further fixtures cover the manifest boundary, which is reached *before* any graph
exists and therefore carries no `DiagnosticCode` (see the M2 Decision Log entry): they
are asserted by their exact refusal message and position instead —
`workspace-dup-member/` (the same `spec` path listed twice) and
`workspace-invalid-member-path/` (a `../escape.keiro` member).

Also add a reordered copy of the positive manifest
(`workspace/service-reordered.keiro-workspace` listing the same members in reverse) and
assert `check` output and `parse` bytes are identical to the canonical manifest's.

**Regression proof.** Run the full suite and the CLI against a handful of existing
single-file fixtures; `git status` must show no modification to any existing fixture,
golden, or generated byte. The single-file `check`/`parse`/`scaffold`/`diff` branches
in `Main.hs` must be textually unchanged except for the dispatch guard and `fileArg`
help text.

**Bookkeeping.** Update `CHANGELOG.md` under `## [Unreleased]` (keiro-dsl entry: the
workspace manifest, composed check, and the new diagnostic codes). In MasterPlan 26,
set the EP-1 registry row to Complete and tick the three EP-1 Progress entries. Perform
the ADR distillation pass (the M1 ADR should already hold the durable content; amend it
only if implementation discovered durable facts, via the strict okf workflow).

Acceptance: the Concrete Steps transcripts reproduce; `cabal test keiro-dsl-test`
green; `just adr-validate` green; `just verify` green.


## Concrete Steps

All commands run from the repository root (the directory containing `cabal.project`),
inside the dev shell (`nix develop` if needed). Commit after each milestone on the
current branch with a conventional-commit message (`feat(dsl): …`, `test(dsl): …`,
`docs(adr): …`) carrying these trailers verbatim:

```text
MasterPlan: docs/masterplans/26-composable-multi-file-service-workspaces-for-keiro-dsl.md
ExecPlan: docs/plans/153-add-the-service-workspace-manifest-loader-composed-graph-and-whole-service-check-to-keiro-dsl.md
Intention: intention_01kyq39tsbepwt43q6db89h0d7
```

```bash
# Baseline: confirm the world is green before touching anything.
cabal build keiro-dsl && cabal test keiro-dsl-test

# Milestone 1 loop:
cabal test keiro-dsl-test
cabal run keiro-dsl -- parse keiro-dsl/test/fixtures/workspace/service.keiro-workspace
# ADR allocation (output is authoritative; expected ADR-14):
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
just adr-validate
```

Milestone 1 transcript, captured verbatim on 2026-07-29 (canonical round trip; a second
`parse` of the printed output produces identical bytes). Note the manifest source has a
leading `#` comment and the canonical output drops it, exactly like the member
pretty-printer:

```text
$ cabal run -v0 keiro-dsl -- parse keiro-dsl/test/fixtures/workspace/service.keiro-workspace
service demo-project
module Demo.Modules.Project
layout collocated
spec domain/project-artifact.keiro
spec domain/project.keiro
spec domain/shared.keiro
exit=0

$ cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/workspace/service.keiro-workspace --out /tmp/x
workspace scaffolding is not yet supported; it lands with docs/plans/154-scaffold-whole-workspaces-atomically-with-workspace-keyed-records-and-adoption-from-per-context-records.md
exit=1

$ cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workspace/service.keiro-workspace
whole-service check lands in a later milestone of docs/plans/153-add-the-service-workspace-manifest-loader-composed-graph-and-whole-service-check-to-keiro-dsl.md
exit=1

$ cabal run -v0 keiro-dsl -- diff keiro-dsl/test/fixtures/workspace/service.keiro-workspace --since HEAD
workspace diff is not yet supported; it lands with docs/plans/155-diff-whole-workspaces-with-shared-declaration-impact-classification-and-unified-compatibility-reports.md
exit=1
```

```bash
# Milestone 3: whole-service check.
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/workspace/service.keiro-workspace
# -> OK (exit 0)
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/workspace-dup-decl/service.keiro-workspace; echo "exit=$?"
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/workspace-unresolved/service.keiro-workspace; echo "exit=$?"
# Determinism: reordered membership is semantically and byte identical.
cabal run keiro-dsl -- parse keiro-dsl/test/fixtures/workspace/service-reordered.keiro-workspace \
  | diff - <(cabal run -v0 keiro-dsl -- parse keiro-dsl/test/fixtures/workspace/service.keiro-workspace) \
  && echo "canonical bytes identical"
```

Milestone 3 transcripts, captured verbatim on 2026-07-29 (abridged only where a
refusal repeats per generated module). Note the primary location is the member that
appears first in canonical member order, and the note lines carry the rest:

```text
$ cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workspace/service.keiro-workspace
OK
exit=0

$ cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workspace-dup-decl/service.keiro-workspace
keiro-dsl/test/fixtures/workspace-dup-decl/domain/project.keiro:3: error[WorkspaceDuplicateDeclaration]: duplicate declaration 'ProjectId': a shared declaration has exactly one owning member (identical duplicates do not merge)
  keiro-dsl/test/fixtures/workspace-dup-decl/domain/shared.keiro:3: note: also declared here, as id 'ProjectId'
exit=1

$ cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workspace-unresolved/service.keiro-workspace
keiro-dsl/test/fixtures/workspace-unresolved/domain/project.keiro:12: error[GuardAtomOutOfScope]: atom 'MissingPhase' in transition 'Pending -- DoProject' resolves to no register, command field, enum constructor, or rule
exit=1

$ cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workspace-context-mismatch/service.keiro-workspace
keiro-dsl/test/fixtures/workspace-context-mismatch/domain/a.keiro:1: error[WorkspaceContextMismatch]: workspace 'demo-project' members declare different contexts (alpha, beta); every member of one workspace must declare the same context
  keiro-dsl/test/fixtures/workspace-context-mismatch/domain/b.keiro:1: note: member declares context 'beta'
exit=1

$ cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workspace-authority-conflict/service.keiro-workspace
keiro-dsl/test/fixtures/workspace-authority-conflict/service.keiro-workspace:2: error[WorkspaceAuthorityConflict]: workspace manifest declares layout collocated, so every member's layout clause must be absent or exactly equal
  keiro-dsl/test/fixtures/workspace-authority-conflict/domain/b.keiro:2: note: member declares layout prefixed
exit=1

$ cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workspace-dup-node/service.keiro-workspace
keiro-dsl/test/fixtures/workspace-dup-node/domain/a.keiro:5: error[WorkspaceDuplicateNodeName]: duplicate aggregate node name 'Project': a node has exactly one owning member
  keiro-dsl/test/fixtures/workspace-dup-node/domain/b.keiro:5: note: also defined here
exit=1

$ cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workspace-path-collision/service.keiro-workspace
keiro-dsl/test/fixtures/workspace-path-collision/domain/a.keiro:5: error[WorkspacePathCollision]: generated module path 'DemoProject/Run/Holes.hs' is claimed by nodes in more than one member; on a case-insensitive filesystem these are one file
  keiro-dsl/test/fixtures/workspace-path-collision/domain/b.keiro:5: note: claimed here by aggregate RUn (line 24)
… five more, one per colliding generated module (Codec, Domain, EventStream, Harness, Projection) …
exit=1

$ cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workspace-missing-member/service.keiro-workspace
keiro-dsl/test/fixtures/workspace-missing-member/service.keiro-workspace:3: error[WorkspaceMemberUnreadable]: workspace member 'domain/b.keiro' could not be read: no such file: keiro-dsl/test/fixtures/workspace-missing-member/domain/b.keiro
exit=1

$ cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workspace-member-parse-failed/service.keiro-workspace
keiro-dsl/test/fixtures/workspace-member-parse-failed/service.keiro-workspace:3: error[WorkspaceMemberParseFailed]: workspace member 'domain/b.keiro' failed to parse:
keiro-dsl/test/fixtures/workspace-member-parse-failed/domain/b.keiro:6:11:
  |
6 |   command !!! not a spec !!!
  |           ^
unexpected '!'
expecting '_'
exit=1
```

The two manifest-boundary refusals are megaparsec errors positioned at the offending
`spec` line, with no `DiagnosticCode` — a malformed manifest never reaches the composer,
exactly as a malformed `.keiro` file never reaches `validateSpec`:

```text
$ cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workspace-dup-member/service.keiro-workspace
keiro-dsl/test/fixtures/workspace-dup-member/service.keiro-workspace:3:1:
  |
3 | spec ./domain/a.keiro
  | ^
duplicate workspace member 'domain/a.keiro': membership is a set
exit=1

$ cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workspace-invalid-member-path/service.keiro-workspace
keiro-dsl/test/fixtures/workspace-invalid-member-path/service.keiro-workspace:2:1:
  |
2 | spec ../escape.keiro
  | ^
member path must not contain '..' segments: '../escape.keiro'
exit=1
```

Determinism, verified the same day — reordering members changes neither the canonical
manifest bytes nor the merged whole-service view:

```text
$ diff <(cabal run -v0 keiro-dsl -- parse keiro-dsl/test/fixtures/workspace/service-reordered.keiro-workspace) \
       <(cabal run -v0 keiro-dsl -- parse keiro-dsl/test/fixtures/workspace/service.keiro-workspace) \
  && echo "canonical bytes identical"
canonical bytes identical

$ diff <(cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workspace/service-reordered.keiro-workspace --emit) \
       <(cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workspace/service.keiro-workspace --emit) \
  && echo "merged spec identical"
merged spec identical
```

`--explain-bindings` is the clearest single piece of evidence that the graph resolved
once rather than three times: one obligation lists use sites from **both** aggregate
members against a mapped type declared in a **third**:

```text
$ cabal run -v0 keiro-dsl -- check keiro-dsl/test/fixtures/workspace/service.keiro-workspace --explain-bindings
binding obligations for context demo-project
  Demo.Project.KeiroBindings (package demo-project-domain)
    projectSummaryBinding :: StructuralBinding Demo.Project.Domain.ProjectSummary ProjectSummaryShape
      reason: binding — structural mapped type ProjectSummary (ProjectArtifact command RecordArtifact .artifactSummary : ProjectSummary; ProjectArtifact event ArtifactRecorded .artifactSummary : ProjectSummary; Project command RegisterProject .initialSummary : ProjectSummary; Project event ProjectRegistered .initialSummary : ProjectSummary; Project register summary : ProjectSummary)
      provenance: binding-version "1"
    …
```

```bash
# Final gates:
cabal test keiro-dsl-test
just adr-validate
just verify
```

Update this section with the exact fixture contents, real transcripts, and any renamed
messages as work proceeds; divergences are documentation bugs to fix here.


## Validation and Acceptance

Acceptance is behavioral, keyed to the IR-2 acceptance bullets this foundation plan owns
(scaffold/diff bullets belong to plans 154–156):

1. **Fixture shape** — `keiro-dsl/test/fixtures/workspace/` contains two aggregate files
   under one context plus a shared-declarations file owning one shared ID (`ProjectId`),
   an enum, a rule, and a mapped structural type. Command:
   `cabal run keiro-dsl -- check keiro-dsl/test/fixtures/workspace/service.keiro-workspace`
   prints `OK`, exit 0.
2. **Cross-file resolution** — either aggregate references the shared enum, id, and
   mapped type, and a read model feeds from an aggregate in another member; the check
   above proves it (any resolution failure would be an error diagnostic), and API tests
   assert zero unresolved-name diagnostics explicitly.
3. **Refusals with file/line diagnostics** — whole-service `check` catches duplicate
   aggregates, conflicting (even identical) shared declarations, cross-file unresolved
   references, and case-folded generated-path collisions across members; each negative
   fixture exits non-zero with its exact `DiagnosticCode` and its rendered output names
   **every** involved file and line (asserted in tests, shown in Concrete Steps).
4. **Determinism** — reordering manifest members changes nothing: `parse` bytes and
   `check` output are identical (fixture `service-reordered.keiro-workspace`; plus the
   API permutation test). This is the EP-1 half of IR-2's "reordering manifest members
   and repeating scaffold produce byte-identical output" (the scaffold half is EP-2's).
5. **Single-file compatibility** — the entire pre-existing `keiro-dsl-test` suite passes
   unmodified; no existing fixture or golden changes; the one-member equivalence
   property holds. `git diff --stat` over `keiro-dsl/test/fixtures/` shows only added
   files.
6. **Round trip** — the manifest QuickCheck property and CLI transcript prove
   `parse . render` identity and canonical byte stability.
7. **Durable decision** — the new ADR exists with an `okf`-allocated handle, `log.md` is
   advanced, and `just adr-validate` passes strict profile enforcement.

Suite commands and expected results: `cabal test keiro-dsl-test` exits 0 with the new
`service workspace (EP-153)` describe block listed; `just adr-validate` exits 0;
`just verify` exits 0.


## Idempotence and Recovery

Every step is additive source editing plus test runs; all commands are safe to re-run.
Nothing in this plan writes outside the working tree except `cabal`'s build artifacts.
`parse` and `check` never write files (coverage reports write only to the explicitly
given `--coverage-report` path, unchanged from today). If a milestone is interrupted,
the Progress section's done/remaining split plus the last green commit are sufficient to
resume.

The `DiagnosticCode` enum is append-only: if a workspace code lands misnamed before
release, add a new code and deprecate the old one in prose — never rename or reuse.

ADR handle allocation is the one step with external state: if interrupted after
`okf id next` but before the record is committed, re-running `okf id list` shows whether
the handle is now allocated in the working tree; keep the already-created record's
`docId` stable rather than allocating again. `just adr-validate` is the guard either
way.

The staged refusals (M1's `check`/`scaffold`/`diff` messages) are deliberately
transitional: M3 replaces `check`'s, and plans 154/155 replace the other two. If this
plan completes but a later plan is delayed, the refusals remain honest — they name the
owning plan documents.


## Interfaces and Dependencies

No new package dependencies. Used from the existing `build-depends` of `keiro-dsl`:
`megaparsec` (manifest parser), `text`, `containers` (line map, ownership index),
`filepath` (path normalization, extension dispatch), `directory` (file content source),
`base`'s `GHC.Generics` (the `Loc` relocation traversal). Tooling: `cabal`, `just`,
`okf`, `git`.

Module-level contract at the end of the plan (full paths; signatures are the minimum
that must exist — implementers may add, not subtract; EP-2 and EP-3 compile against
these names, so treat them as stable once this plan completes):

`Keiro.Dsl.Workspace` (new file `keiro-dsl/src/Keiro/Dsl/Workspace.hs`, exposed in
`keiro-dsl/keiro-dsl.cabal`):

```haskell
-- Milestone 1
data WorkspaceManifest   -- service name, optional module/layout, members with Locs
parseWorkspaceManifest :: FilePath -> Text -> Either ParseError WorkspaceManifest
renderWorkspaceManifest :: WorkspaceManifest -> Text
isWorkspacePath :: FilePath -> Bool

-- Milestone 2
data ContentSource = ContentSource { csRead :: FilePath -> IO (Either Text Text) }
fileContentSource :: FilePath -> ContentSource
data WorkspaceFailure
    -- constructors: manifest unreadable (reason), manifest parse error (ParseError),
    -- compose/member diagnostics (NonEmpty WorkspaceDiagnostic)
renderWorkspaceFailure :: FilePath -> WorkspaceFailure -> [Text]
loadWorkspace :: ContentSource -> FilePath -> IO (Either WorkspaceFailure WorkspaceSpec)
composeWorkspace :: FilePath -> WorkspaceManifest -> [(FilePath, Text, Spec)]
                 -> Either (NonEmpty WorkspaceDiagnostic) WorkspaceSpec
data WorkspaceSpec      -- fields as specified in Milestone 2
data WorkspaceMember    -- path, unrelocated Spec, line base, line count
data OwnershipIndex     -- decl name / (node kind, name) -> (member path, original Loc)
data LineMap
resolveWorkspaceLine :: WorkspaceSpec -> Int -> Maybe (FilePath, Int)
oneMemberWorkspace :: FilePath -> Spec -> WorkspaceSpec
checkWorkspace :: WorkspaceSpec -> [WorkspaceDiagnostic]
data WorkspaceDiagnostic  -- NonEmpty (FilePath, Int) locations, Severity,
                          -- DiagnosticCode, message

-- Milestone 3
renderWorkspaceDiagnostic :: FilePath -> WorkspaceDiagnostic -> Text
```

`Keiro.Dsl.Validate` (`keiro-dsl/src/Keiro/Dsl/Validate.hs`): `DiagnosticCode` extended
append-only with the seven **composition** refusal codes
`WorkspaceMemberUnreadable`, `WorkspaceMemberParseFailed`, `WorkspaceContextMismatch`,
`WorkspaceAuthorityConflict`, `WorkspaceDuplicateDeclaration`,
`WorkspaceDuplicateNodeName`, and `WorkspacePathCollision`; `nodeIdentity` exported.
(Manifest syntax and structure errors — duplicate members, invalid member paths — carry
no code, exactly as a `.keiro` parse error carries none; see the M2 Decision Log entry.)
`validateSpec`, `Diagnostic`, and `renderDiagnostic` are unchanged. `Keiro.Dsl.Workspace`
imports `Validate` (codes, severity, `validateSpec`), `Parser`, `Grammar`,
`PrettyPrint`, `Scaffold`/`ScaffoldRun` (pure planner for the collision check only);
nothing imports `Workspace` except `app/Main.hs` and the tests — until EP-2/EP-3.

`keiro-dsl/app/Main.hs`: extension dispatch in all four file-taking commands;
`runWorkspaceCheck`; single-file branches otherwise untouched; `mkContext` untouched.

Consumed-by contract (from MasterPlan 26 Integration Points): EP-2 (plan 154) takes
`WorkspaceSpec` — notably `wsService`, `wsMergedSpec`, `wsOwnership`, `wsContext`/
`wsModuleRoot`/`wsLayout` — as its planning input and must not re-parse members; EP-3
(plan 155) additionally consumes `ContentSource` (supplying a git-blob source) and
`composeWorkspace`'s purity to resolve a workspace at an old revision, plus
`WorkspaceDiagnostic` rendering for its use-site findings. Breaking any of these names
after this plan completes requires coordinating with those plans.
