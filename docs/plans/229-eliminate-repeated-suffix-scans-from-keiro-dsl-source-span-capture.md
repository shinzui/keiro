---
id: 229
slug: eliminate-repeated-suffix-scans-from-keiro-dsl-source-span-capture
title: "Eliminate repeated suffix scans from Keiro DSL source-span capture"
kind: exec-plan
created_at: 2026-08-10T13:41:00Z
intention: "intention_01kznxvd42efj9s5ty7tcfkjqm"
---

# Eliminate repeated suffix scans from Keiro DSL source-span capture

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, parsing a large `.keiro` specification no longer repeatedly walks the entire
unconsumed suffix whenever the frontend attaches a source span to a declaration, field, state, or
expression. Command-line checks, code generation, workspace loading, and source-aware editor or
library integrations keep the same exact half-open spans and the same semantic results, but their
parse-time cost grows with the syntax actually consumed rather than with every remaining suffix.

The result is observable in two ways. A new `keiro-dsl-parser-bench` Cabal benchmark generates
large nested specifications and multi-member workspaces and records comparable before/after
measurements. The focused span and frozen-compatibility tests continue to report byte-for-byte
identical positions, diagnostics, parse results, and workspace outcomes. This work changes parser
and tooling performance only; it changes no generated service runtime, language syntax, semantic
graph, persisted value, or generated Haskell output.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-10T13:57:18Z) Confirmed IR-15 and ADR profile validity, inspected the registered
  Megaparsec and tasty-bench source through Mori, and verified that the worktree contains only this
  untracked plan before implementation.
- [x] (2026-08-10T14:04:07Z) Milestone 1: added the reproducible single-source and in-memory
  workspace scaling benchmark, preflight-parsed every fully forced fixture, and recorded the
  unchanged-parser baseline in `/tmp/keiro-dsl-parser-before.csv`; all 12 rows passed.
- [ ] Milestone 2: derive the consumed slice from Megaparsec offsets, retain consumed-syntax trivia
  trimming, and pass the expanded exact-span and compatibility regressions.
- [ ] Milestone 3: re-run and document the benchmark, pass the complete DSL/workspace and repository
  gates, distill ADR impact, and close IR-15 only when all acceptance evidence is present.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: The first workspace fixture used 256 compact aggregates and was unsuitable for
  isolating parser scaling because workspace composition dominated its unchanged-parser runtime.
  Evidence: the largest compatibility-source parse took 63.3 ms, while the 1/2/4/8-member
  workspace rows all took about 2.3 s regardless of suffix-chain length. Before committing the
  baseline, the workspace generator was revised to keep 32 aggregates but make each one wide in
  registers, fields, guards, expressions, and writes. This keeps total syntax fixed across member
  counts while making located parsing material relative to composition.
  Date: 2026-08-10

- Observation: The committed unchanged-parser baseline ran on an Apple arm64 host under macOS
  26.5.2, GHC 9.12.4, Cabal 3.16.1.0, and Cabal's `-O1` build profile. The exact command was
  `cabal bench keiro-dsl:keiro-dsl-parser-bench --benchmark-options='-j1 --csv
  /tmp/keiro-dsl-parser-before.csv'`; fixture preflight and all 12 measured rows passed in 65.94 s.
  The CSV reports twice the standard deviation, so the values below divide that uncertainty column
  by two and express means and standard deviations in milliseconds.

  ```text
  scenario                                               mean ms    stdev ms
  surface-source/32 aggregates/15,594 chars               4.548512   0.113306
  surface-source/64 aggregates/31,146 chars               8.866254   0.235855
  surface-source/128 aggregates/62,250 chars             17.672156   0.860677
  surface-source/256 aggregates/124,458 chars            35.048412   0.911435
  compatibility-source/32 aggregates/15,594 chars         7.261828   0.339847
  compatibility-source/64 aggregates/31,146 chars        15.674206   0.413082
  compatibility-source/128 aggregates/62,250 chars       31.257550   0.878551
  compatibility-source/256 aggregates/124,458 chars      64.210600   2.211583
  workspace/1 member/32 aggregates/86,668 chars          368.315500   9.541302
  workspace/2 members/32 aggregates/86,745 chars         356.275400  11.487352
  workspace/4 members/32 aggregates/86,899 chars         349.277150  11.108674
  workspace/8 members/32 aggregates/87,207 chars         357.146300   9.449847
  ```

  Date: 2026-08-10


## Decision Log

Record every decision made while working on the plan.

- Decision: Treat IR-15 as validated and implement the optimization rather than leaving the plan
  conditional on future measurement.
  Rationale: Both strict request validators pass; `withOwnedSpan` still computes
  `T.length inputBefore - T.length inputAfter`; a temporary `-O2` current-parser probe grew from about
  7.9 ms at 29,823 characters to 99.5 ms at 253,823 characters; and the registered Megaparsec
  source provides offset-based consumed chunks without a dependency change. The permanent
  benchmark remains necessary for reproducible before/after evidence.
  Date: 2026-08-10

- Decision: Replace suffix-length subtraction with Megaparsec's `match` result and keep
  `ownedSyntaxLength` responsible for excluding trailing trivia from only the consumed chunk.
  Rationale: `match` computes the token count from start/end parser offsets and takes that many
  tokens from the starting stream. It therefore removes both whole-suffix `Text.length` traversals
  without changing the existing string-aware ownership rules or public types.
  Date: 2026-08-10

- Decision: Add a separate manual parser benchmark component and record measurements in the
  existing typed-spec user guide; do not add a timing threshold to CI.
  Rationale: Timings vary with machine load, but the benchmark is valuable when run before and
  after on one machine. Correctness stays enforced by deterministic span and compatibility tests,
  while the benchmark and direct code inspection establish the performance property.
  Date: 2026-08-10

- Decision: Reuse the package's existing Megaparsec and tasty-bench bounds without changing the
  library dependency graph.
  Rationale: `keiro-dsl` already supports Megaparsec `>=9.6 && <9.9`, where `match` is available,
  and its existing codec benchmark already uses tasty-bench `>=0.5 && <0.6`. The new benchmark is
  a separate component and introduces no runtime dependency.
  Date: 2026-08-10

- Decision: Benchmark workspaces with 32 wide aggregates rather than 256 compact aggregates.
  Rationale: `loadWorkspace` must include real composition, but a graph with 256 aggregate owners
  made composition overwhelm the span-capture cost this plan needs to compare. Wide aggregates
  retain many nested `withOwnedSpan` sites and equal total syntax across member splits without
  turning unrelated composition work into nearly all of the row runtime.
  Date: 2026-08-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

The source request is
[IR-15](../improvement-requests/avoid-repeated-input-scans-while-capturing-keiro-dsl-source-spans.md).
Its OKF metadata and log are valid: both `mori improvement-requests validate` and strict profile
enforcement report 21 valid requests/concepts. The request is deliberately non-release-blocking
and concerns the time spent parsing source in tooling, not the runtime of a generated application.

`keiro-dsl/src/Keiro/Dsl/Parser/Core.hs` defines the internal Megaparsec parser type `P`, the
whitespace consumer `sc`, token helpers such as `lexeme`, and `withOwnedSpan`. A source span is
half-open: its start points at the first owned token and its end points immediately after the last
owned token. The lexer consumes following whitespace and `#` line comments, so `withOwnedSpan`
must distinguish syntax owned by a production from trailing *trivia*, meaning whitespace and
comments that separate it from the next production.

The current helper saves the remaining `Text` before and after the production and subtracts their
`Text.length` values. Strict `Text.length` traverses the supplied text, so each located production
walks both the entire suffix before the production and the slightly shorter suffix afterward.
`withOwnedSpan` is used for the language preamble, context/module/layout clauses, every top-level
item, aggregate states and transitions, fields, nested expressions, and several feature markers.
Repeated top-level and nested uses therefore amplify the suffix work. After obtaining the consumed
length, `ownedSyntaxLength` scans only the consumed slice with three modes—ordinary syntax, string
literal, and comment—to find the last non-trivia token. That consumed-syntax scan is required and
is not the defect.

The registered dependency source at
`mori://mrkkrp/megaparsec/packages/megaparsec` defines `getOffset` as the parser state's processed
token count and `match :: MonadParsec e s m => m a -> m (Tokens s, a)`. `match` records the start
and end offsets and calls the stream's `takeN_` for only their difference. For strict `Text`,
Megaparsec implements `takeN_` with `Text.splitAt`. This is exactly the consumed-chunk operation
needed here; it avoids measuring either unconsumed suffix. `reachOffsetNoLine`, already used by
`withOwnedSpan`, advances positions over the owned prefix so line, column, Unicode, tab, and newline
semantics remain Megaparsec's responsibility.

`keiro-dsl/src/Keiro/Dsl/Parser/Document.hs` routes `parseSurfaceSource` through located grammar
productions. `keiro-dsl/src/Keiro/Dsl/Parser.hs` is the stable compatibility facade:
`parseSource`, `parseSpec`, and `parseSpecText` parse through the surface tree and
`lowerSurfaceSource`. `keiro-dsl/src/Keiro/Dsl/Workspace.hs` uses `parseSourceDocument` for every
member loaded by `loadWorkspace`, then passes the parsed members to `composeWorkspace`. A large
workspace therefore pays the same per-member span-capture cost even though its manifest parser is
a separate grammar.

`keiro-dsl/test/Keiro/Dsl/FrontendSurface.hs` owns focused source-span and lowering tests. It
already checks Unicode before a declaration, trailing comments, a multi-line aggregate, an empty
body, nested fields and expressions, complete transitions, and exact semantic-source-index
positions. `keiro-dsl/test/Keiro/Dsl/FrontendCompatibility.hs` owns the checked
`keiro-dsl/test/frontend-0.7/manifest.json` oracle for accepted/rejected sources, workspaces,
rendered diagnostics, canonical round trips, and released entry-point signatures. Before this plan
was written, the combined focused run passed 11 examples with zero failures. There is no direct
tab/mixed-newline span matrix and no parser-scaling benchmark. The complete unchanged
`keiro-dsl-test` baseline also passed 664 examples with zero failures in 273.525 seconds under
GHC 9.12.4 with Cabal's `-O1` development profile.

`keiro-dsl/keiro-dsl.cabal` declares the library and test components plus an existing
`keiro-dsl-codec-bench` tasty-bench component. The new parser benchmark should follow that
component's style but live in `keiro-dsl/bench/parser-scaling/Main.hs`. The registered benchmark
dependency is `mori://Bodigrim/tasty-bench/packages/tasty-bench`. Its local source documents
`--csv` and `--baseline` for same-machine comparison. Generate and fully force benchmark input
before `defaultMain`; do not use `env`, because it delivers a lazy resource accessor and is
unnecessary for immutable `Text` and `Map` inputs.

[Plan 173](173-introduce-located-keiro-surface-syntax-and-explicit-lowering.md) introduced the
owned-span algorithm. [Plan 219](219-preserve-exact-semantic-source-provenance-through-parsing-and-workspace-composition.md)
extended its use to states, transitions, and member-local exact indices. The durable constraints
are [ADR 0016](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md), which
requires exact non-lossless surface spans while keeping `Spec` semantic and compatibility entry
points stable, and
[ADR 0014](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md),
which requires independently parsed members to retain attributable provenance and compose into one
order-independent service graph. This optimization changes neither decision. No relevant
cross-repository ADR was found.

The pre-plan `-O2` current-parser probe was intentionally temporary and is not the deliverable, but it
established that the request is current enough to plan. It parsed valid declaration-heavy inputs
five or three times per size and observed these mean CPU seconds:

```text
characters   mean seconds
29,823       0.007854
61,823       0.016755
125,823      0.042514
253,823      0.099517
```

The permanent benchmark replaces this provisional evidence with nested aggregate and workspace
scenarios, CSV output, and an identical before/after executable surface.


## Plan of Work

Milestone 1 establishes evidence before changing production parsing. Add a
`benchmark keiro-dsl-parser-bench` stanza to `keiro-dsl/keiro-dsl.cabal` with source directory
`bench/parser-scaling`, main module `Main.hs`, and benchmark-only dependencies on `base`,
`containers`, `deepseq`, `keiro-dsl`, `tasty-bench`, and `text`. Do not change the library stanza or
any dependency bound.

Create `keiro-dsl/bench/parser-scaling/Main.hs`. It must deterministically generate valid language-4
specifications with many uniquely named aggregates. Each aggregate should contain several
registers, a multi-field command and event, states, a transition with a nested boolean/arithmetic
expression, writes, an emit, and a final `goto`, so the size ladder exercises top-level and nested
`withOwnedSpan` uses rather than only repeated simple declarations. Prepare at least four doubling
sizes and name each benchmark with both its construct count and final character count.

The benchmark should contain three groups. `surface-source` calls `parseSurfaceSource`,
`compatibility-source` calls `parseSource`, and `workspace` calls `loadWorkspace` with an in-memory
`ContentSource` over a fully forced `Map FilePath Text`. Workspace fixtures must include a valid
manifest and several uniquely named member sources with one shared context. They must exercise the
same total syntax at multiple member counts so the results distinguish one large suffix chain from
several independently parsed members. Parse every generated input once before `defaultMain` and
fail with its rendered error if a fixture is invalid. Use `whnf` for pure parsers and `whnfIO` for
`loadWorkspace`; document that reaching the outer `Right` requires Megaparsec to consume `eof`, so
weak-head evaluation completes the parse even though public parser results have no `NFData`
instance. Fully force source texts and maps outside the measured functions.

Build and run this benchmark against the unchanged `withOwnedSpan`, writing
`/tmp/keiro-dsl-parser-before.csv`. Record the machine architecture, GHC version, optimization
profile, command, scenario sizes, means, and standard deviations in this plan's Surprises &
Discoveries section. Commit the benchmark separately before editing `Parser/Core.hs`; that commit
is the reproducible old implementation baseline. Milestone 1 is accepted when all generated
fixtures parse successfully, the benchmark produces every named row, and the baseline CSV exists.

Milestone 2 makes the minimal production change. In
`keiro-dsl/src/Keiro/Dsl/Parser/Core.hs`, keep the starting offset, starting source position, and
starting positional state. Replace the two `getInput` calls and suffix-length subtraction with
`(consumed, value) <- match parser`. Pass `consumed` directly to `ownedSyntaxLength`; compute the
owned end offset from the starting offset plus the returned owned length; and retain the existing
`reachOffsetNoLine` projection. Remove no `TriviaScan` mode and do not change `sc`, `lexeme`, any
grammar production, `SourcePoint`, `SourceSpan`, or public parser/lowering signature. The intended
shape is:

```haskell
withOwnedSpan :: P a -> P (Located a)
withOwnedSpan parser = do
  startOffset <- getOffset
  startPosition <- getSourcePos
  startState <- getParserState
  (consumed, value) <- match parser
  let ownedLength = ownedSyntaxLength consumed
      endOffset = startOffset + ownedLength
      endPosition =
        pstateSourcePos
          (reachOffsetNoLine endOffset (statePosState startState))
      span =
        SourceSpan
          { source = sourceName startPosition
          , start = sourcePointAt startOffset startPosition
          , end = sourcePointAt endOffset endPosition
          }
  pure Located {span, value}
```

The actual code should preserve this current direct `SourceSpan` construction; no new public or
internal helper is needed.

Expand `keiro-dsl/test/Keiro/Dsl/FrontendSurface.hs` with a table-driven exact-span matrix. Cover a
leading tab, Unicode before owned syntax, LF, CRLF, and mixed newline sequences, leading comments,
trailing spaces/comments, `#` inside a string literal, an empty document body, and nested aggregate
fields and expressions. Assert complete start/end offsets and one-based line/column points, not
only extracted source text. Add one parity example that runs the same rich source through
`parseSurfaceSource` plus `lowerSurfaceSource`, `parseSourceDocument`, `parseSource`, `parseSpec`,
and `parseSpecText`, proving their successful semantic values agree after projecting each wrapper.
Existing failure and diagnostic goldens must not be updated.

Run the focused span, surface-lowering, workspace-provenance, and frozen-compatibility groups. Then
run the unchanged benchmark with the old CSV supplied as `--baseline` and write
`/tmp/keiro-dsl-parser-after.csv`. The largest single-source cases should be measurably faster and
the size ladder should lose the old repeated-suffix growth. Timing ratios are same-machine evidence,
not a CI threshold: if uncertainty overlaps or a scenario regresses, rerun on an idle machine and
investigate before continuing. Milestone 2 is accepted only when the code contains no full-suffix
length subtraction, all deterministic parity tests pass unchanged, and the benchmark demonstrates
the intended improvement on representative large inputs.

Milestone 3 publishes and closes the result. Add a short "Parser scaling" subsection to
`docs/user/typed-spec-toolchain.md`. State the benchmark command and workload, summarize the
before/after largest-source and workspace measurements on one machine, explain that exact span and
compatibility suites stayed unchanged, and explicitly limit the effect to parsing performed by
CLI, workspace, code-generation, and source-aware tooling. Do not claim generated application
runtime or CI-wide speedups. Add a concise `Changed` entry to `keiro-dsl/CHANGELOG.md`.

After every full gate passes, update
`docs/improvement-requests/avoid-repeated-input-scans-while-capturing-keiro-dsl-source-spans.md`:
set frontmatter status to `completed`, add
`plan: docs/plans/229-eliminate-repeated-suffix-scans-from-keiro-dsl-source-span-capture.md`, advance
its timestamp, and rewrite its Status section to summarize the implemented benchmark, optimization,
and preserved compatibility. Append the matching `Implemented` entry to
`docs/improvement-requests/log.md` with `okf log add`. Run both improvement-request validators.

Finally perform the mandatory ADR distillation pass over this plan's Decision Log, Surprises &
Discoveries, and Outcomes & Retrospective. ADR 0016 and ADR 0014 should remain unchanged if the
implementation is the planned internal optimization because their span and workspace contracts do
not change. If implementation changes a public boundary, source-position semantics, or workspace
ownership rule, amend the owning ADR and its OKF log in the same change. Record final commands and
measurements in this plan, complete Outcomes & Retrospective, and keep each implementation commit
linked with both `ExecPlan:` and `Intention:` trailers.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
```

Confirm the request, dependency, and current helper before editing:

```bash
mori improvement-requests validate --path /Users/shinzui/Keikaku/bokuno/keiro
okf validate docs/improvement-requests --strict \
  --profile mori/improvement-requests-profile.dhall \
  --profile-enforce --log-enforce
mori registry show mrkkrp/megaparsec --full
mori registry show Bodigrim/tasty-bench --full
sed -n '296,370p' keiro-dsl/src/Keiro/Dsl/Parser/Core.hs
```

The initial validation should include:

```text
OK: 21 improvement request(s)
OK: 21 concepts
```

After adding only the benchmark component and source, compile it and record the unchanged-parser
baseline. Keep the CSV outside the repository because it is machine-specific:

```bash
cabal build keiro-dsl:bench:keiro-dsl-parser-bench
cabal bench keiro-dsl:keiro-dsl-parser-bench \
  --benchmark-options='-j1 --csv /tmp/keiro-dsl-parser-before.csv'
```

Expected output names every doubling size under the three groups and ends successfully, for
example:

```text
surface-source/nested-aggregates-...: OK
compatibility-source/nested-aggregates-...: OK
workspace/members-...: OK
All 12 tests passed
```

The exact row count may be larger than 12 if the implementation adds useful sizes; document the
final count in this plan. Record the baseline immediately before changing `Parser/Core.hs`.

After the helper and tests change, run the deterministic frontend checks:

```bash
cabal test keiro-dsl:keiro-dsl-test --test-show-details=direct \
  --test-option=--match --test-option='source spans'
cabal test keiro-dsl:keiro-dsl-test --test-show-details=direct \
  --test-option=--match --test-option='surface lowering'
cabal test keiro-dsl:keiro-dsl-test --test-show-details=direct \
  --test-option=--match --test-option='workspace source provenance'
cabal test keiro-dsl:keiro-dsl-test --test-show-details=direct \
  --test-option=--match --test-option='frontend 0.7 compatibility'
```

Each command must exit zero. The compatibility group currently has six examples; its diagnostic
goldens and manifest must remain byte-identical.

Run the same benchmark executable surface against the recorded baseline:

```bash
cabal bench keiro-dsl:keiro-dsl-parser-bench \
  --benchmark-options='-j1 --baseline /tmp/keiro-dsl-parser-before.csv --csv /tmp/keiro-dsl-parser-after.csv'
```

The report should describe the largest single-source rows as faster than baseline. Copy concise
before/after values—not the machine-specific CSV files—into this plan and the typed-spec guide.

Run the complete package and repository gates before closing IR-15:

```bash
cabal build all
cabal test keiro-dsl:keiro-dsl-test --test-show-details=direct
cabal test keiro-dsl --test-show-details=direct
just adr-validate
nix fmt
nix flake check
git diff --check
git status --short
```

`nix fmt` may edit formatting; inspect and include only formatting attributable to this plan. A
successful `git diff --check` prints nothing. `git status --short` should list only this plan and
the implementation/documentation files named here.

Only after those gates pass, update IR-15 and append its bundle log entry:

```bash
okf log add docs/improvement-requests IR-15 \
  --kind Implemented \
  --message "Close IR-15 after Plan 229 benchmarks and removes repeated suffix scans while preserving exact spans and parser compatibility."
mori improvement-requests validate --path /Users/shinzui/Keikaku/bokuno/keiro
okf validate docs/improvement-requests --strict \
  --profile mori/improvement-requests-profile.dhall \
  --profile-enforce --log-enforce
git diff --check
git status --short
```

Every implementation commit must use a Conventional Commit subject and end with both trailers:

```text
ExecPlan: docs/plans/229-eliminate-repeated-suffix-scans-from-keiro-dsl-source-span-capture.md
Intention: intention_01kznxvd42efj9s5ty7tcfkjqm
```


## Validation and Acceptance

The permanent benchmark is executable acceptance evidence. It generates valid sources with many
nested fields and expressions at four or more doubling sizes and valid workspaces with multiple
members. The same benchmark component runs before and after the production edit on the same
machine. The plan and `docs/user/typed-spec-toolchain.md` record the command, environment, workload,
mean measurements, uncertainty, and largest-case improvement. At least the largest
`surface-source`, `compatibility-source`, and representative `workspace` cases must be measurably
faster after the change. If not, IR-15 remains open until the cause is understood.

Direct inspection of `withOwnedSpan` proves the algorithmic property: it uses the starting parser
offset and the consumed chunk returned by `match`; it contains no `T.length` call on the pre- or
post-production remaining input. `ownedSyntaxLength` sees only that consumed chunk. A repository
search for `T.length inputBefore`, `T.length inputAfter`, or their renamed equivalent in span
capture returns no match.

The exact-span group passes cases covering Unicode, tabs, LF/CRLF/mixed newlines, leading trivia,
trailing whitespace and comments, string-literal `#`, empty bodies, fields, states, transitions,
and nested expressions. Every expected `SourcePoint` retains its exact token offset and one-based
line/column. Half-open ends still exclude trailing trivia and include `#` when it is inside a string
literal.

For one rich accepted source, `lowerSurfaceSource` after `parseSurfaceSource` returns the same
`ParsedSource` as `parseSource`; `parseSourceDocument` projects that same parsed value;
`parseSpec` and `parseSpecText` return the same `Spec`. Existing structured failures retain their
codes and spans. The frozen frontend compatibility manifest and diagnostic files do not change,
and its complete source/workspace/round-trip/signature group passes.

The complete `keiro-dsl-test` suite and all Cabal test components selected by `cabal test keiro-dsl`
pass. `cabal build all`, strict ADR validation, formatting, `nix flake check`, and diff hygiene pass.
No generated conformance file changes solely because the parser gets faster.

IR-15 is complete only after its frontmatter and prose point to this plan, its status is
`completed`, its log contains the implementation entry, and both strict request validators pass.
The changelog and typed-spec note describe only parse-time tooling impact; they make no generated
service runtime claim.


## Idempotence and Recovery

The parser edit, input generators, tests, and documentation are deterministic and may be rebuilt or
re-run without external state. The in-memory workspace benchmark performs no filesystem writes.
Benchmark CSVs live under explicit `/tmp/keiro-dsl-parser-before.csv` and
`/tmp/keiro-dsl-parser-after.csv` paths; re-running a stage intentionally replaces its own
measurement file and does not affect repository state.

Commit the benchmark before changing `Parser/Core.hs` and write its results into this plan. If the
temporary baseline CSV is lost after the optimization lands, do not reset or overwrite the active
worktree. Create a disposable Git worktree at the benchmark-only milestone commit in a new explicit
temporary directory, run the same command there, record the new baseline environment, and remove
that disposable worktree after comparison. Never compare a result built with a different scenario
set, GHC version, optimization profile, or machine as if it were the paired baseline.

If an exact-span or compatibility test changes, revert only the `withOwnedSpan` optimization and
diagnose the position calculation; do not bless new goldens for a performance-only change. The old
implementation remains recoverable from the benchmark milestone commit. If the benchmark is noisy,
close other work, keep tasty-bench at `-j1`, and rerun both sides rather than weakening correctness
or claiming an unsupported speedup.

`okf log add` is append-only. Run it only after final gates and only once. If request validation
fails, correct the newly added IR-15 metadata/log entry in place before committing; do not add a
second contradictory closure entry. All implementation commits must leave the repository buildable
and carry the plan and intention trailers.


## Interfaces and Dependencies

No public library interface changes. `Keiro.Dsl.Source.SourcePoint`,
`Keiro.Dsl.Source.SourceSpan`, `Keiro.Dsl.Source.Located`,
`Keiro.Dsl.Frontend.parseSurfaceSource`, `Keiro.Dsl.Frontend.lowerSurfaceSource`,
`Keiro.Dsl.Parser.parseSourceDocument`, `Keiro.Dsl.Parser.parseSource`,
`Keiro.Dsl.Parser.parseSpec`, `Keiro.Dsl.Parser.parseSpecText`, and
`Keiro.Dsl.Workspace.loadWorkspace` retain their current signatures and results.

The internal helper in `keiro-dsl/src/Keiro/Dsl/Parser/Core.hs` remains:

```haskell
withOwnedSpan :: P a -> P (Located a)
```

It uses existing Megaparsec APIs from `mori://mrkkrp/megaparsec/packages/megaparsec`, specifically
`getOffset`, `getSourcePos`, `getParserState`, `match`, `reachOffsetNoLine`, `statePosState`, and
`pstateSourcePos`. The existing bound `megaparsec >=9.6 && <9.9` is unchanged. `Data.Text` remains
the parser stream; no byte-offset conversion is introduced.

The new executable component in `keiro-dsl/keiro-dsl.cabal` is:

```text
benchmark keiro-dsl-parser-bench
  type:           exitcode-stdio-1.0
  hs-source-dirs: bench/parser-scaling
  main-is:        Main.hs
```

Its benchmark-only dependency is the already used
`mori://Bodigrim/tasty-bench/packages/tasty-bench` at the existing `>=0.5 && <0.6` bound. It may
also depend on `containers`, `deepseq`, and `text` to construct and force immutable fixtures. None
is added to the library component.

`keiro-dsl/bench/parser-scaling/Main.hs` should keep its generator and failure wrappers private.
The intended internal seams are equivalent to:

```haskell
data WorkspaceFixture = WorkspaceFixture
  { fixtureManifestPath :: !FilePath
  , fixtureContents :: !(Map FilePath Text)
  }

nestedSpecification :: Text -> Int -> Text
workspaceFixture :: Int -> Int -> WorkspaceFixture
parseSurfaceOrFail :: FilePath -> Text -> SurfaceSource
parseCompatibilityOrFail :: FilePath -> Text -> ParsedSource
loadWorkspaceOrFail :: WorkspaceFixture -> IO WorkspaceSpec
```

Names may differ, but generated aggregate and member identities must be unique, every fixture must
be preflight-parsed before measurement, and all source/map values must be forced before
`defaultMain`. The benchmark exposes no application API and persists no state.
