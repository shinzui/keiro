---
type: Improvement Request
title: Keep consumer ID bindings package-internal
description: >-
  Document and check that the module holding a consumer-bound ID's total binding is not part
  of the consumer package's public interface, and state the in-memory precondition behind the
  exact TypeID image claim.
timestamp: 2026-11-25T13:24:37Z
generated:
  by: codex-cli/gpt-6.2-sol
  at: 2026-11-25T13:12:14Z
requestId: IR-66
status: proposed
origin: mori://shinzui/danwa
acceptanceCriteria:
  - id: AC-1
    statement: The nominal binding contract and the consumer-bound ID guidance state that binding values and the ID constructor belong in a package-internal module.
    verification: Read the Keiro.Codec.Nominal module documentation and the consumer-bound ID guide and confirm both name the visibility rule and the reason for it.
  - id: AC-2
    statement: The scaffolder reports a consumer-bound ID whose binding module is part of the consuming package's public interface.
    verification: Scaffold one fixture whose binding module is listed under exposed-modules and one whose binding module is under other-modules; the first produces the diagnostic and the second does not.
  - id: AC-3
    statement: The exactness claim for enforced TypeID equality projections states its in-memory precondition.
    verification: Read the NominalEqualityDomain documentation and confirm it says the exact image holds only when every value of the consumer type was admitted by the declared domain.
  - id: AC-4
    statement: The change leaves the binding representation, encoded text, and fold fingerprints of existing consumers unchanged.
    verification: Regenerate a v7-only and a v5-or-v7 consumer fixture and confirm the generated codecs and fingerprints are identical before and after.
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-11-25T13:12:14Z
    document_timestamp: 2026-11-25T13:12:14Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-6.2-sol
    effort: unspecified
    context: >-
      Author review based on Keiro's nominal binding and ID-domain parser, Danwa's generated
      codecs, and the verified Danwa package boundary.
  - kind: model
    reviewer: claude
    reviewed_at: 2026-11-25T13:24:37Z
    document_timestamp: 2026-11-25T13:24:37Z
    scope: technical-accuracy
    outcome: commented
    provider: anthropic
    model: claude-fable-5-2
    effort: unspecified
    context: >-
      Rescoping review. Compared the Danwa change with the consumer-bound ID layouts in
      mori://shinzui/kotei and the generated ID modules in mori://shinzui/kawa, and read
      Keiro.Codec.Nominal, Keiro.Codec.IdDomain, and Keiro.Dsl.NominalType. The projection
      exactness concern is read from source and has not been exercised by a test.
---

# Keep consumer ID bindings package-internal

## Problem and evidence

A consumer-bound ID converts to and from `KindID prefix` through a total `NominalBinding`. `KindID` accepts any UUID version, so it is wider than the declared `typeid-v7` or `typeid-v5-or-v7` admission domain. The generated decoder validates text before it calls the binding, so decoded values are always admitted. Code that can import the binding, or the ID's constructor, can build a value the checked parser would reject.

Whether that is reachable from outside the consumer package depends on where the consumer puts the binding. Kotei keeps its constructors and bindings in modules listed under `other-modules`, so only its own package can call them. Danwa placed its seven bindings in its public ID module and also derived `Generic` on the ID types, which made unchecked construction available to every Haskell client. Danwa has since moved the bindings to an internal module. [Kotei core](mori://shinzui/kotei/packages/kotei-core) · [Danwa ExecPlan](mori://shinzui/danwa/plans/32-seal-danwa-typeid-construction)

Keiro does not state this rule. The `Keiro.Codec.Nominal` documentation describes totality and says nothing about visibility. The scaffolder already knows each binding module, since it lists them under `consumer-modules` in the Cabal fragment, and it already rejects a type and its binding sharing one module. A consumer can resolve that rejection with a type-only re-export and leave the binding public, which is what Danwa first did.

One Keiro claim also depends on this boundary. `Keiro.Dsl.NominalType` says a consumer-bound ID "has the exact TypeID text image" because it is backed by `KindID prefix`. The generated equality projection renders whatever the binding returns, so for a v7-only domain the claim holds only when no out-of-domain value exists in memory. This reading comes from the source and has not been confirmed by a test.

## Requested change

State the visibility rule where consumers will read it: the `Keiro.Codec.Nominal` module documentation and the guidance for consumer-bound IDs. Binding values and the ID constructor belong in a package-internal module, and the ID type should stay abstract through its derived instances.

Have the scaffolder report a binding module that is part of the consuming package's public interface. Emitting binding modules under `other-modules` in the Cabal fragment, or a diagnostic when the consuming stanza exposes one, would both satisfy this.

Correct the exactness documentation on `NominalEqualityDomain` to name the precondition. If a test shows that an out-of-domain value changes projection behavior, record that as a separate finding.

Leave the binding representation as it is. An opaque checked representation indexed by prefix and admission policy would remove the dependence on consumer discipline, at the cost of a new binding type, a new construction API for seeded UUIDv5 IDs, and fingerprint changes for every existing consumer. Reconsider it if a second consumer exposes its bindings after this change, or if the projection finding proves material.

The earlier work defined the versioned text domain and decoder behavior. This request covers the consumer package boundary that the in-memory representation relies on. [ID domain enforcement](mori://shinzui/keiro/okf/improvement-requests/concepts/IR-14) · [Legacy ID admission](mori://shinzui/keiro/okf/improvement-requests/concepts/IR-46)
