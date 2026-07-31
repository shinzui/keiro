---
id: 160
slug: add-an-explicit-keiro-dsl-language-version-contract
title: "Add an explicit Keiro DSL language version contract"
kind: exec-plan
created_at: 2026-07-31T14:46:35Z
---

# Add an explicit Keiro DSL language version contract

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, every Keiro DSL source can state which language contract it was written for:

```keiro
language keiro-dsl 1
context hospital-capacity
```

The parser records both the declared and effective version, rejects unsupported versions before
interpreting version-sensitive syntax, and carries the version through pretty printing, workspace
composition, checking, scaffolding, fingerprints, and machine-readable inspection. Existing
unversioned sources remain readable as an explicitly identified legacy form, so current fleets can
be rewritten later without blocking this foundation.

This plan deliberately does not implement `keiro-dsl upgrade` or migrate dependent repositories.
It creates the stable source/version boundary that a later upgrade command can dispatch on.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: add the version preamble, source-version model, and early unsupported-version
  diagnostics while preserving explicit legacy-unversioned input.
- [ ] Milestone 2: propagate declared/effective versions through workspaces, pretty printing,
  inspection, scaffold records, fingerprints, and diffs.
- [ ] Milestone 3: version all Keiro-owned fixtures and generated examples, add compatibility and
  future-version tests, document the contract, and complete repository validation.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-31: No existing ExecPlan or MasterPlan child mentions a DSL source-language version or
  an upgrade dispatch boundary. Workspace schema versions and scaffold-record versions exist, but
  neither identifies the grammar/semantics used to interpret a `.keiro` source.
- 2026-07-31: Several registered dependent projects currently contain syntax that the latest
  checker no longer accepts. They are not production deployments and can be migrated later; this
  plan must not hide their source contract by assuming “whatever the installed parser means.”


## Decision Log

Record every decision made while working on the plan.

- Decision: Use a required-position source preamble, `language keiro-dsl <natural-number>`, before
  `context`, while continuing to parse a missing preamble as `LegacyUnversioned` for compatibility.
  Rationale: A fixed preamble can be recognized before the version-specific grammar. Preserving an
  explicit legacy AST state lets inspection and a later upgrader find old sources without forcing
  a fleet migration in this plan.
  Date: 2026-07-31

- Decision: Version 1 denotes the full language accepted when this plan lands; unversioned input
  has effective version 1 but is never normalized to “declared 1” in provenance unless rewritten.
  Rationale: Silent provenance rewriting would make it impossible to distinguish an intentional
  contract from legacy parser coincidence.
  Date: 2026-07-31

- Decision: Once a language version is released, later grammar or semantic capabilities do not
  silently widen it; the implementing plan registers the next version and its predecessor relation.
  Rationale: A source version must identify the minimum parser/semantics contract needed by the
  source. Otherwise an older tool and newer tool could both claim v1 support while accepting
  different v1 programs, defeating upgrade dispatch.
  Date: 2026-07-31

- Decision: Reject unsupported declared versions immediately with a stable diagnostic containing
  the declared version and the tool's supported range.
  Rationale: Parsing a future language with today's grammar can misinterpret a source before
  semantic validation. Version selection is the earliest sound boundary.
  Date: 2026-07-31

- Decision: Do not make a language-version change itself a domain wire/replay change, but include
  it in source/scaffold provenance and report it separately in diff output.
  Rationale: Rewriting an unchanged v1 source from legacy-unversioned to declared v1 should not
  manufacture an event compatibility break, while operators still need to see the contract change.
  Date: 2026-07-31

- Decision: Keep this audit follow-on as a standalone ExecPlan rather than reopening the completed
  structural-consumer-type MasterPlan.
  Rationale: The language-version contract is an independent prerequisite for later upgrade
  tooling and should expose its own implementation status.
  Date: 2026-07-31


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

`keiro-dsl/src/Keiro/Dsl/Parser.hs` currently begins a source at its `context` declaration and
selects one grammar regardless of provenance. `Grammar.hs` stores the context and declarations but
no language version. `PrettyPrint.hs` therefore cannot retain a version. `Workspace.hs` parses and
relocates member files; a workspace can currently combine sources without proving that the same
language semantics were selected for each member.

`ScaffoldRecord.hs` and `WorkspaceRecord.hs` persist generated-tree constraints, while
`FoldFingerprint.hs` and related diff/replay modules compute semantic identities. Those record
schema versions are implementation formats, not source-language versions. The CLI is assembled
under `keiro-dsl/app/` and exposes check, pretty, inspect/explain, diff, workspace, and scaffold
paths that must all report version failures consistently.

[ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) makes the
version preamble an early gate: a future declared language must fail before current parsing or
lowering. [ADR 14](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)
requires one workspace composition authority, so version compatibility belongs in workspace
loading rather than individual downstream commands. No existing ADR defines language versioning;
if implementation establishes compatibility-support policy beyond the decisions in this plan,
record it in a new ADR.

“Declared version” means the number written in the source. “Effective version” means the grammar
and semantics used by the current tool. An unversioned legacy source has no declared version but
temporarily resolves to effective version 1. This distinction must survive all machine-readable
provenance.


## Plan of Work

Milestone 1 adds `LanguageVersion`, `SourceLanguage`, and version-location fields in `Grammar.hs`.
Refactor `Parser.hs` into a version preamble parser followed by a version-selected body parser. It
must recognize the preamble without consuming future syntax, accept exactly supported version 1,
and return a stable located error for 0, 2, an invalid token, duplicate preambles, or a preamble
after `context`. Unversioned sources parse as `LegacyUnversioned` and retain their original source
shape. Add one public `supportedLanguageVersions` definition; no CLI or module may maintain its own
range.

Milestone 2 threads the value through `PrettyPrint.hs`, `Workspace.hs`, `Validate.hs`,
`FoldFingerprint.hs`, `ReplayImpact.hs`, `Diff.hs`, `ScaffoldRecord.hs`, `WorkspaceRecord.hs`, and
the JSON inspection paths. Canonical pretty output for a declared source begins with its preamble;
legacy pretty output remains unversioned unless an explicit normalization option is passed. A
workspace accepts legacy plus v1 members because both have effective version 1, but its report
lists every member's declared/effective version. Any future mix of different effective versions
must fail before AST merge. Scaffold records persist both fields and the version-selection-policy
revision so cache reuse cannot cross incompatible parser semantics.

Milestone 3 adds preamble fixtures for v1, legacy, invalid, and future versions; multi-member
workspace parity tests; parse/pretty properties; deterministic scaffold tests; and diff tests that
separate provenance-only declaration from semantic changes. Rewrite all Keiro-owned `.keiro`
fixtures and generated documentation examples to declare v1 except fixtures specifically testing
legacy behavior. Update `agents/skills/keiro-dsl-authoring/NOTATION.md`, the typed toolchain guide,
CLI help, and changelog. Do not edit other repositories. File an improvement request for the later
`keiro-dsl upgrade` command and fleet orchestration.

This version registry is a hard prerequisite for later syntax-bearing plans 158 and 161. Those
plans must allocate/register their language version(s) rather than silently adding nominal-binding
or expression syntax to a released v1 grammar. They do not need to implement the general upgrade
command, but must provide any explicit manual rewrite notes needed until IR-5 lands.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
cabal test keiro-dsl-test --test-options='--match=language.*version'
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/language-v1.keiro
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/language-future.keiro
cabal run keiro-dsl -- inspect keiro-dsl/test/fixtures/language-legacy.keiro --format=json
cabal test keiro-dsl-test
cabal build all
nix flake check
```

The v1 check exits successfully. The future-version check exits non-zero and names declared version
2 and supported version 1 without secondary grammar errors. Legacy inspection reports JSON
equivalent to:

```json
{"declaredLanguageVersion":null,"effectiveLanguageVersion":1,"sourceForm":"legacy-unversioned"}
```

During implementation, update this transcript to the final stable JSON envelope and record the
allocated diagnostic code.


## Validation and Acceptance

1. `language keiro-dsl 1` is accepted only before `context`, round-trips canonically, and is
   preserved in single-file and workspace inspection.
2. An unsupported declared version fails before version-specific parsing and emits one primary,
   stable diagnostic with the supported range. Check, scaffold, diff, inspect, and workspace
   commands agree.
3. Unversioned input remains readable, is explicitly reported as legacy, and has effective version
   1. No persisted record or JSON response falsely claims it declared v1.
4. Workspace loading reports per-member versions and rejects incompatible effective versions
   before merge. Path relocation does not change version diagnostic locations.
5. Language provenance is included in scaffold/workspace records and invalidates incompatible
   cache reuse. Adding the v1 declaration to an otherwise unchanged legacy source is reported as a
   provenance change, not a wire/replay break.
6. Every Keiro-owned ordinary fixture and documentation example declares v1; only named legacy
   compatibility fixtures remain unversioned. No dependent-repository migration is part of this
   plan.
7. The implementation exposes a single version dispatch point that can later host `v1 -> v2`
   migration logic; it does not add a placeholder upgrade command that merely rewrites a number.
8. A test fixture proves that registering a new syntax feature requires a new language-version
   parser entry; the released v1 parser table is immutable after release.


## Idempotence and Recovery

Parser, pretty, inspect, and record generation are deterministic and safe to repeat. Rewrite
Keiro-owned fixtures through a mechanical formatter/update followed by parse/pretty and generated
tree checks; keep legacy fixtures in an explicit allowlist so bulk rewrites cannot erase coverage.

If adding the field breaks record decoding, introduce an explicit record-schema migration that
maps an old record to `LegacyUnversioned`; never guess that an absent field was a declared v1. If a
new syntax feature lands concurrently, define whether it is part of v1 before merging rather than
silently expanding version 1 in only one parser branch.


## Interfaces and Dependencies

`Keiro.Dsl.Grammar` or a focused `Keiro.Dsl.LanguageVersion` module must expose equivalents of:

```haskell
newtype LanguageVersion = LanguageVersion Natural

data SourceLanguage
  = LegacyUnversioned { effectiveVersion :: LanguageVersion }
  | DeclaredLanguage
      { declaredVersion :: LanguageVersion
      , effectiveVersion :: LanguageVersion
      , versionLoc :: Loc
      }

supportedLanguageVersions :: NonEmpty LanguageVersion
```

The parser entry point must first return a source-language selection and then dispatch to a body
parser for that effective version. Machine-readable inspection and workspace records must expose
nullable declared version, non-null effective version, and a stable source-form tag. No new
external dependency is required. This plan provides the dispatch/provenance contract only;
`keiro-dsl upgrade` and fleet rewriting are intentionally deferred to their improvement request.


Revision note: Detached this plan from the completed structural-consumer-type MasterPlan so it is
an independent implementation unit, 2026-07-31.
