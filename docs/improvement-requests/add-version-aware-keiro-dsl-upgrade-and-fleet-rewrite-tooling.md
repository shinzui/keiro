---
type: Improvement Request
title: Add version-aware keiro-dsl upgrade and fleet rewrite tooling
description: >-
  Upgrade declared Keiro DSL source versions through checked sequential rewrites with dry-run,
  workspace atomicity, and fleet-wide reporting instead of blind syntax replacement.
timestamp: 2026-09-16T04:45:00Z
requestId: IR-5
status: proposed
origin: mori://shinzui/keiro
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-07-31T15:03:53Z
    document_timestamp: 2026-07-31T15:03:53Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      In-repository capability audit of parser, workspace, pretty-print, diff, scaffold-record,
      and registered dependent-project behavior. Plan 160 supplies the prerequisite declared and
      effective source-language version contract; this request deliberately defers rewriting.
  - kind: model
    reviewer: claude-code
    reviewed_at: 2026-09-16T04:45:00Z
    document_timestamp: 2026-09-16T04:45:00Z
    scope: technical-accuracy
    outcome: approved
    provider: anthropic
    model: claude-opus-5
    effort: high
    context: >-
      Bundle refresh at Keiro `708aa215`; the document was corrected in this pass. The Status
      section claimed the `keiro-dsl` CLI "still offers only `pretty`, `check`, `scaffold`, and
      `diff`", which `keiro-dsl/app/Main.hs` contradicts: it also offers `parse`, `inspect`,
      `behavior-obligations`, and `new`. The enumeration was corrected, and the two
      reviewed-migration switches `scaffold --apply-name-migrations` and `scaffold
      --apply-generated-haskell-edition` were named explicitly so the request states why
      generated-Haskell migration does not overlap `.keiro` source rewriting. The substance is
      unchanged and still stands: no command rewrites a specification source or upgrades a
      fleet, and no plan implements the request.
---

# Improvement Request: Add Version-Aware `keiro-dsl upgrade` and Fleet Rewrite Tooling

## Status

Proposed for later work. The prerequisite
[Plan 160](../plans/160-add-an-explicit-keiro-dsl-language-version-contract.md) is complete, and
Languages 1 through 5 now exist, so the request is unblocked. No plan implements it. The
`keiro-dsl` CLI offers `parse`, `pretty`, `check`, `inspect`, `behavior-obligations`, `scaffold`,
`diff`, and `new`; not one of them rewrites a `.keiro` source or upgrades a fleet. The two
reviewed-migration switches that exist — `scaffold --apply-name-migrations` and
`scaffold --apply-generated-haskell-edition` — move and rewrite *generated Haskell* and its
sidecars, never the specification source, so they neither satisfy nor overlap this request.
MasterPlans 29 and 34 and Plan 176 explicitly left source rewriting and fleet upgrade automation
to this request. No
registered fleet is treated as production, so dependent sources may later be rewritten in place
after review.

## Context

Once a source declares `language keiro-dsl N`, Keiro needs a supported way to reach a later
language version. Merely changing the number is unsafe: syntax, defaults, name resolution, lowering,
and compatibility classifications may all change together. Workspaces add an atomicity problem
because rewriting only some members can leave a service unparsable.

## Requested Change

Add `keiro-dsl upgrade` with sequential, version-specific `N -> N+1` transforms. It must support
single files and workspaces, `--check`, `--dry-run`, structured reports, staged atomic writes,
backups or recoverable patches, and post-rewrite parse/check/pretty/diff validation. Unknown or
lossy changes must become explicit manual obligations rather than guessed rewrites.

Add a fleet mode that consumes Mori-discovered Keiro dependents, reports declared/effective
versions and blockers, and emits per-repository rewrite plans. Cross-repository writes remain an
explicit operator action.

## Acceptance

1. A v1 fixture upgrades through every registered step to the requested target and passes the
   target parser/checker; repeated upgrade is a no-op.
2. Dry-run reports exact files, semantic changes, manual obligations, and compatibility diffs
   without writes.
3. Workspace upgrade is all-or-nothing and recovers from a failed member validation.
4. Golden tests pin every version transform and prove a transform never only bumps the preamble.
5. Fleet inspection uses canonical Mori project identities and does not assume every dependent is
   deployed or production.

## Requested Deliverables

- Version-transform registry and `keiro-dsl upgrade` CLI.
- Atomic file/workspace rewrite and structured reporting.
- Mori-aware fleet inventory/planning mode.
- Upgrade authoring guide, fixtures, recovery tests, and changelog.
