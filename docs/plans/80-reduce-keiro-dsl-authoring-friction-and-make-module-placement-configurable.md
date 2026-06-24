---
id: 80
slug: reduce-keiro-dsl-authoring-friction-and-make-module-placement-configurable
title: "Reduce keiro-dsl authoring friction and make module placement configurable"
kind: exec-plan
created_at: 2026-06-24T21:30:25Z
master_plan: "docs/masterplans/8-build-the-keiro-dsl-service-dsl-toolchain.md"
---

# Reduce keiro-dsl authoring friction and make module placement configurable

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`keiro-dsl` is a command-line tool that turns a typed `.keiro` specification of a backend
service into compiling Haskell. It lives in the directory `keiro-dsl/` of this repository.
You run it as `cabal run keiro-dsl -- <subcommand>`. Its four subcommands today are `parse`
(pretty-print a spec), `check` (validate a spec and exit non-zero on errors), `scaffold`
(emit Haskell modules from a spec into a directory), and `diff` (classify spec changes as
ADDITIVE or BREAKING against a git ref). The modules it emits come in two flavours: a
`-- @generated` deterministic layer that is overwritten on every run, and create-if-absent
"hole" modules (`Holes.hs`, `ProcessHoles.hs`) that a human fills in with the behaviour-bearing
code. A "hole" is a typed function stub with a `-- HOLE …` comment telling the author what
decision to encode.

Today, after you run `scaffold`, three things make daily use painful, and one of them blocks
adoption by teams outright:

1. **Module placement is hard-wired (the blocker).** Every emitted module is forced into the
   namespace `Generated.<Context>.<Node>` (for the generated layer) and `<Context>.<Node>`
   (for the hole module), rooted at whatever directory you pass to `--out`. A team whose code
   lives under, say, `Acme.Hospital.Reservation.*` cannot put the generated modules next to
   their domain code; they are stuck with a parallel `Generated.*` tree. There is a dormant
   `moduleRoot` field on the internal `Context` record that was *designed* to allow a namespace
   prefix, but it is dead: `mkContext` in `keiro-dsl/app/Main.hs` hard-codes it to the empty
   string, and no command-line flag or spec clause ever sets it. This plan makes module
   placement configurable so each domain's generated and hole modules can be collocated with
   that domain's existing code.

2. **`scaffold` emits source but no build wiring.** It writes `.hs` files and stops. It never
   tells you which modules it wrote, nor produces the Cabal `other-modules` list and
   `build-depends` you must add to compile them. The proof of the pain is `keiro-dsl/keiro-dsl.cabal`
   itself: roughly twenty conformance test stanzas whose `other-modules` blocks are hand-typed
   copies of the scaffolder's own output paths. This plan makes `scaffold` emit a build manifest
   so wiring becomes copy-paste (or fully mechanical), not hand-transcription.

3. **`scaffold` is silent and the firewall check is a manual grep.** The tool's load-bearing
   correctness rule — the "firewall invariant", meaning no generated module may contain a keiki
   symbolic operator (`./=`, `.==`, `.||`, `lit`, `B.slot`, `B.requireGuard`) — is today verified
   by a human copy-pasting a `grep` from the authoring docs. This plan has `scaffold` check its
   own output and print a report: what it wrote (generated vs. hole-created vs. hole-skipped),
   whether the firewall held, and which test component pins the behaviour.

4. **Per-iteration overhead and a blank-page problem.** Every action is a verbose
   `cabal run keiro-dsl -- …` that rebuilds; `parse` largely duplicates `check`; and there is no
   way to generate a starter spec. This plan adds small ergonomic wins: a `check` that can also
   pretty-print, a one-shot `check`-then-`scaffold`, and a `new <kind>` subcommand that prints a
   minimal valid spec skeleton.

After this change a user can run `cabal run keiro-dsl -- scaffold service.keiro --out src --module-root Acme --collocate`
and watch the generated modules land at `src/Acme/Hospital/Reservation/Generated/*.hs` (module
`Acme.Hospital.Reservation.Generated.*`) right beside their hand-written domain code, see a
printed report confirming the firewall held and naming the modules written, and copy a ready-made
`other-modules` block out of an emitted manifest file into their Cabal stanza. They can bootstrap
a new spec with `cabal run keiro-dsl -- new aggregate`. None of this changes the meaning of an
existing spec, and the default output (no new flags) stays byte-for-byte identical to today's.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] **M1 — Configurable module placement.** (2026-06-24) Threaded a `Placement` policy through
      `Context` (`GeneratedPrefix`/`CollocatedLeaf`, with `defaultContext`/`genPrefixFor`/
      `holePrefixFor`); added `--module-root`/`--collocate` CLI flags and optional spec
      `module`/`layout` clauses (parser + pretty-printer round-trip). Default output verified
      byte-identical (`diff -r` clean; scaffold-conformance green; 49/49 tests pass; sampled
      conformance suites build).
- [x] **M2 — Build-wiring manifest.** (2026-06-24) New `Keiro.Dsl.Manifest`
      (`renderManifest`/`manifestDependencies`/`moduleNameOf`); `scaffold` writes
      `keiro-dsl-manifest.<context>.txt` into `--out` with a Cabal-pasteable `other-modules:`
      block (dotted names, sorted) and a node-kind-derived `build-depends:` block. Verified the
      reservation manifest's `other-modules`/`build-depends` match the conformance stanza
      verbatim; tests assert module-list = scaffolder output and the per-kind dep sets.
- [x] **M3 — Self-firewall check + post-scaffold report.** (2026-06-24) Added
      `forbiddenOperators`/`firewallBreaches` to `Scaffold` (`lit` word-matched, symbolic
      operators substring-matched, Generated-only). `writeModule` now returns a disposition;
      `scaffold` prints a stderr report (per-module gen/hole + overwritten/created/skipped,
      `firewall: OK (N scanned, 0 forbidden)`, harness component(s), manifest path) and exits
      non-zero on a breach. Tests cover synthetic breach, hole-module exemption, `lit`
      word-boundary, and clean real output. LOOP.md's manual grep replaced with the built-in
      check. Mutation/diff scripts (`mutation-test.sh`, `process-`, `workflow-`, `diff-test.sh`)
      all pass.
- [ ] **M4 — Per-iteration ergonomics.** `check --emit` pretty-prints on success; a `--scaffold`
      shortcut runs check-then-scaffold; document/install a `keiro-dsl` wrapper.
- [ ] **M5 — `new <kind>` starter skeletons.** A `new` subcommand prints a minimal valid spec for
      each node kind (aggregate, process, contract/intake/emit/publisher, workqueue/dispatch,
      workflow/operation).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The mutation-test scripts (`process-mutation-test.sh`, `workflow-mutation-test.sh`)
  re-scaffold into the tracked `test/conformance-*` dirs. Because the committed Generated
  fixtures are fourmolu-formatted but the scaffolder emits unformatted text (blank line after
  pragmas, original import order), running those scripts leaves the tracked `.hs` files showing
  as modified (formatting-only) — pre-existing behaviour, not a regression. Restore with
  `git checkout -- keiro-dsl/test/conformance-process/` after running them. M2 also makes those
  runs drop a `keiro-dsl-manifest.<context>.txt` into the dir; added `keiro-dsl-manifest.*.txt`
  to `.gitignore` so the informational artifact is never committed.
- The default scaffold output stays byte-identical for the `.hs` modules, but M2 adds the
  manifest file to the `--out` directory, so a `diff -r baseline after` now reports the manifest
  as an extra file. The backwards-compat guarantee is on module *text* (pinned by the
  scaffold-conformance property), which remains green.


## Decision Log

Record every decision made while working on the plan.

- Decision: Carry module placement on the existing `Context` record rather than inventing a new
  parameter threaded through every emitter.
  Rationale: `Context` is already the single value threaded into `scaffoldAggregate`,
  `scaffoldProcess`, `scaffoldContract`, `scaffoldIntake`, `scaffoldPublisher`,
  `scaffoldWorkqueue`, and the harness emitters, and its Haddock already states it is "Extended
  additively (never re-shaped) by later verticals." The dormant `moduleRoot :: !Text` field
  (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs:74`) was put there for exactly this. We extend it, we do
  not replace it.
  Date: 2026-06-24

- Decision: Default output must remain byte-identical to today's. The new placement knobs default
  to the current behaviour (`moduleRoot = ""`, "Generated" as a *prefix* namespace).
  Rationale: `keiro-dsl/test/Main.hs` contains a "scaffold-conformance" property that pins the
  emitted text byte-for-byte against the checked-in `Generated.*` fixtures under
  `keiro-dsl/test/conformance*/`. Any default-changing edit would turn that test red and break
  every conformance suite. Backwards compatibility is therefore a hard acceptance criterion, not
  a nicety.
  Date: 2026-06-24

- Decision: Offer two placement *styles* — "prefix" (today's `Generated.<Ctx>.<Node>`) and
  "collocated leaf" (`<Ctx>.<Node>.Generated`, with the hole module at `<Ctx>.<Node>.Holes`) —
  selected by a `--collocate` flag / `layout collocated` spec clause, on top of a `--module-root`
  namespace prefix.
  Rationale: The team requirement is to place generated modules *next to the domain code for each
  domain*. Domain code at `Acme.Hospital.Reservation.*` wants generated modules under
  `Acme.Hospital.Reservation.Generated.*` (a leaf under the domain), not a sibling `Generated.*`
  tree. "Prefix" preserves back-compat and is the default; "collocated leaf" satisfies the new
  requirement. A free-form template was rejected as over-general for the two real layouts.
  Date: 2026-06-24

- Decision: Spec-level placement (`module`/`layout` clauses) is the source-of-truth default; CLI
  flags override it per invocation.
  Rationale: The `.keiro` file is the permanent source of truth, so a team's standing layout
  belongs in the spec. But the *same* spec may be scaffolded into different repositories/checkouts,
  so a per-invocation CLI override is also needed. Precedence: CLI flag > spec clause > built-in
  default.
  Date: 2026-06-24

- Decision: No intention linkage for this plan (proceeded without an Intention ID).
  Rationale: The authoring session could not reliably display the interactive intention prompt;
  per the exec-plan skill, work proceeds without the trailer when intention linkage is skipped.
  Date: 2026-06-24


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Everything in this plan lives under the directory `keiro-dsl/` at the repository root
(`/Users/shinzui/Keikaku/bokuno/keiro`). Run every command from the repository root unless told
otherwise.

The toolchain is a small Haskell project. Its library modules are under `keiro-dsl/src/Keiro/Dsl/`:

- `Grammar.hs` — the typed AST (`Spec`, `Node`, `Aggregate`, `ProcessNode`, `ContractNode`,
  `IntakeNode`, `EmitNode`, `PublisherNode`, `WorkqueueNode`, `PgmqDispatchNode`, `WorkflowNode`,
  `OperationNode`, plus field/expr types). `Spec` has `specContext :: Text` (the `context <name>`
  declared at the top of a `.keiro` file) and `specNodes :: [Node]`.
- `Parser.hs` — a megaparsec parser. `parseSpec :: FilePath -> Text -> Either ParseError Spec`.
  The lexer has a `reservedWords` list and a `keyword` combinator; adding a new top-level clause
  (for `module`/`layout`) means adding to this parser.
- `Validate.hs` — `validateSpec :: Spec -> [Diagnostic]`, returning structured, line-numbered
  diagnostics with machine codes (`DiagnosticCode`). Empty list means valid.
- `Scaffold.hs` — the code generator. The key value is `Context`:

  ```haskell
  data Context = Context
      { contextName :: !Text
      , moduleRoot  :: !Text   -- dormant today: always ""
      }
  ```

  Every emitter computes its module namespace identically. For an aggregate, `resolveAgg`
  (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs:116`) computes:

  ```haskell
  root        = case moduleRoot ctx of r | T.null r -> ""; r -> r <> "."
  aGenPrefix  = root <> "Generated." <> ctxPascal <> "." <> nm   -- e.g. Generated.HospitalCapacity.Reservation
  aHolePrefix = root <> ctxPascal <> "." <> nm                   -- e.g. HospitalCapacity.Reservation
  ```

  where `ctxPascal = pascalFromKebab (contextName ctx)` and `nm` is the node name. The exact same
  three-line pattern (a local `root`, then `root <> "Generated." <> ctxPascal <> "." <> <name>`)
  is repeated for the contract emitter (`Scaffold.hs:229-230`), the intake emitter
  (`:347-348`), the publisher emitter (`:419-420`), the workqueue emitter (`:474-475`), and the
  process emitter (around `:582`). The on-disk path is always the prefix with `.` replaced by `/`,
  appended with the module leaf and `.hs`, e.g.
  `modulePath = T.unpack (T.replace "." "/" (aGenPrefix a) <> "/" <> name <> ".hs")`
  (`Scaffold.hs:196`). So the namespace prefix *is* the directory layout under `--out`.

  A `ScaffoldModule` is the unit of output:

  ```haskell
  data ScaffoldModule = ScaffoldModule
      { modulePath :: !FilePath   -- relative to --out
      , moduleText :: !Text
      , kind       :: !ModuleKind -- Generated | HoleStub
      }
  ```

- `Harness.hs` — emits the behaviour-pinning test modules. `harnessFor` emits `…/Harness.hs`
  (aggregate), `harnessProcess` emits `…/ProcessHarness.hs`, `harnessWorkflow` emits
  `…/WorkflowFacts.hs` and `…/WorkflowRuntime.hs`. These use the same genPrefix derivation, so
  they move with the placement policy automatically once `Context` carries it.

- `Diff.hs`, `PrettyPrint.hs` — the `diff` classifier and the pretty-printer used by `parse`.

The command-line front end is `keiro-dsl/app/Main.hs`. It defines `data Command = Parse … | Check … | Scaffold FilePath FilePath | Diff …`, an optparse-applicative `commands` parser, and `run :: Command -> IO ()`. The function that turns a parsed `Spec` into a `Context` is:

```haskell
mkContext :: Spec -> Context
mkContext spec = Context{contextName = specContext spec, moduleRoot = ""}
```

This is the single place where `moduleRoot` is wired to a constant, and the place this plan
changes first. `run (Scaffold fp out)` parses, builds the context, concatenates the module lists
from every emitter, and calls `writeModule out` for each. `writeModule` (`Main.hs:129`) writes
`Generated` modules unconditionally and `HoleStub` modules only when absent — it already computes
the "exists / does not exist" fact this plan wants to report, then discards it.

The test project has two relevant suites declared in `keiro-dsl/keiro-dsl.cabal`:

- `keiro-dsl-test` (`hs-source-dirs: test`, `main-is: Main.hs`) — the unit/property suite. It
  contains the "scaffold-conformance" test that pins emitted text byte-for-byte. **This is the
  guardrail for backwards compatibility.**
- `keiro-dsl-conformance*` (many suites) — each compiles a checked-in copy of the scaffolder's
  `Generated.*` output plus a hand-filled `Holes.hs` against the live `keiki`/`keiro` runtime.
  Their `other-modules` lists are the hand-maintained Cabal wiring this plan aims to make
  mechanical.

Term definitions used below. **Firewall invariant**: no `-- @generated` module may contain any
of the keiki symbolic operators `./=`, `.==`, `.||`, the function `lit`, or the qualified names
`B.slot`, `B.requireGuard`; these belong only in hand-filled hole modules. **Harness**: the
emitted test module that pins behaviour (`Harness.hs` / `ProcessHarness.hs` / `WorkflowFacts.hs`).
**Manifest**: a small text file this plan introduces, listing every module `scaffold` wrote, its
kind, and the Cabal dependencies implied by the spec's node kinds.


## Plan of Work

The work is five milestones. M1 is first and load-bearing because it is the adoption blocker and
because the manifest in M2 must report whatever placement M1 produces. Each milestone is
independently verifiable and leaves the toolchain compiling and the conformance suites green.

### Milestone 1 — Configurable module placement

Scope: let an author choose where generated and hole modules land, both as a standing default in
the spec and as a per-invocation CLI override, while keeping the no-flags default byte-identical
to today.

At the end of M1: `cabal run keiro-dsl -- scaffold service.keiro --out src --module-root Acme --collocate`
writes generated modules to `src/Acme/<Ctx>/<Node>/Generated/*.hs` (module
`Acme.<Ctx>.<Node>.Generated.*`) and the hole module to `src/Acme/<Ctx>/<Node>/Holes.hs` (module
`Acme.<Ctx>.<Node>.Holes`); and a spec containing `module Acme` / `layout collocated` produces the
same placement with no flags. Running `scaffold` with no new flags produces exactly today's bytes.

Concretely:

1. In `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, replace the single dormant `moduleRoot` field with a
   placement policy. Keep `moduleRoot` as the namespace-prefix carrier and add a style selector:

   ```haskell
   data Placement
       = GeneratedPrefix   -- today's default: <root>.Generated.<Ctx>.<Node>, holes at <root>.<Ctx>.<Node>
       | CollocatedLeaf    -- new: <root>.<Ctx>.<Node>.Generated, holes at <root>.<Ctx>.<Node>.Holes
       deriving stock (Eq, Show)

   data Context = Context
       { contextName :: !Text
       , moduleRoot  :: !Text       -- "" means no prefix (unchanged default)
       , placement   :: !Placement  -- defaults to GeneratedPrefix (unchanged default)
       }
   ```

   Provide a smart constructor `defaultContext :: Text -> Context` so callers that do not care
   about placement (tests, `parse`) get today's behaviour: `Context name "" GeneratedPrefix`.

2. Factor the namespace derivation into two shared helpers so the six emitters and the harness
   stop repeating the three-line `root <> "Generated." <> …` pattern:

   ```haskell
   -- | The generated-layer namespace for a node, honouring root + placement.
   genPrefixFor  :: Context -> Text {- pascal node name -} -> Text
   -- | The hand-owned (hole) namespace for a node.
   holePrefixFor :: Context -> Text -> Text
   ```

   For `GeneratedPrefix`: `genPrefixFor = root <> "Generated." <> ctxPascal <> "." <> node` and
   `holePrefixFor = root <> ctxPascal <> "." <> node` — identical to today. For `CollocatedLeaf`:
   `genPrefixFor = root <> ctxPascal <> "." <> node <> ".Generated"` and
   `holePrefixFor = root <> ctxPascal <> "." <> node`. Replace every open-coded prefix computation
   in `Scaffold.hs` (aggregate `resolveAgg`, contract, intake, publisher, workqueue, process) and
   in `Harness.hs` with a call to these helpers. This is a pure refactor for the default style and
   the only place the new style is realised.

3. In `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, add optional placement to the spec. Add fields to
   `Spec` (e.g. `specModuleRoot :: !(Maybe Text)` and `specLayout :: !(Maybe Placement)` — or a
   single `specPlacement :: Maybe (Text, Placement)`). Keep them `Maybe` so existing specs parse
   unchanged.

4. In `keiro-dsl/src/Keiro/Dsl/Parser.hs`, parse two new optional top-level clauses that may
   appear right after `context <name>`: `module <DottedModulePrefix>` and `layout (prefixed|collocated)`.
   Add `module` and `layout` (and `prefixed`/`collocated` if you lex them as keywords) to
   `reservedWords`. A `DottedModulePrefix` is one-or-more PascalCase segments joined by dots, e.g.
   `Acme.Services`. Default when absent: root `""`, layout `prefixed`.

5. In `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs`, render the new clauses when present so
   `parse` round-trips a spec that uses them. (A spec without the clauses must pretty-print exactly
   as before.)

6. In `keiro-dsl/app/Main.hs`: add `--module-root STRING` and `--collocate` (a switch) to the
   `scaffold` subcommand parser. Change `mkContext` to fold spec clauses and CLI flags with the
   precedence CLI > spec > default:

   ```haskell
   mkContext :: Maybe String -> Bool -> Spec -> Context
   mkContext cliRoot cliCollocate spec =
       Context
         { contextName = specContext spec
         , moduleRoot  = maybe (fromMaybe "" (specModuleRoot spec)) T.pack cliRoot
         , placement   = if cliCollocate then CollocatedLeaf
                                         else fromMaybe GeneratedPrefix (specLayout spec)
         }
   ```

   (Adjust to whatever field shape M1.3 chose.) Thread the two new `Scaffold` command fields
   through `run (Scaffold …)`.

Acceptance for M1 is in Validation and Acceptance below; the key guard is that
`cabal test keiro-dsl-test` (the scaffold-conformance property) stays green with no fixture edits,
proving the default path is byte-identical.

### Milestone 2 — Build-wiring manifest

Scope: make `scaffold` emit, alongside the modules, a manifest that lists what it wrote and the
Cabal wiring needed to compile it, so a team stops hand-transcribing `other-modules`.

At the end of M2: every `scaffold` run also writes `keiro-dsl-manifest.txt` into the `--out`
directory (one per run; if multiple services are scaffolded to the same dir, the file name is
`keiro-dsl-manifest.<context>.txt`). The manifest contains, in plain text a human can paste into a
`.cabal` file: an `other-modules:` block listing every generated and hole module name (dotted,
not path), a `build-depends:` block listing the dependencies implied by the node kinds present,
and a short comment header naming the source spec.

Concretely:

1. In `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` (or a new small module `Keiro/Dsl/Manifest.hs`), add a
   pure function:

   ```haskell
   -- | Render a Cabal-pasteable manifest from the modules a scaffold run produced
   --   plus the node kinds present (which imply the dependency set).
   renderManifest :: Text {- spec name -} -> [ScaffoldModule] -> Spec -> Text
   ```

   The module *name* (dotted) is recoverable from `modulePath` by dropping the trailing `.hs` and
   replacing `/` with `.`. The dependency set is a pure function of which `Node` constructors occur
   in the spec, grounded in the existing per-suite `build-depends` in `keiro-dsl/keiro-dsl.cabal`:
   aggregate ⇒ `aeson, keiki, keiro, text`; intake/publisher ⇒ `keiro` (+ `kiroku-store`,
   `hasql-transaction`, `effectful-core` for the full integration path); workqueue/dispatch ⇒
   `keiro-pgmq` (+ `aeson, text`); workflow/operation ⇒ `keiro, text` (+ `effectful-core` for the
   filled body); process ⇒ `aeson, keiki, keiro, text, time, uuid`. Encode this mapping as a small
   lookup table with a comment citing the cabal stanzas it was derived from.

2. In `keiro-dsl/app/Main.hs`, `run (Scaffold …)` writes the manifest after the modules. The
   manifest is informational output, not a `ScaffoldModule`, so it does not participate in the
   firewall scan and is always overwritten.

The manifest is deliberately a *paste aid*, not an automated cabal edit — editing a consumer's
`.cabal` in place is out of scope and risky. The acceptance is that the emitted `other-modules`
block, pasted into a fresh stanza, compiles the scaffolded modules.

### Milestone 3 — Self-firewall check and post-scaffold report

Scope: make `scaffold` verify its own firewall invariant and print a structured report, replacing
the manual grep in the authoring docs and surfacing the harness component.

At the end of M3: `scaffold` prints to standard error a report like:

```text
scaffold: hospital-surge.keiro -> src/ (module-root=Acme, layout=collocated)
  generated  Acme.HospitalCapacity.HospitalSurge.Process            (overwritten)
  generated  Acme.HospitalCapacity.HospitalSurge.ProcessHarness     (overwritten)
  hole       Acme.HospitalCapacity.HospitalSurge.ProcessHoles       (created)
  hole       Acme.HospitalCapacity.Surge.Holes                      (skipped: already present)
firewall: OK (12 generated modules scanned, 0 forbidden operators)
harness:  run `cabal test <your-component>` over Acme.HospitalCapacity.HospitalSurge.ProcessHarness
manifest: src/keiro-dsl-manifest.hospital-capacity.txt
```

and exits non-zero if any generated module contains a forbidden operator.

Concretely:

1. Add a pure firewall scanner in `Scaffold.hs`:

   ```haskell
   -- | The forbidden keiki symbolic operators that must never appear in a
   --   @-- @generated@ module (the firewall invariant).
   forbiddenOperators :: [Text]   -- ["./=", ".==", ".||", "lit", "B.slot", "B.requireGuard"]

   -- | Scan generated modules for firewall breaches; returns offending (module, operator, line).
   firewallBreaches :: [ScaffoldModule] -> [(FilePath, Text, Int)]
   ```

   Scan only modules whose `kind == Generated`. Match the operators textually (the same set the
   docs grep for), being careful that `lit` is matched as a word, not a substring of `quality`.

2. In `Main.hs`, `writeModule` already distinguishes "created" from "skipped: already present" for
   hole modules — return that fact instead of discarding it, and collect a per-module disposition.
   After writing, print the report (modules + dispositions, firewall verdict, the harness module
   name(s) recovered from the `…Harness`/`…ProcessHarness`/`…WorkflowFacts` modules in the output
   list, and the manifest path). Exit non-zero on any firewall breach.

This makes the LOOP.md step-4 grep obsolete; update that doc in M3 to point at the built-in check.

### Milestone 4 — Per-iteration ergonomics

Scope: small wins that cut the per-edit loop. At the end of M4: `check --emit` pretty-prints the
spec on success (folding the common `parse`-then-`check` into one call); a `scaffold` run can be
preceded by validation in one command (either `check` gains a `--scaffold DIR` option or `scaffold`
runs `validateSpec` first and refuses on errors — choose the latter as it is safer and needs no new
flag); and the authoring docs gain a one-line `keiro-dsl` shell wrapper so users stop typing
`cabal run keiro-dsl --` each time.

Concretely: in `Main.hs`, have `run (Scaffold …)` call `validateSpec` after parsing and abort with
the diagnostics (reusing `renderDiagnostic`) if any are errors — so you can never scaffold an
invalid spec. Add an `--emit` switch to `check` that prints `renderSpec spec` to stdout on success.
Add a `keiro-dsl/bin/keiro-dsl` wrapper script (`exec cabal run -v0 keiro-dsl -- "$@"`) and mention
it in `agents/skills/keiro-dsl-authoring/LOOP.md` and `SKILL.md`.

### Milestone 5 — `new <kind>` starter skeletons

Scope: remove the blank-page cost. At the end of M5: `cabal run keiro-dsl -- new aggregate` prints
a minimal, valid `.keiro` spec for an aggregate to stdout (and likewise `process`, `contract`,
`intake`, `emit`, `publisher`, `workqueue`, `dispatch`, `workflow`, `operation`). Each printed
skeleton must itself pass `check` (a test asserts this), so the skeletons double as living,
guaranteed-valid notation examples.

Concretely: add `New String` to `data Command`, a `new` subparser taking the kind, and a pure
`skeletonFor :: Text -> Either Text Text` returning the spec text (or an error listing valid kinds).
Source the skeletons from the smallest passing fixtures already in `keiro-dsl/test/fixtures/`
(e.g. `reservation.keiro`, `hospital-surge.keiro`, `contract.keiro`, `intake.keiro`,
`subscription.keiro`, `workflow.keiro`) reduced to their minimal valid form.


## Concrete Steps

Run all commands from `/Users/shinzui/Keikaku/bokuno/keiro`.

Establish the baseline before any edit, so you can prove the default path is unchanged later:

```bash
cabal build keiro-dsl 2>&1 | tail -3
cabal test keiro-dsl-test 2>&1 | tail -5            # scaffold-conformance must be green
cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/hospital-surge.keiro --out /tmp/keiro-baseline
find /tmp/keiro-baseline -name '*.hs' | sort > /tmp/keiro-baseline-modules.txt
```

After M1, re-run the same scaffold with **no new flags** into a fresh dir and diff the trees; they
must be identical:

```bash
cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/hospital-surge.keiro --out /tmp/keiro-after
diff -r /tmp/keiro-baseline /tmp/keiro-after && echo "DEFAULT UNCHANGED"
```

Then exercise the new placement and observe the collocated tree:

```bash
cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/hospital-surge.keiro \
  --out /tmp/keiro-collocated --module-root Acme --collocate
find /tmp/keiro-collocated -name '*.hs' | sort
# expect paths like /tmp/keiro-collocated/Acme/HospitalCapacity/HospitalSurge/Generated/Process.hs
# and a hole at         /tmp/keiro-collocated/Acme/HospitalCapacity/HospitalSurge/ProcessHoles.hs
```

For M2/M3, after a scaffold run, inspect the manifest and the printed report:

```bash
cabal run -v0 keiro-dsl -- scaffold keiro-dsl/test/fixtures/reservation.keiro --out /tmp/keiro-m2
cat /tmp/keiro-m2/keiro-dsl-manifest*.txt       # other-modules + build-depends blocks
```

For M5:

```bash
cabal run -v0 keiro-dsl -- new aggregate | cabal run -v0 keiro-dsl -- check /dev/stdin ; echo "exit=$?"
# expect: OK / exit=0
```

(Update this section with real transcripts as each milestone lands.)


## Validation and Acceptance

The change is effective when all of the following hold. Each is a behaviour a human can run and
observe, not an internal attribute.

1. **Backwards compatibility (the hard gate).** `cabal test keiro-dsl-test` is green with no edits
   to any `Generated.*` fixture, and `diff -r` between a pre-change scaffold and a post-change
   no-flags scaffold of the same fixture reports no differences. This proves the default output is
   byte-identical. Additionally, every `keiro-dsl-conformance*` suite still builds:
   `cabal build all 2>&1 | tail -5` shows no failures.

2. **Collocation works (the new requirement).** Scaffolding `hospital-surge.keiro` with
   `--module-root Acme --collocate` produces generated modules whose `module` header reads
   `Acme.HospitalCapacity.HospitalSurge.Generated.*` (verify with
   `grep -rh '^module ' /tmp/keiro-collocated`), placed at the matching directory path, with the
   hole module at `Acme.HospitalCapacity.HospitalSurge.ProcessHoles`. The same placement is
   produced from a spec carrying `module Acme` / `layout collocated` with no CLI flags. Add a
   parser/scaffold unit test in `keiro-dsl/test/Main.hs` asserting both the prefix and collocated
   prefixes for a sample spec, and a round-trip test that `parse` preserves the `module`/`layout`
   clauses.

3. **Manifest compiles.** Take a fresh service spec, scaffold it, create a new test-suite stanza in
   a scratch `.cabal` whose `other-modules` and `build-depends` are pasted verbatim from the emitted
   manifest, and `cabal build` it — it compiles. (For automated proof, add a test that the manifest's
   module list equals the set of `modulePath`s the scaffolder returned, and that its dependency set
   matches the node kinds present.)

4. **Firewall self-check fires.** A unit test feeds `firewallBreaches` a synthetic `Generated`
   module text containing `./=` and asserts a non-empty result; and asserts that real scaffolder
   output for every fixture yields an empty result (the firewall holds). Running `scaffold` on a
   normal spec prints `firewall: OK` and exits 0.

5. **Validation gate.** `scaffold` on an invalid spec (e.g.
   `keiro-dsl/test/fixtures/reservation-bad-command.keiro`) prints the diagnostics and exits
   non-zero *without writing modules*. `check --emit` on a valid spec prints the pretty-printed spec
   and exits 0.

6. **Skeletons are valid.** A test enumerates every `new <kind>` skeleton, runs it through
   `parseSpec` then `validateSpec`, and asserts zero error-severity diagnostics for each.

The existing mutation tests under `keiro-dsl/test/` (`mutation-test.sh`, `process-mutation-test.sh`,
`workflow-mutation-test.sh`, `diff-test.sh`) must still pass; run them after M1–M3.


## Idempotence and Recovery

`scaffold` is already idempotent by construction: `Generated` modules are overwritten every run and
`HoleStub` modules are written only when absent (`writeModule`, `Main.hs:129`). The manifest (M2) is
always overwritten, so re-running is safe. The placement change (M1) is a pure renaming of output
paths; running into a fresh `--out` directory is always safe, and running into an existing one only
overwrites generated modules and leaves filled holes untouched — the same guarantee as today.

If M1 accidentally changes default output, the scaffold-conformance test in `keiro-dsl-test` turns
red immediately; do not "fix" it by editing fixtures — fix the helper so the default style emits the
original bytes. Keep each milestone on its own commit (with the `ExecPlan:` trailer) so any milestone
can be reverted independently. The forbidden-operator scan (M3) is read-only over in-memory text and
cannot damage anything.


## Interfaces and Dependencies

No new third-party dependencies are required; everything uses the libraries already in
`keiro-dsl.cabal` (`megaparsec`, `prettyprinter`, `text`, `containers`, `optparse-applicative`,
`directory`, `filepath`, `process`).

Types and signatures that must exist at the end of each milestone (full module paths):

- End of M1, in `Keiro.Dsl.Scaffold`:
  - `data Placement = GeneratedPrefix | CollocatedLeaf` (Eq, Show), exported.
  - `data Context = Context { contextName :: !Text, moduleRoot :: !Text, placement :: !Placement }`,
    exported, with `defaultContext :: Text -> Context`.
  - `genPrefixFor :: Context -> Text -> Text` and `holePrefixFor :: Context -> Text -> Text`,
    exported (consumed by `Keiro.Dsl.Harness`).
  - In `Keiro.Dsl.Grammar`: `Spec` carries optional placement (`specModuleRoot :: Maybe Text`,
    `specLayout :: Maybe Placement`, or an equivalent single field).
  - In `Keiro.Dsl.Parser`: `parseSpec` accepts the optional `module`/`layout` clauses; signature
    unchanged.
  - In `Main`: `mkContext :: Maybe String -> Bool -> Spec -> Context`; `data Command`'s `Scaffold`
    variant carries the module-root and collocate fields.
- End of M2, in `Keiro.Dsl.Scaffold` (or `Keiro.Dsl.Manifest`):
  `renderManifest :: Text -> [ScaffoldModule] -> Spec -> Text`, exported.
- End of M3, in `Keiro.Dsl.Scaffold`:
  `forbiddenOperators :: [Text]` and `firewallBreaches :: [ScaffoldModule] -> [(FilePath, Text, Int)]`,
  exported.
- End of M4, in `Main`: `check` parser gains an `--emit` switch; `run (Scaffold …)` runs
  `validateSpec` and aborts on errors. New file `keiro-dsl/bin/keiro-dsl` (executable wrapper).
- End of M5, in `Main`: `data Command` gains `New String`; `skeletonFor :: Text -> Either Text Text`
  (place in `Main` or a tiny `Keiro.Dsl.Skeleton` module so it is unit-testable).

Downstream consumers to keep green: every `keiro-dsl-conformance*` suite in `keiro-dsl.cabal`, and
the authoring skill docs `agents/skills/keiro-dsl-authoring/{SKILL.md,LOOP.md,NOTATION.md}` (update
LOOP.md's manual firewall grep to the built-in check in M3, and document `--module-root`/`--collocate`
and `new` in SKILL.md/NOTATION.md as those land).
