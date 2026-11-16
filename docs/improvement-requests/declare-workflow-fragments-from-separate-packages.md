---
type: Improvement Request
title: Declare workflow fragments from separate packages
description: >-
  A workflow body is declared in one member of one workspace, so the steps a separately built
  package journals inside that workflow are invisible to keiro-dsl check, diff and replay-impact.
  Let a package declare a fragment of a host workflow's body, and classify a change to it like any
  other body change.
timestamp: 2026-11-16T04:40:00Z
requestId: IR-61
status: proposed
origin: mori://shinzui/shikigami
acceptanceCriteria:
  - id: AC-1
    statement: A package outside the workspace that owns a workflow can declare the step and child labels its code journals inside that workflow's body, without editing the owning workspace's members, and the host workflow declares where such fragments may run.
    verification: A fixture with a host workspace and a fragment declared in a second directory; keiro-dsl check passes over the composition and fails when a fragment declares a label the host body or another fragment already declares.
  - id: AC-2
    statement: keiro-dsl diff classifies an added, removed, reordered or retyped label of a fragment with the same findings it gives the same change in a host body, and names the fragment that owns it.
    verification: Diff tests that rename and remove one fragment step and assert the breaking finding, the owning fragment in the diagnostic, and an unchanged verdict for the host and the other fragments.
  - id: AC-3
    statement: A fragment's durable labels can be listed by running its body without PostgreSQL, through a recording interpreter of the Workflow effect or exported effect constructors, so a package can assert that its code journals exactly what it declares.
    verification: A unit test that runs a body with two steps and one await over the recording interpreter and asserts the three labels in order, with no store.
reviews:
  - kind: model
    reviewer: claude-code
    reviewed_at: 2026-11-16T04:40:00Z
    document_timestamp: 2026-11-16T04:40:00Z
    scope: technical-accuracy
    outcome: approved
    provider: anthropic
    model: claude-fable-5-2
    effort: unspecified
    context: >-
      The authoring model's own verification, not an independent review. It read the export list
      of keiro/src/Keiro/Workflow.hs at tag keiro-0.22.0.0 (the Workflow effect is exported
      without constructors and the only runners are runWorkflow and runWorkflowWith, which need
      Store), and Shikigami's domain/shikigami/agent-run.keiro and justfile keiro-diff recipe at
      Shikigami commit 6989b827. It did not read the keiro-dsl composition or diff source.
---

# Improvement Request: Declare Workflow Fragments from Separate Packages

## Status

Proposed. It does not block its origin: Shikigami carries a per-package golden label inventory
until keiro can see these labels.

## Context and evidence

Shikigami runs every agent as one durable workflow, `shikigami.agent-run`, whose body is
declared in `domain/shikigami/agent-run.keiro` (candidate Language 6, keiro-dsl 0.22.0.0). The
body lists every step label any flow may journal, for example `step watchdog-open` and
`step recall-playbook-learnings`, because a flow is a Haskell function that runs inside that
workflow and calls `step` with its own labels.

`mori://shinzui/shikigami/plans/130-move-the-extension-boundary-out-of-shikigami-core-with-flow-packs-and-an-architecture-fitness-check`
moves flows out of the core library into *flow packs*: separate Cabal packages, in the same
repository or another one, that an executable composes at start. A pack's flow still runs inside
`shikigami.agent-run` and still journals steps, but its labels can no longer be declared in the
core member:

* Declaring them there makes every pack an edit to the core repository, which is what the pack
  boundary exists to prevent, and is impossible for a pack in another repository.
* Not declaring them leaves them outside the specification. The first pack,
  `flow-pack-examples`, journals `examples-classify` and seven capability labels built from its
  keys. `keiro-dsl check`, `diff` and the replay-impact report do not see any of them, so renaming
  one is a breaking durable change that the gate reports as no change.

The second gap appeared while building the interim check. A package cannot list the labels its
body journals without a database: `Keiro.Workflow` exports the `Workflow` effect without its
constructors, and `runWorkflow` and `runWorkflowWith` both require `Store`. The pack's test
therefore starts PostgreSQL, runs each branch under `runWorkflowWith`, and reads the step index
back.

## Current consumer bridge

Each pack prefixes every label with its checked pack name and ships a sorted golden file of the
labels its flows journal, with a test that derives the list from a real journal and compares.
ADR 0129 of `mori://shinzui/shikigami`, at
`docs/adr/0129-the-kernel-owns-primitives-and-use-cases-ship-as-declarations-or-packs.md` (its
artifact-level URI is pending), records the rule. The bridge catches a changed label in review. It does not classify the change, it does not cover result types or ordering, and nothing
checks one pack's labels against another's beyond the name prefix.

## Requested change

Let a workflow body be assembled from a host declaration and separately declared fragments.

1. A host workflow declares an extension point in its body: a named place where fragments run,
   with whatever the host must fix about them (for example that a fragment's labels carry the
   fragment's name as a prefix).
2. A fragment is declared outside the host's workspace member, in its own package. It names the
   host workflow and extension point and lists its steps, awaits, children and `patch` gates in
   the existing body grammar.
3. `check` validates a host together with a chosen set of fragments and refuses a label collision
   between fragments or with the host.
4. `diff` treats a fragment as part of the body it extends: a changed fragment label is the same
   finding as a changed host label, attributed to the fragment. A fragment that is absent from a
   composition is not a removal from the host.
5. A recording interpreter of the `Workflow` effect, or its constructors behind an internal
   module, so a package can assert in a unit test that its body journals what its fragment
   declares.

How fragments are located (a path list, a second workspace, a manifest field) is the owner's
decision. The consumer needs only that a fragment's source lives in the package that owns the
code, and that the gate can be run over the host plus the fragments one executable composes.

## Acceptance

The three criteria in the front matter. A Shikigami pack would then replace its golden label
file with a fragment declaration and keep one unit test over the recording interpreter.
