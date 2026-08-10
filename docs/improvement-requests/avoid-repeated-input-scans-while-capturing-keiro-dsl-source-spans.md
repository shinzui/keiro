---
type: Improvement Request
title: Avoid repeated input scans while capturing Keiro DSL source spans
description: >-
  Keep exact source ownership without repeatedly traversing the remaining DSL input for every
  located production, so large specifications and workspaces retain predictable parse-time cost.
timestamp: 2026-08-10T14:50:32Z
requestId: IR-15
status: completed
origin: mori://shinzui/keiro
plan: docs/plans/229-eliminate-repeated-suffix-scans-from-keiro-dsl-source-span-capture.md
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-08-01T23:05:03Z
    document_timestamp: 2026-08-01T23:05:03Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      In-repository review of the source-aware frontend after MasterPlan 28, including the stable
      parser facade, workspace loading path, located productions, compatibility suite, and fixture
      sizes. The concern is parse-time tooling scalability, not generated application runtime.
---

# Improvement Request: Avoid Repeated Input Scans While Capturing Keiro DSL Source Spans

## Status

Completed by Plan 229. The parser benchmark now exercises eight-aggregate sources whose nested
transitions double from 32 through 256, plus the same service split across one through eight
workspace members. Source-span capture uses Megaparsec's consumed chunk instead of measuring two
complete remaining-input suffixes per located production. On the recorded Apple arm64 run, the
largest surface and compatibility parser cases improved by 6.1% and 9.5%, respectively; workspace
wall time remained within measurement uncertainty because it also includes source indexing and
semantic composition.

Exact Unicode, tab, newline, trivia, string-literal, and nested-expression spans remain unchanged.
All public parser projections agree, frozen compatibility fixtures are unchanged, and the complete
DSL, package conformance, build, ADR, formatting, and flake gates pass. The improvement affects
parse-time tooling only, not generated service execution.

## Context

The source-aware frontend introduced by
[MasterPlan 28](../masterplans/28-build-a-modular-source-aware-keiro-dsl-language-frontend.md)
captures exact half-open spans for top-level items, fields, expressions, feature markers, and the
language preamble. The stable `parseSource`, `parseSpec`, and `parseSpecText` facade also traverses
this frontend before lowering, so ordinary parsing pays the span-capture cost even when callers do
not retain the surface tree.

`withOwnedSpan` currently determines consumed input by taking `Text.length` of the complete input
suffix before and after each located production. Nested and repeated productions can therefore
traverse large unconsumed suffixes many times. The compatibility fixtures establish correctness
for small sources but do not characterize scaling for large specifications or multi-member
workspaces.

This is not evidence of a current user-visible regression and should not block adoption by itself.
It is an avoidable scaling risk in development, CI, code-generation, and source-aware tooling.

## Requested Change

Measure parse-time behavior with realistically large generated specifications and workspaces. If
the repeated suffix traversal is material, derive consumed length from Megaparsec's start and end
offsets, or use another approach that does not traverse the full remaining input for every located
node. Continue scanning only the consumed construct where syntax-ownership rules require trimming
trailing trivia.

Preserve the existing surface representation, half-open span semantics, lowering result, stable
failure codes, and compatibility-rendered diagnostics.

## Acceptance

1. A reproducible large-source and large-workspace benchmark characterizes parsing before and
   after the change, including inputs with many nested fields and expressions.
2. Span capture does not traverse the complete unconsumed input suffix for every located
   production.
3. Existing Unicode, tabs, mixed newline, leading-trivia, trailing-comment, empty-body, and
   nested-expression span cases retain their exact offsets and line/column positions.
4. `parseSource`, `parseSpec`, `parseSpecText`, `parseSurfaceSource`, and `lowerSurfaceSource`
   retain their existing successful results and structured failures.
5. The frozen compatibility manifest retains byte-for-byte diagnostics, and the complete DSL and
   workspace suites pass.

## Requested Deliverables

- A representative parse-scaling benchmark or regression harness.
- Span-capture implementation that avoids repeated whole-suffix traversal when measurements
  justify the change.
- Exact-span and compatibility regressions covering ordinary and advanced frontend entry points.
- A short performance note documenting the measured impact and parse-time-only scope.
