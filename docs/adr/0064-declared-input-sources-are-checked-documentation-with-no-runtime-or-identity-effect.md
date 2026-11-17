---
type: Architecture Decision Record
title: Declared input sources are checked documentation with no runtime or identity effect
description: A candidate Language 6 input may name the intake and events that feed it; check verifies the link and the topology exports it as a feeds edge, but it never reaches generated code, fingerprints, ledgers or diff verdicts.
timestamp: 2026-11-17T17:00:00Z
docId: ADR-64
status: Accepted
date: 2026-11-17
originatingPlan: docs/plans/341-declare-and-check-the-intake-that-feeds-a-process-or-router-input-and-export-it-as-a-topology-edge.md
---

# Declared input sources are checked documentation with no runtime or identity effect

## Context

A process or router declares a typed `input`, but the conversion from an intake's accepted
inbox message into that input is hand-written Haskell. Readers of a specification, and
`check`, therefore could not see or verify which intake feeds which component. Mori asked
for the link in `docs/improvement-requests/declare-which-intake-feeds-a-process-or-router-input.md`
(IR-63) and required that declaring it not change runtime behavior.

## Decision

Candidate Language 6 accepts `from intake <Intake> event <Event>+` between an input's name
and its body, on router inputs, legacy process inputs and reaction-process inputs. It is
registered as the `InputSourceSyntax` feature of the candidate syntax profile, as
[ADR-16](0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md) requires.
Languages 1 to 5 refuse it, and `from`, `intake` and `event` are contextual words, not
reserved words. The author names the events because the checker cannot infer them from
hand-written code. `check` reports `InputSourceUnresolvedIntake` and
`InputSourceEventNotAccepted`.

A declared source is checked documentation. It takes no part in generated code, fold
fingerprints, process-reaction or router-selection fingerprints, the scaffold ledger, or
`diff` compatibility and replay verdicts. A test scaffolds a sourced and an unsourced
specification and requires byte-identical output and equal identities. The topology exports
each source as a `feeds` edge under schema id `/2` (ADR-62).

## Consequences

- An existing service can adopt, change or remove a source with no drain, migration or
  version bump.
- Identity and comparison code must keep encoding `InputDecl` field by field. A generic
  encoding of the whole value would let `source` leak into an identity, and the
  non-interference test would fail.
- Moving the hand-written inbox-to-input conversion into generated code would be a separate
  decision. It would give the clause runtime meaning and would need its own compatibility
  rules.
- Only intakes can be declared as sources. Other input origins would need a new form.
