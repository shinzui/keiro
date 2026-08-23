---
type: Architecture Decision Record
title: keiro-dsl records use concise labels without product selectors
description: Package-authored keiro-dsl records use concise repeated labels under NoFieldSelectors; callers read through record dot or patterns while external identities remain explicit.
timestamp: 2026-08-23T19:10:03Z
docId: ADR-38
status: Accepted
date: 2026-08-23
originatingPlan: docs/plans/177-modernize-keiro-dsl-records-and-field-access.md
---

# 38. keiro-dsl records use concise labels without product selectors

Date: 2026-08-23

Status: Accepted


## Context

The original `keiro-dsl` semantic graph used owner-prefixed field names such as
`aggName`, `rmName`, and `wfKey`. `DuplicateRecordFields` later made those prefixes
unnecessary for construction and matching, but the package continued exporting an
ordinary selector function for every product field. That broad API made field names
part of the PVP surface accidentally, encouraged point-free selector composition, and
made records landed under `NoFieldSelectors` coexist with a different historical
convention.

The repository-wide record guidance at
`mori://shinzui/haskell-jitsurei/docs/core-record-patterns` prefers concise semantic
labels and warns against importing generic-lens's orphan `IsLabel` instance into
Keiki-facing closures. Keiro also has external identities—DSL spellings, JSON keys,
wire keys, SQL names, rendered reports, and fingerprints—that must not be derived
accidentally from a Haskell cleanup.


## Decision

Every component importing `keiro-dsl/keiro-dsl.cabal`'s `shared` stanza compiles with
`DuplicateRecordFields`, `NoFieldSelectors`, and `OverloadedRecordDot`. Product records
use concise labels such as `name`, `source`, `span`, and `value`, even when several
types repeat the label. Record constructors remain exported where their types were
already public, so callers can continue constructor-directed construction and pattern
matching. Product selector functions and temporary compatibility aliases are not part
of the new API.

Ordinary reads use record dot. Destructuring uses constructor patterns, and
transformations use explicit reconstruction or small typed helpers. The package does
not enable `OverloadedRecordUpdate`; adoption of record update would be a separate
decision. It also does not add `lens`, `generic-lens`, or `Data.Generics.Labels` merely
to shorten reconstruction. A future exception must be isolated from Keiki-facing
imports and justified against current dependency source and releases.

A deliberately public single-field newtype unwrapper remains an ordinary explicitly
signed function. It is implemented with a positional constructor match rather than a
record label, for example `unLoc (Loc value) = value`. This preserves a small nominal
conversion API without restoring product selectors.

Existing field order, strictness, constructors, and deriving behavior are preserved by
the migration. JSON and text instances, canonical encodings, renderers, wire keys,
fingerprints, ledger schemas, and runtime identities continue to name their external
fields explicitly and do not derive them from the concise Haskell label. The generated
Haskell analogue is governed separately by ADR 0019's `idiomatic-v2` edition and ADR
0015's explicit adoption path.

The checked package migration manifest and generated-edition manifest are omission
detectors, not one-time prose. Extension policy rejects `FieldSelectors` escape hatches
and redundant local record-default pragmas. Fourmolu receives the same record trio as
parser options so formatting cannot reinterpret record-dot syntax as composition.

Because existing callers lose selector functions and many field labels change, this is
a PVP-major Haskell source change. It is not a `.keiro` language, data, wire-format, or
runtime migration.


## Consequences

- Public record construction and matching stay available, but direct selector calls
  must migrate to record dot or a constructor pattern.
- Repeated concise labels no longer expand the package's top-level function namespace.
- Explicit newtype unwrappers remain stable and distinguish nominal conversion from
  accidental product-field access.
- External serialized and runtime identities remain reviewable at their owning
  boundary instead of following Haskell field names implicitly.
- The compiler, inventory generator, extension-policy check, and formatter all enforce
  the same record model.
- Downstream packages must recompile for the next breaking `keiro-dsl` release; projects
  that only run the CLI are affected only when they adopt generated `idiomatic-v2`.


## Related decisions

- [ADR 0015](0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
  defines backup-backed generated-source adoption and hand-owned Hole boundaries.
- [ADR 0019](0019-generated-haskell-has-an-explicit-edition-and-local-extension-contract.md)
  defines the corresponding `idiomatic-v2` generated record model.
- [ADR 0021](0021-direct-fields-have-independent-dsl-selector-and-wire-identities.md)
  separates DSL, Haskell selector, and wire identities.
