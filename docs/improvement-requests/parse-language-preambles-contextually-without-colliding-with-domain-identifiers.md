---
type: Improvement Request
title: Parse language preambles contextually without colliding with domain identifiers
description: >-
  Recognize a Keiro language-version preamble only in its grammar position so legal nested fields,
  strings, and identifiers cannot be mistaken for file-level feature declarations.
timestamp: 2026-08-01T16:29:14Z
requestId: IR-11
status: completed
origin: mori://shinzui/mori
plan: docs/plans/167-parse-keiro-language-preambles-and-feature-gates-from-grammar-context.md
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-07-31T23:44:22Z
    document_timestamp: 2026-07-31T23:44:22Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Reproduced with Mori's released-version workspace and traced to Keiro.Dsl.Parser's
      file-wide significant-line scans for preambles and version-gated body features.
---

# Improvement Request: Parse Language Preambles Contextually Without Colliding With Domain Identifiers

## Status

**Implemented.** [Plan 167](../plans/167-parse-keiro-language-preambles-and-feature-gates-from-grammar-context.md)
under [MasterPlan 27](../masterplans/27-repair-the-keiro-dsl-0-6-language-nominal-generation-and-workspace-regressions.md)
now selects a preamble only from its grammar position before `context` and emits the existing
structured feature diagnostics from their owning productions. The version-1 and version-2
collision fixtures check and scaffold successfully, duplicate and misplaced real preambles retain
their exact lines, and the complete 427-example DSL suite passes.

## Context

Keiro 0.6 selects a source language by scanning every significant source line and treating a line
whose first whitespace-delimited word is `language` as a file-level preamble. This makes ordinary
nested domain syntax context-sensitive in the wrong layer. Mori has a mapped structural field:

```keiro
language as "language" : Text required
```

The valid Keiro 0.5 specification fails under 0.6 with `MisplacedLanguagePreamble`. Adding a real
`language keiro-dsl 2` preamble makes the field look like a duplicate preamble, so authors cannot
upgrade without renaming their DSL selector. The same implementation also detects version-gated
body features through raw line and substring scans. Legal identifiers, quoted strings, and future
syntax can therefore collide with `using`, `Integer`, `implementation hole`, `reg.`, or `cmd.`.

This violates the frozen version-1 compatibility contract and couples language evolution to
accidental lexical spellings in domain models.

## Requested Change

Parse the optional language preamble only at the beginning of the document, after permitted
leading trivia and before declarations. Detect misplaced or duplicate preambles through parser
context rather than a file-wide first-word scan. Determine version-gated syntax from parsed tokens
or the AST, with source spans, rather than searching raw text.

Language keywords should be contextual wherever the grammar permits domain identifiers. A field
or quoted wire key named `language` must not be interpreted as a preamble.

## Acceptance

1. Mori's unchanged version-1 mapped field `language as "language" : Text required` checks and
   scaffolds under the current Keiro release.
2. The same field remains valid in a document with one leading `language keiro-dsl 2` preamble.
3. A second real preamble and a real preamble after declarations receive precise source-located
   diagnostics.
4. Comments, strings, wire keys, and nested identifiers containing all version-feature keywords
   cannot select a language or trigger a feature gate.
5. Existing version-1 and version-2 positive and negative fixtures retain their intended results.
6. Regression fixtures exercise mapped fields, direct fields, declarations, comments, and strings
   whose first token or contents resemble language syntax.

## Requested Deliverables

- Grammar-aware preamble selection and body-feature validation.
- A Keiro 0.6 patch release restoring version-1 source compatibility.
- Parser unit, golden-diagnostic, and end-to-end check/scaffold regressions.
- Documentation that identifies the sole legal preamble position.
