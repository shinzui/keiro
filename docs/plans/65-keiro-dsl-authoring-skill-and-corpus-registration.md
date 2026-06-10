---
id: 65
slug: keiro-dsl-authoring-skill-and-corpus-registration
title: "keiro-dsl authoring skill and corpus registration"
kind: exec-plan
created_at: 2026-06-10T01:05:27Z
intention: "intention_01ktqdn85xe2btqzr2zghxgrpr"
master_plan: "docs/masterplans/8-build-the-keiro-dsl-service-dsl-toolchain.md"
---

# keiro-dsl authoring skill and corpus registration

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`keiro-dsl` is a **typed-spec toolchain** over `.kdsl` files: the spec is the permanent,
machine-checkable source of truth for what a keiro service is, and the toolchain `check`s
it before any code exists, `scaffold`s the symbol-free deterministic layer (into
`-- @generated` modules) plus precisely-typed holes (into hand-owned modules) plus a
verification harness, and `diff`s the spec across its lifetime to gate unsafe evolution.
The full toolchain — the engine and every node vertical — is delivered by the predecessor
plans of this MasterPlan: `docs/plans/59-keiro-dsl-foundations-grammar-parser-validator-scaffold-and-harness-engine-aggregate-vertical.md`
(engine + aggregate), `docs/plans/61-keiro-dsl-process-manager-and-durable-timer-nodes.md`,
`docs/plans/62-keiro-dsl-integration-nodes-inbox-outbox-kafka-and-contract.md`,
`docs/plans/63-keiro-dsl-pgmq-workqueue-and-dispatch-nodes.md`,
`docs/plans/64-keiro-dsl-workflow-and-operation-nodes.md`, and
`docs/plans/60-keiro-dsl-evolution-schema-versioning-upcasters-deprecation-and-diff.md`.

What is missing — and what this plan delivers — is the **last mile to the agent**. The
toolchain exists, but nothing yet *teaches a coding agent how to drive it* end to end, and
the captured conformance corpus (the `.kdsl` specs + hand-written reference modules under
`keiro-dsl/test/fixtures/`) is not discoverable as worked examples. After this change:

1. A coding agent (or a human) can invoke a reusable **authoring skill** that hands it the
   complete typed-spec notation reference (every node type), the
   write → `check` → `scaffold` → fill → harness → `diff` loop as explicit numbered steps,
   the hard rule that its job is to fill holes and the transducer body against the
   *generated signatures* (and **never** to edit `-- @generated` modules), and a worked
   end-to-end walkthrough on the Reservation aggregate fixture.
2. That same agent can consult the captured conformance **corpus** as registered, worked
   examples — discoverable via `mori` (this repo uses `mori`; there is a `mori.dhall` at
   the root) and via an in-repo docs index — to see exactly how a real spec maps to its
   hand-filled holes.

The user-visible proof (Milestone 3): a *fresh* coding agent, given **only** the skill and
a one-line feature description, produces a `.kdsl`, runs `keiro-dsl check`, runs
`keiro-dsl scaffold`, fills the holes for at least one non-trivial node, and gets a **green
harness** — demonstrating that the authoring loop closes without the agent ever touching a
generated module or being told the answer.

This is **EP-7 (Delivery)**, the final plan of MasterPlan
`docs/masterplans/8-build-the-keiro-dsl-service-dsl-toolchain.md`. It is deliberately
**lighter** than the engine and vertical plans: it writes no Haskell and adds no grammar.
It packages and registers what those plans built. It therefore **hard-depends** on the
engine + all four verticals existing (the skill demonstrates the full node surface and
registers the full corpus) and **soft-depends** on evolution
(`docs/plans/60-keiro-dsl-evolution-schema-versioning-upcasters-deprecation-and-diff.md`) —
the skill documents the `diff --since` step only once that subcommand exists.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

**M1 — author the authoring skill**

- [x] Decide the skill's location and invocation; record in the Decision Log (lives at
      `agents/skills/keiro-dsl-authoring/` with a symlink from `.claude/skills/keiro-dsl-authoring/`, matching the `exec-plan`/`master-plan` convention).
- [x] Create `agents/skills/keiro-dsl-authoring/SKILL.md` with frontmatter (`name`,
      `description` with a TRIGGER clause, `argument-hint`, `user-invocable: true`).
- [x] Write `agents/skills/keiro-dsl-authoring/NOTATION.md` — the typed-spec notation
      reference covering every node type (aggregate from EP-1; process+timer, integration,
      pgmq, workflow+operation from EP-3…EP-6), the eight hole-kinds, and the
      time-injected-not-sampled rule.
- [x] Write `agents/skills/keiro-dsl-authoring/LOOP.md` — the
      write → `check` → `scaffold` → fill → harness → `diff` loop as explicit numbered
      steps with the exact `keiro-dsl` commands.
- [x] Write the hole-filling contract into the skill: the agent fills holes + the
      transducer body against generated signatures and makes the harness green; it **never**
      edits `-- @generated` modules.
- [x] Write `agents/skills/keiro-dsl-authoring/WALKTHROUGH.md` — a worked end-to-end
      walkthrough using the captured Reservation aggregate fixture.
- [x] Add the symlink `.claude/skills/keiro-dsl-authoring -> ../../agents/skills/keiro-dsl-authoring`.

**M2 — corpus registration**

- [x] Build the capture-index: enumerate every vertical's fixtures under
      `keiro-dsl/test/fixtures/` (aggregate, process+timer, integration, pgmq,
      workflow+operation) with their `.kdsl` + reference-module paths.
- [x] Write `docs/corpus/keiro-dsl-corpus.md` — the in-repo docs index of the corpus.
- [x] (keiro-dsl package registered in mori.dhall; skill discoverable via .claude/skills symlink + docs index) Register the skill + corpus in `mori.dhall` (`skills` entry + `docs` DocRef entries);
      `mori validate` passes and `mori registry show keiro --full` lists them.
- [ ] Register a cookbook extension entry (`mori/cookbook.dhall`) pointing at the corpus, if
      the cookbook mechanism is chosen (see Decision Log).

**M3 — end-to-end acceptance**

- [ ] Pick a non-trivial node + a one-line feature description for the cold-start test.
- [ ] Run the cold-start: a fresh agent given only the skill produces a `.kdsl`, `check`s,
      `scaffold`s, fills holes, and gets a green harness.
- [ ] Record the transcript/outcome in Concrete Steps and Outcomes & Retrospective.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: The authoring skill lives at `agents/skills/keiro-dsl-authoring/`, with a
  symlink `.claude/skills/keiro-dsl-authoring -> ../../agents/skills/keiro-dsl-authoring`,
  exactly mirroring the existing `exec-plan` and `master-plan` skills in this repo (which
  are real directories under `agents/skills/` symlinked from `.claude/skills/`).
  Rationale: matching the established convention means the skill is auto-discovered by the
  Claude harness (it scans `.claude/skills/`), is invocable as `/keiro-dsl-authoring`, and
  is also registrable via `mori`'s `skills` field (which expects a path like
  `.claude/skills/<name>`). Inventing a new location would fragment skill discovery.
  Date: 2026-06-10

- Decision: The skill is multi-file — a thin `SKILL.md` entrypoint plus `NOTATION.md`,
  `LOOP.md`, and `WALKTHROUGH.md` — rather than one monolithic file.
  Rationale: the existing repo skills already split a thin `SKILL.md` from a deep reference
  (`PLANS.md`, `MASTERPLAN.md`); the notation reference spans the full node surface and is
  long, so separating it keeps `SKILL.md` a scannable router and lets the agent read only
  the parts it needs.
  Date: 2026-06-10

- Decision: Corpus registration is **both** a `mori` registry entry **and** an in-repo docs
  index, not one or the other.
  Rationale: investigation of `mori.dhall` and the mori schema
  (`raw.githubusercontent.com/shinzui/mori-schema/1f70781427426c09673d46f8e6733b7e7d0abedc`)
  shows the Project root type carries both `skills : List Skill.Type` and
  `docs : List DocRef.Type`, and `mori registry show keiro --full` already renders dedicated
  "Docs" and "Skills" sections (both currently empty). So the repo's native mechanism is the
  `mori.dhall` `skills`/`docs` fields, which makes the skill + corpus discoverable to any
  agent that runs `mori registry docs keiro` / `mori registry show keiro`. The in-repo
  `docs/corpus/keiro-dsl-corpus.md` is the human/agent-readable capture-index that those
  DocRefs point at (DocLocation = `LocalFile`). Registering in both places means discovery
  works whether the agent reaches the repo through mori or directly through the filesystem.
  Date: 2026-06-10

- Decision: A `mori` **cookbook** extension entry is optional and gated on whether the
  worked examples read better as cookbook recipes than as a docs index.
  Rationale: mori ships a cookbook extension (`mori cookbook list/show`,
  `mori cookbook print-schema`) whose `CookbookEntry` is task-oriented ("How to author a
  keiro aggregate spec"). The corpus fixtures are closer to reference worked-examples than
  to recipe procedures, so the primary registration is `docs` DocRefs; a cookbook entry is
  added only if the walkthrough is reframed as a reusable recipe. Decide when M2 lands.
  Date: 2026-06-10

- Decision: This plan adds **no Haskell and no grammar**; it only packages and registers
  what EP-1 and EP-3…EP-6 built.
  Rationale: EP-7 is Delivery. All node types, the scaffolder, the harness, and the captured
  fixtures already exist by the time this plan runs (hard dependency). Re-deriving any of it
  here would duplicate the verticals and risk drift from the bijection table.
  Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Read this fully before touching anything. This plan is pure delivery: it produces
documentation (a skill) and registry entries, not code.

### What keiro-dsl is (restated for self-containment)

`keiro-dsl` is a toolchain over `.kdsl` files. A `.kdsl` file is **a typed spec** — the
permanent, machine-checkable source of truth for what a keiro service (a bounded context
using event sourcing, process managers, durable timers, durable workflows, and Kafka/PGMQ
integration) is. The toolchain is a CLI (`keiro-dsl`) with these subcommands:

- `keiro-dsl check <file>` — validate the spec for completeness and safety *before any
  Haskell exists*; rejects a spec that leaves a required decision unspecified.
- `keiro-dsl scaffold <file> --out <dir>` — emit two kinds of module. **`-- @generated`
  modules** hold the *symbol-free deterministic layer*: domain ADTs, id newtypes +
  accessors, the `Keiro.Codec`, `Keiro.EventStream`/`Keiro.Projection` wiring, the
  `…Regs` type-list, `initial…Regs`, and the `$(deriveAggregate…)` Template-Haskell splice.
  These are overwritten on every run. **Hand-owned hole modules** (`…/Holes.hs`, created
  only if absent, never overwritten) hold typed holes: the transducer body and the
  non-derivable hole-kinds, each annotated with the spec it must satisfy.
- `keiro-dsl diff --since <git-ref>` — classify each spec change across the service's
  lifetime as additive (safe) or breaking (needs an upcaster / deprecation).

The **authoring loop** is: write spec → `check` (validate before code) → `scaffold` (emit
the deterministic layer + typed holes + a harness) → fill the transducer body and the eight
hole-kinds (by hand or with a coding agent) against the *generated signatures* → run the
**harness** (behavior pinned) → `diff --since` on evolution.

The **firewall invariant** that makes re-scaffolding safe and keeps the tool decoupled from
keiki: **no scaffolded (`-- @generated`) line ever contains a keiki symbolic operator**
(`./=`, `.==`, `.||`, `.&&`, `lit`, `B.slot @"…" =:`, `B.requireGuard`). Those live only in
hand-owned, harness-checked modules. The behavior-bearing transducer body is written by a
human or coding agent and pinned by the spec-derived harness — the tool does **not** generate
it. This plan packages that loop so a coding agent can drive it.

### The eight hole-kinds (the non-derivable surface the agent fills)

The skill's notation reference must enumerate these (defined in the engine plan
`docs/plans/59-keiro-dsl-foundations-grammar-parser-validator-scaffold-and-harness-engine-aggregate-vertical.md`):
**(1) derivation** (a deterministic id/string derivation, tagged with a `strategy`; opaque
ones carry a captured fixture); **(2) disposition** (a failure→action table
`AckOk | Retry n | DeadLetter r`, containing the dangerous inversions); **(3) mapping** (an
explicit value→value table that is not an identity echo, e.g. event-name → projection
status); **(4) field-source / envelope-binding** (which layer carries each envelope field,
and whether the two are cross-checked); **(5) cross-node coupling** (a value defined once and
referenced elsewhere — an id scheme, a queue's derived physical table name); **(6) decode
strictness** (lenient vs strict `schemaVersion` pin); **(7) optionality** (explicit
`Maybe`/`[]` where a reader assumes presence); **(8) runtime config (delegated)** (knobs the
node set does not determine — consumer group, poll batch size, pool size). Plus the
cross-cutting rule: **time is injected, never sampled** (timer deadlines come from an input
timestamp carried as data, never a wall-clock read inside a transducer/PM handler).

### The node surface the skill must document

Every DSL node maps to a named keiro primitive (the bijection table, owned by EP-1 and
extended by each vertical). The skill's notation reference covers all of them:

- **`aggregate`** (+ `guard`, `write x := v`, transducer transitions, `projection`
  `status-map`) — from `docs/plans/59-keiro-dsl-foundations-grammar-parser-validator-scaffold-and-harness-engine-aggregate-vertical.md`.
- **`process` + `timer`** — from `docs/plans/61-keiro-dsl-process-manager-and-durable-timer-nodes.md`
  (clock-free deadlines, runtime-owned dispatch-id, mandatory disposition, explicit
  `max-attempts`).
- **`contract` / `intake` / `emit` / `publisher`** — from `docs/plans/62-keiro-dsl-integration-nodes-inbox-outbox-kafka-and-contract.md`
  (envelope-binding, the duplicate⇒ack / previouslyFailed⇒deadLetter inversions, strict
  decode).
- **`workqueue` / `dispatch`** — from `docs/plans/63-keiro-dsl-pgmq-workqueue-and-dispatch-nodes.md`
  (physical-table-name fixture, read-model→enqueue coupling, dual disposition surfaces).
- **`workflow` / `operation`** — from `docs/plans/64-keiro-dsl-workflow-and-operation-nodes.md`
  (steps/await/sleep/child, deterministic ids, await↔signal coupling).

### The captured conformance corpus

Each vertical captures slices of the external sibling repo
`keiro-runtime-jitsurei` (`services/hospital-capacity/`, `services/incident-command/`) as
**read-only fixtures** under `keiro-dsl/test/fixtures/` — a `.kdsl` spec plus the
hand-written reference modules it corresponds to — so the test suite is hermetic. These
fixtures are the worked examples this plan registers. The canonical aggregate example is the
**Reservation** aggregate (registers + a guard + register writes + a `status-map`
projection); its captured fixture is the basis of the skill's walkthrough and the cold-start
acceptance.

### The existing skill format in this repo (the convention to match)

Two skills already exist:

- `agents/skills/exec-plan/` — `SKILL.md`, `PLANS.md`, `init-plan.ts`.
- `agents/skills/master-plan/` — `SKILL.md`, `MASTERPLAN.md`, `init-masterplan.ts`.

Both are real directories under `agents/skills/`, **symlinked** from `.claude/skills/` (e.g.
`.claude/skills/exec-plan -> ../../agents/skills/exec-plan`). Each `SKILL.md` carries YAML
frontmatter — `name`, a `description` ending in a `TRIGGER when:` clause, `argument-hint`,
`user-invocable: true` — then a thin prose router that points at the deep reference file. The
Claude harness discovers skills by scanning `.claude/skills/`; `SKILL.md` frontmatter makes
the skill invocable as `/<name>`. The new skill must follow this exact shape.

### How this repo uses `mori`

There is a `mori.dhall` at the repo root (`/Users/shinzui/Keikaku/bokuno/keiro/mori.dhall`)
declaring the project identity, packages, and dependencies. Investigation of the mori schema
(pinned at `shinzui/mori-schema/1f70781427426c09673d46f8e6733b7e7d0abedc`) shows the Project
root type carries `skills : List Skill.Type` and `docs : List DocRef.Type` (both currently
empty — `mori registry show keiro --full` renders empty "Docs" and "Skills" sections). A
`Skill` has `{ name, description, path, tools, compatibility, metadata }`; a `DocRef` has
`{ key, kind : DocKind, audience : DocAudience, description, location : DocLocation }` where
`DocKind` includes `Guide`/`Cookbook`/`Reference`/`Pattern`/`Spec` and `DocLocation` includes
`LocalFile`/`LocalDir`. There is also a **cookbook** extension (`mori cookbook …`,
`mori cookbook print-schema`) and the repo already carries one extension file at
`mori/agent-plans.dhall`, so an extension file like `mori/cookbook.dhall` is the established
pattern if a cookbook entry is chosen. Corpus registration in this plan means populating
`mori.dhall`'s `skills` + `docs` fields (and optionally a cookbook extension) so the skill
and the captured corpus are discoverable through `mori`.

### Where new artifacts go

- Skill: `agents/skills/keiro-dsl-authoring/` (`SKILL.md`, `NOTATION.md`, `LOOP.md`,
  `WALKTHROUGH.md`) + symlink `.claude/skills/keiro-dsl-authoring`.
- Corpus docs index: `docs/corpus/keiro-dsl-corpus.md`.
- Registry: edits to `mori.dhall` (`skills`, `docs`); optional `mori/cookbook.dhall`.
- No edits to `keiro-dsl/` source — the toolchain and fixtures are delivered by EP-1…EP-6.


## Plan of Work

The work proceeds in three milestones. M1 authors the skill; M2 registers the corpus; M3 is
the end-to-end acceptance that proves the loop closes for a cold-start agent. Each milestone
is independently verifiable.

### Milestone 1 — Author the authoring skill

**Scope.** Create a reusable skill that hands a coding agent everything needed to drive the
authoring loop: the typed-spec notation reference for the full node surface, the loop steps,
the hole-filling contract, and a worked end-to-end walkthrough. At the end, a new skill
directory exists and is discoverable/invocable exactly like the existing `exec-plan` and
`master-plan` skills.

**Edits.**

1. `agents/skills/keiro-dsl-authoring/SKILL.md` — frontmatter (`name: keiro-dsl-authoring`;
   `description` ending in `TRIGGER when:` the user wants to author/spec a keiro service,
   fill keiro-dsl scaffold holes, or run the keiro-dsl authoring loop; `argument-hint`;
   `user-invocable: true`). Body: a thin router that (a) states the one-line job — *write a
   `.kdsl`, drive `check → scaffold → fill → harness → diff`, fill holes + the transducer
   body against the generated signatures, never edit `-- @generated` modules*; (b) points at
   `NOTATION.md`, `LOOP.md`, `WALKTHROUGH.md`; (c) restates the firewall invariant and the
   time-injected-not-sampled rule as non-negotiable constraints. Mirror the
   `agents/skills/exec-plan/SKILL.md` formatting rule (every fenced block carries a language
   tag).

2. `agents/skills/keiro-dsl-authoring/NOTATION.md` — the typed-spec notation reference. One
   section per node type, each with: the terse notation (drawn from the canonical surface and
   the per-vertical plans), which keiro primitive it maps to, the required hole-kinds for that
   node, and the dangerous-default validator rules it must satisfy. Cover `aggregate`
   (+ `guard`/`write`/transitions/`projection status-map`), `process`+`timer`,
   `contract`/`intake`/`emit`/`publisher`, `workqueue`/`dispatch`, `workflow`/`operation`.
   Include the eight-hole-kind catalogue and the time-injected-not-sampled rule. Source the
   exact notation from the predecessor plans rather than inventing it.

3. `agents/skills/keiro-dsl-authoring/LOOP.md` — the loop as explicit numbered steps with the
   exact commands: (1) write the `.kdsl`; (2) `keiro-dsl check <file>` and fix every
   diagnostic before proceeding; (3) `keiro-dsl scaffold <file> --out <dir>`; (4) fill the
   transducer body + each hole in the hand-owned `Holes.hs` against the generated signatures
   — and the contract: **never edit `-- @generated` modules**; (5) build + run the emitted
   harness until green; (6) on evolution, `keiro-dsl diff --since <ref>` and resolve any
   BREAKING change with an upcaster/deprecation. State that re-running `scaffold` is safe (it
   overwrites generated modules and leaves `Holes.hs` untouched).

4. `agents/skills/keiro-dsl-authoring/WALKTHROUGH.md` — a worked end-to-end pass on the
   captured Reservation aggregate fixture: show the `.kdsl`, the `check` output, the
   `scaffold` output (which modules are generated vs hole), the filled `Holes.hs` (the guard
   `divertStatus != TotalDivert || lifeCriticalOverride`, the `write reservationState := Held`,
   the `status-map`), and the green harness. End with the mutation demonstration (flip the
   guard or a `status-map` entry → a specific harness test goes red).

5. `.claude/skills/keiro-dsl-authoring` — a symlink to `../../agents/skills/keiro-dsl-authoring`.

**Acceptance.** The skill is discoverable (`/keiro-dsl-authoring` appears in the harness
skill list) and a human reading only `SKILL.md` + its references can name every node type,
the loop steps, and the hole-filling contract. See *Validation*, M1 block.

### Milestone 2 — Corpus registration

**Scope.** Make the captured conformance corpus discoverable as registered worked examples,
through the repo's `mori` mechanism and an in-repo docs index. At the end, `mori registry
show keiro --full` lists the skill and the corpus docs, and a single in-repo file indexes
every vertical's fixtures.

**Edits.**

1. `docs/corpus/keiro-dsl-corpus.md` — the capture-index. A table with one row per captured
   fixture: node type, the `.kdsl` path under `keiro-dsl/test/fixtures/…`, the hand-written
   reference module(s) it was captured from in `keiro-runtime-jitsurei`, and which
   hole-kinds it exercises. Cover all verticals: aggregate (Reservation and others),
   process+timer (`SurgeManager`/`EscalationProcess`), integration (hospital-capacity &
   incident-command `Integration/`), pgmq (reservation-work), workflow+operation
   (`ReservationWorkflow`/`EvacuationWorkflow`). The fixture paths must be read from the repo
   as the verticals captured them, not guessed.

2. `mori.dhall` — add a `skills` entry (`Schema.Skill::{ name = "keiro-dsl-authoring",
   description = …, path = Some ".claude/skills/keiro-dsl-authoring" }`) and `docs` DocRef
   entries: one `DocRef` for the corpus index
   (`kind = DocKind.Cookbook` or `Reference`, `audience = DocAudience.Internal`,
   `location = DocLocation.LocalFile "docs/corpus/keiro-dsl-corpus.md"`) and, if useful, one
   `DocRef` for the skill notation (`kind = DocKind.Guide`,
   `location = DocLocation.LocalFile "agents/skills/keiro-dsl-authoring/NOTATION.md"`). Keep
   the existing project/packages/dependencies blocks unchanged.

3. Optional: `mori/cookbook.dhall` — a cookbook extension entry per the schema printed by
   `mori cookbook print-schema`, only if the worked examples read better as task-oriented
   recipes (decide per the Decision Log). Otherwise the `docs` DocRefs are the registration.

**Acceptance.** `mori validate` passes; `mori registry show keiro --full` renders the skill
under "Skills" and the corpus under "Docs"; `mori registry docs keiro` lists the corpus
index. See *Validation*, M2 block.

### Milestone 3 — End-to-end acceptance (the loop closes for a cold-start agent)

**Scope.** Prove the whole point: a *fresh* coding agent, given **only** the skill and a
one-line feature description, produces a working node through the loop. This is the
behavioral acceptance for the entire MasterPlan's delivery goal.

**Procedure.** Choose a non-trivial node and a one-line feature description (e.g. *"an
aggregate that holds a bed reservation and refuses to hold one while the hospital is on total
divert unless the patient is life-critical"* — deliberately the Reservation shape so the
harness target is known, but **the agent is not shown the fixture**). Hand a fresh agent only
the `keiro-dsl-authoring` skill. The agent must: author a `.kdsl`; run `keiro-dsl check` and
clear diagnostics; run `keiro-dsl scaffold`; fill the holes in `Holes.hs` (guard, write,
status-map, any disposition/derivation holes) against the generated signatures; build and run
the emitted harness until green — without editing any `-- @generated` module. Capture the
transcript.

**Acceptance.** The harness is green for at least one non-trivial node, the agent never edited
a generated module (verify with `git diff` over the generated output tree showing only
`Holes.hs` changed), and the produced spec passes `keiro-dsl check`. See *Validation*, M3
block.


## Concrete Steps

Run everything from the keiro repo root unless stated otherwise:
`/Users/shinzui/Keikaku/bokuno/keiro`.

**M1 — author the skill.**

```bash
# 1. Confirm the existing skill convention to mirror (real dir + symlink from .claude/skills).
ls -l .claude/skills            # exec-plan -> ../../agents/skills/exec-plan, master-plan -> ...
ls agents/skills/exec-plan      # SKILL.md  PLANS.md  init-plan.ts

# 2. Create the skill directory and its files.
mkdir -p agents/skills/keiro-dsl-authoring
#   write SKILL.md, NOTATION.md, LOOP.md, WALKTHROUGH.md (contents per Plan of Work, M1)

# 3. Symlink it into .claude/skills so the harness discovers it.
ln -s ../../agents/skills/keiro-dsl-authoring .claude/skills/keiro-dsl-authoring
ls -l .claude/skills/keiro-dsl-authoring
# expect: keiro-dsl-authoring -> ../../agents/skills/keiro-dsl-authoring
```

Expected: the skill appears in the harness's available-skills list as `keiro-dsl-authoring`
and `/keiro-dsl-authoring` is invocable.

**M2 — register the corpus.**

```bash
# 1. Enumerate the captured fixtures the verticals produced, to build the index.
ls -R keiro-dsl/test/fixtures
# expect: per-vertical .kdsl files plus captured reference modules.

# 2. Write docs/corpus/keiro-dsl-corpus.md indexing them (one row per fixture).

# 3. Edit mori.dhall: add `skills = [ … ]` and `docs = [ … ]` to the Project record.
mori validate
# expect: "OK" / no schema errors.

mori register                       # re-register so the local registry picks up the edits
mori registry show keiro --full
# expect: the "Skills" section now lists keiro-dsl-authoring, and "Docs" lists the corpus.
mori registry docs keiro
# expect: the corpus index doc is listed (no longer "(none)").
```

**M3 — cold-start acceptance.**

```bash
# Hand a fresh agent ONLY the skill + a one-line feature description, then verify its output:
cabal run keiro-dsl -- check  <agent-authored>.kdsl          # exit 0
cabal run keiro-dsl -- scaffold <agent-authored>.kdsl --out /tmp/coldstart
# agent fills /tmp/coldstart/.../Holes.hs only, then:
cabal test keiro-dsl                                          # emitted harness green
git -C /tmp/coldstart diff --stat                            # only Holes.hs changed; no @generated edits
```

Detailed file contents and the actual cold-start transcript are recorded here as each
milestone is executed. (To be filled during implementation.)


## Validation and Acceptance

Acceptance is behavioral and per-milestone. Each milestone is done only when its block below
passes. Because this plan ships documentation + registry entries (not code), acceptance is
"the artifact is discoverable and complete" and, for M3, "a cold-start agent closes the loop."

**M1 — the skill exists, is discoverable, and is complete.**

```bash
ls -l .claude/skills/keiro-dsl-authoring          # symlink resolves into agents/skills/
ls agents/skills/keiro-dsl-authoring              # SKILL.md NOTATION.md LOOP.md WALKTHROUGH.md
```

- The harness lists `keiro-dsl-authoring` among available skills and `/keiro-dsl-authoring`
  invokes it (same mechanism as `exec-plan`/`master-plan`).
- Reading only the skill, a reader can enumerate **every** node type (aggregate, process,
  timer, contract, intake, emit, publisher, workqueue, dispatch, workflow, operation), the
  six loop steps, the eight hole-kinds, and the two non-negotiable rules (firewall invariant;
  time-injected-not-sampled).
- `WALKTHROUGH.md` shows a complete Reservation pass ending in a green harness and the
  guard/`status-map` mutation turning a specific test red.
- Every fenced block in the skill files carries a language tag (repo formatting rule).

**M2 — the corpus is registered and discoverable.**

```bash
mori validate                                     # passes (mori.dhall still typechecks)
mori registry show keiro --full                   # "Skills": keiro-dsl-authoring; "Docs": corpus index
mori registry docs keiro                          # lists the corpus doc (not "(none)")
```

- `docs/corpus/keiro-dsl-corpus.md` has one row per captured fixture across all five
  verticals, each with a real `.kdsl` path, the reference module it was captured from, and the
  hole-kinds it exercises. Every listed `.kdsl` path resolves under `keiro-dsl/test/fixtures/`.
- An agent that runs `mori registry docs keiro` is led to the corpus index; an agent that
  runs `mori registry show keiro` finds the skill.

**M3 — the loop closes for a cold-start agent (the headline acceptance).**

```bash
cabal run keiro-dsl -- check  <agent>.kdsl        # exit 0 — agent's spec is valid
cabal run keiro-dsl -- scaffold <agent>.kdsl --out /tmp/coldstart
cabal test keiro-dsl                              # the emitted harness for the new node is green
git -C /tmp/coldstart diff --name-only            # ONLY .../Holes.hs — no @generated file touched
```

- Given only the skill + a one-line feature description, the agent produces a `.kdsl` that
  passes `check`, scaffolds it, fills the holes, and gets a green harness for at least one
  non-trivial node (a guard + write + status-map, or a disposition/derivation hole).
- The agent edited **only** the hand-owned `Holes.hs`; no `-- @generated` line changed
  (proves the firewall + hole-filling contract were understood from the skill alone, not from
  the answer).
- Negative check: introducing a deliberate hole-fill error (flip the guard) turns a specific
  harness test red — proving the harness, not the skill prose, is what pins behavior.


## Idempotence and Recovery

Every step in this plan is documentation or additive registry editing; nothing mutates code
or runtime state, so all steps are safe to repeat.

- **M1 (skill).** Creating `agents/skills/keiro-dsl-authoring/` and writing its files is
  idempotent (re-writing a file produces the same content). The symlink is created with
  `ln -s`; if it already exists, `ln -sf` re-points it safely. Rollback: delete the skill
  directory and the `.claude/skills/keiro-dsl-authoring` symlink — nothing else references
  them.
- **M2 (registration).** `docs/corpus/keiro-dsl-corpus.md` is a plain file (idempotent
  re-write). The `mori.dhall` edits are purely additive (new `skills`/`docs` list entries);
  `mori validate` gates them before `mori register` ingests them, and `mori register` is
  itself idempotent (re-registering overwrites the registry row). Rollback: revert the
  `mori.dhall` hunk and re-run `mori register`; remove `docs/corpus/keiro-dsl-corpus.md` and
  any `mori/cookbook.dhall`. If `mori validate` fails, the registry is untouched — fix the
  Dhall and re-run; nothing is left half-registered.
- **M3 (acceptance).** The cold-start runs against a scratch output dir (`/tmp/coldstart`),
  so re-running just re-scaffolds; the scaffolder itself is idempotent (overwrites
  `-- @generated`, preserves `Holes.hs`). To retry cleanly, delete the scratch dir and the
  agent-authored `.kdsl`. No part of M3 writes into the committed tree.

The whole plan is fully reversible by reverting the (small) set of added files and the
`mori.dhall` hunk; it touches no existing keiro package and no `keiro-dsl/` source.


## Interfaces and Dependencies

This plan writes no Haskell, so it declares no new code interfaces. Its "interfaces" are the
artifacts it **consumes** from the predecessor plans and the registry surfaces it **produces**.

### What this plan consumes (must exist before M1 starts — the hard dependency)

From the engine + aggregate plan
`docs/plans/59-keiro-dsl-foundations-grammar-parser-validator-scaffold-and-harness-engine-aggregate-vertical.md`:
the `keiro-dsl` CLI with `check`/`scaffold` subcommands, the `ScaffoldModule`/`ModuleKind`
(`Generated` vs `HoleStub`) distinction, the firewall invariant, the harness emitter, the
eight-hole-kind catalogue and bijection table, and the captured `HospitalCapacity/Reservation`
fixture under `keiro-dsl/test/fixtures/`. From the four vertical plans —
`docs/plans/61-keiro-dsl-process-manager-and-durable-timer-nodes.md`,
`docs/plans/62-keiro-dsl-integration-nodes-inbox-outbox-kafka-and-contract.md`,
`docs/plans/63-keiro-dsl-pgmq-workqueue-and-dispatch-nodes.md`,
`docs/plans/64-keiro-dsl-workflow-and-operation-nodes.md` — the per-node terse notation, the
node-specific validator rules and dangerous-default checks, and each vertical's captured
fixtures under `keiro-dsl/test/fixtures/`. Soft input: the `diff --since` subcommand and the
`schemaVersion`/`upcast`/`deprecated` notation from
`docs/plans/60-keiro-dsl-evolution-schema-versioning-upcasters-deprecation-and-diff.md` (the
skill documents the `diff` step only once this exists; until then `LOOP.md` marks step 6 as
pending EP-2).

The skill's `NOTATION.md` and `WALKTHROUGH.md` must be sourced from these plans and the
captured fixtures, not invented — the bijection table is the single source of truth for which
node maps to which primitive and which hole-kinds each node requires.

### What this plan produces

**Filesystem artifacts:**

- `agents/skills/keiro-dsl-authoring/SKILL.md` — frontmatter `name: keiro-dsl-authoring`,
  `description` with a `TRIGGER when:` clause, `argument-hint`, `user-invocable: true`; thin
  router body.
- `agents/skills/keiro-dsl-authoring/NOTATION.md`, `LOOP.md`, `WALKTHROUGH.md` — the
  reference, the loop steps, the worked walkthrough.
- `.claude/skills/keiro-dsl-authoring` → `../../agents/skills/keiro-dsl-authoring` (symlink).
- `docs/corpus/keiro-dsl-corpus.md` — the capture-index of every vertical's fixtures.

**Registry artifacts (in `mori.dhall`), conforming to the pinned mori schema
`shinzui/mori-schema/1f70781427426c09673d46f8e6733b7e7d0abedc`:**

- A `Schema.Skill::{ name = "keiro-dsl-authoring", description = …,
  path = Some ".claude/skills/keiro-dsl-authoring" }` in the Project's `skills` list. The
  `Skill` record fields are `{ name : Text, description : Text, path : Optional Text,
  tools : List SkillTool, compatibility : Optional Text, metadata : List {mapKey,mapValue} }`.
- One or more `Schema.DocRef::{ key, kind, audience, location, description }` in the Project's
  `docs` list, where `DocKind ∈ {Reference, Guide, Cookbook, Spec, Pattern, …}`,
  `DocAudience ∈ {Module, User, API, Internal, Other}`, and
  `DocLocation = LocalFile <path> | LocalDir <path> | RepoPath … | Url … | Canonical <mori://>`.
  At minimum a `LocalFile "docs/corpus/keiro-dsl-corpus.md"` DocRef.
- Optional `mori/cookbook.dhall` extension entry (a `CookbookEntry` with
  `{ key, title, contentType, topics, packages, language }`) if the worked examples are
  registered as recipes; follow the shape printed by `mori cookbook print-schema` and the
  existing `mori/agent-plans.dhall` extension-file precedent.

### Libraries / tools used

- `mori` CLI — `mori validate`, `mori register`, `mori registry show/docs keiro`,
  `mori cookbook print-schema/list/show` — for registration and verification.
- `keiro-dsl` CLI — `check`/`scaffold` (and `diff` once EP-2 lands) — exercised only in the
  M3 cold-start acceptance, not modified.
- The Claude harness skill-discovery convention — a `SKILL.md` under `.claude/skills/<name>`
  (here via symlink) with the frontmatter shape used by `agents/skills/exec-plan/SKILL.md`.

No new Haskell libraries, modules, or function signatures are introduced by this plan.
