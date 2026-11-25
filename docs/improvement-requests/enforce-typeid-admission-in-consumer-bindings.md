---
type: Improvement Request
title: Enforce TypeID admission in consumer bindings
description: >-
  Give generated consumer-bound IDs an opaque representation that enforces the declared prefix
  and UUID admission policy throughout construction and decoding.
timestamp: 2026-11-25T13:12:14Z
generated:
  by: codex-cli/gpt-6.2-sol
  at: 2026-11-25T13:12:14Z
requestId: IR-66
status: proposed
origin: mori://shinzui/danwa
acceptanceCriteria:
  - id: AC-1
    statement: A generated consumer binding receives a checked ID representation indexed by the declared prefix and admission policy.
    verification: Compile fixtures for the v7-only and v5-or-v7 policies and verify that the public interfaces preserve the abstraction and distinguish both prefix and policy.
  - id: AC-2
    statement: Public construction and generated decoders enforce the same admitted set.
    verification: Exercise valid ID generation and round trips, and assert consistent rejection of out-of-domain text across the checked API and generated codec.
  - id: AC-3
    statement: Adopting checked bindings preserves the canonical encoded text and the supported historical replay behavior for each declared policy.
    verification: Decode and replay existing v7-only and v5-or-v7 event fixtures through the candidate; document any Haskell API or generated fingerprint changes in the upgrade guide.
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
---

# Enforce TypeID admission in consumer bindings

## Problem and evidence

The generated Keiro decoder applies the declared TypeID policy to text. Consumer-bound ID conversions are total over plain `KindID`, whose type does not guarantee the same admitted set. The codec checks its own input before conversion, while a consumer type can still receive an ID through another in-process API. Danwa confirmed this mismatch locally for a UUIDv7-only declaration and closed its public construction gap by making the bindings package-internal and keeping its ID types abstract. That hardening depends on each consumer maintaining the same boundary. [Danwa ExecPlan](mori://shinzui/danwa/plans/32-seal-danwa-typeid-construction)

## Requested change

Generate the binding against an opaque checked representation. Its construction API should enforce the prefix, canonical text, UUID variant, and the declared UUID admission policy. A total binding can then assume that its input has already passed the same check as text admitted by the generated decoder. Provide an adoption path for existing consumer-owned ID types. Verify both the v7-only domain and the v5-or-v7 domain used for legacy identities.

The earlier work defined the versioned text domain and decoder behavior. This request extends that policy to the in-memory representation at the consumer binding boundary. [ID domain enforcement](mori://shinzui/keiro/okf/improvement-requests/concepts/IR-14) · [Legacy ID admission](mori://shinzui/keiro/okf/improvement-requests/concepts/IR-46)
