# Complete the domain scalar, identity, and decoder audit

Audit and implement the necessary fixes in the current target repository. Carry
the work through classification, remediation, and acceptance; an inventory or
proposed plan alone is not completion. Follow repository instructions and the
user's scope. Preserve unrelated changes and use the current branch unless asked
otherwise. Do not upgrade dependencies as a prerequisite to this audit.

This reusable procedure derives from
mori://shinzui/shikigami/plans/108-complete-the-remaining-domain-scalar-identity-and-decoder-audit.
Its completed result and final scope discipline are the precedent; its historical
counts, pending checkpoints, package names, tool paths, and platform are not
requirements for this project. The governing domain guide is
mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids.
Resolve sources with Mori and read their actual content. Use `mori registry list`,
`mori registry search`, `mori registry show <project> --full`,
`mori registry docs <project>`, and `mori path <uri>` as appropriate. If artifact
resolution lags, resolve the owning project, locate its documented relative path,
and record both together; retain canonical Mori URIs in cross-repository references.
Do not search the filesystem root or traverse `/nix/store` for source material.

## Establish the target and authorities

Read local instructions, architecture decisions, package/build definitions,
existing audit evidence, workflow versioning policy, and test entrypoints. Discover
the actual production modules and executable/role entrypoints. Include internal
declarations, aliases, positional fields and newtype payloads; exported records
alone are insufficient. Identify generated sources and their authoritative input.
Record any scope limits explicitly. Never infer exhaustive coverage from grep.

Reuse the target's frozen guide revision/hash when one exists. Otherwise record
the guide URI, revision, project-relative path, and SHA-256 used for this audit.
Do not silently refresh the standard or copy another project's release closure.
Trace producers, consumers, lifetimes, authorities, and boundaries in source before
classifying a value. Use Mori to inspect dependency implementations instead of
guessing APIs. If a dependency change becomes necessary, verify the authoritative
registry and upstream release tags before choosing bounds; local corpus metadata
may lag. A native parser may not enforce a separate UUID version/variant contract.
Historical reads must not accidentally acquire a current-clock admission rule.

Use local plan conventions if the work requires an ExecPlan. Keep progress and
acceptance evidence in the repository's established locations; otherwise use
`docs/evidence/domain-scalar-identity-decoder-audit/`. Reuse existing census,
classification, compiler probes and database fixtures before extending them.
Build only the minimum missing coverage checks, not another validation framework.
Discover actual commands and test names; do not copy Shikigami commands blindly.

## Stage 1: Complete inspectable classification before source refactors

Build a coherent target candidate in its declared development environment. Produce
or refresh a machine-readable census, a semantic classification ledger, and an
acceptance note. Bind the census to the actual source set, source/interface hashes
when using compiled declarations, compiler/build configuration, and census tools.
Include empty entrypoints in freshness coverage. Byte-identical retained compiler
interfaces can predate touched source: compare their embedded source fingerprints
where available, not just modification times. Read only target-local build artifacts.

Use stable keys `(sourcePath, module, declaration, member)`: `$self` for every
declaration (including aliases and nullary types), `Constructor.fieldName` for
record members and `Constructor.#1`, etc. for positional arguments and newtype
payloads. Shared selectors need a key per constructor. Source paths distinguish
different `Main` modules. Review alias targets and nested payloads independently.
Fail on unsupported declaration forms rather than silently dropping them.

Each entry records its key, source hash, classification, disposition, invariant,
authority, boundary owner, source-supported rationale, and evidence paths plus
symbols/test names. Explain an absent invariant or authority. Classifications:
`domain-value`, `owned-identity`, `external-identity`, `runtime-opaque`, `locator`,
`boundary-dto`, `incidental`, `structural`. Dispositions: `compliant`, `violation`,
`not-applicable`, `pending`. Structural/container compliance does not certify its
members. An exclusion needs a concrete producer/consumer explanation, including
where an adapter representation enters the domain. Persistence is no exemption.

Bind the ledger to the census hash and guide identity. Derive expected keys
independently of the ledger. A coverage checker must reject missing, extra, or
duplicate keys, pending entries, missing rationale/evidence, stale source/build/
tool hashes, and newly added or removed source files absent from the census.
Provide two modes: complete coverage permitting counted violations, and resolved
coverage refusing any violation. Exercise positive and mutation controls for
deleted/duplicated entries, omitted positional and entrypoint members, source-set
drift, stale hashes, and unresolved violations. Mechanical coverage cannot certify
semantic rationales: read the actual declaration and its uses for every entry.

Finish the entire classification before starting more source refactoring. Report
coverage totals separately from violation totals. Stage 1 passes with all current
keys reviewed, no pending entries, fresh evidence, and passing coverage controls;
known violations may remain. Do not rebuild for classification-only edits unless
the source/build evidence has actually become stale.

## Stage 2: Resolve concrete findings in cohesive concept batches

Apply the guide to demonstrated meaning and existing contracts. Distinct domain
roles require nominal separation when accidental substitution matters. Refined
values require checked construction; reuse existing refiners and hide constructor,
coercion, record-update or Generic bypasses where they would defeat an invariant.
A primitive representation or public constructor alone does not prove a violation.
Keep documentary nominal values without inventing additional refinement contracts.
Use closed alternatives for genuinely closed state/format/permission vocabularies.
Preserve existing valid boolean/string/number encodings when changing representation.

Distinguish service-owned entity identity, native identity, foreign/signed claims,
locators, scoped coordinates, and creation deduplication keys. Allocate TypeIDs only
for actual owned entities when required by the governing contract. Never allocate
replacement identities for unreadable retained intent, wrap an already adequate
native type, redefine identity from a locator, or change deterministic ID/hash/
commitment recipes just to clear a finding. Preserve exact external bytes and
existing grammars. A checked digest alone does not prove content/reference/request
binding: verify the owning associations at construction and the actual read seam.
Filesystem locators may still require runtime revalidation after construction.

For every changed persistence decoder, decode and validate the complete owned
value inside the owning transaction. Distinguish genuine absence, typed corruption
refusal, and SQL/connection failure. A returned `Left` is insufficient if a caller
can ignore it and commit: condemn/abort the transaction using its actual owner's
mechanism. Prove rollback of tentative writes both before and after an ignored
refusal. Do not hide present corruption with inner joins, JSON predicates,
`mapMaybe`, malformed-as-`Nothing`, list trimming, or pagination lookahead. Decode
before filtering when the predicate itself depends on untrusted owned metadata.
Use trustworthy relational indexes when available; document conservative scans.

Keep unreadable intent unresolved. Preserve holds, receipt uncertainty, retained
plans, original attribution and exact winners; do not authorize another send,
launch, allocation, deletion or definitive negative receipt through corruption.
Apply existing preparation invariants before retained plans authorize work. Do not
broaden an owner's authority or impose unrelated validation on advisory text.

For changed owners, execute public-path controls against the real storage engine
using disposable suite-owned databases, never a developer/production database:

- Persist and successfully read a complete valid value, then mutate exactly the
  field or association under test. Include syntactically valid but foreign
  coordinates, not just malformed JSON. Missing unrelated fields cannot explain
  the expected refusal.
- Prove typed refusal, whole-transaction rollback even when ignored, unchanged
  retained evidence/holds, and no forbidden external effect. Corrupt list members
  and pagination probe rows must not disappear behind valid rows.
- Repair the original data and recover the original record/effect/winner without
  replacement. Where allocation/deduplication applies, test repeated/concurrent
  requests and recovery against the same retained winner.
- Retain absent-row and genuine SQL-failure controls. Prove normal database
  constraints first; if testing constraint loss, relax them only in a disposable
  fixture and label that scenario. Direct decoders/custom stores still need
  their own association checks.

For type changes, first compile a valid external client using the public API.
Then require intended compiler rejection for cross-domain substitution and any
constructor/coercion/Generic bypass that violates the real contract. Verify the
failure is the expected type error, not a broken import or build. Exercise positive
and negative codecs, boundaries, exact valid wire goldens and deterministic recipes.
Apply the repository's durable workflow/versioning gates to changed workflow
bodies, replayed codecs or identities; use patches/version transitions when its
policy requires them. Unchanged JSON alone does not prove replay safety.

Use focused tests while implementing each concept batch. Retain source-bound test
evidence, then perform a coherent combined build/census reconciliation instead of
repeating every full suite after small edits. Record each resolved finding's fix
or source-supported classification correction and concrete evidence. Reconcile
removed/moved keys to reviewed successors; deletion alone is not remediation.
Stage 2 passes only with zero unresolved findings and passing changed-owner tests.
If no storage/workflow boundary exists, document that fact rather than adding one.

## Stage 3: Accept the final source

Build the coherent final candidate, refresh the census, reconcile all keys, and
semantically rereview changed sources. Updating hashes alone does not renew review.
Run resolved coverage, the complete relevant compiler controls, final behavioral
suites, and applicable compatibility, workflow, migration, HTTP and style gates.
Use the target's development shell and actual suite fixtures. Record nonzero
selected test counts; database startup/migration failure is failure, not a skip.
Keep deadlines intact and serialize contention-sensitive suites where justified.
Compilation of another platform is not runtime qualification on that platform.

Record commands, exit results, counts, source revision plus dirty-diff identity,
source/build/tool hashes, platform/compiler, test evidence paths, and limitations
in the acceptance note. If a fixture alone needed correction, run its actual
failed test again and distinguish the rerun from the earlier broad run. Preserve
valid evidence across documentation-only edits; rerun when code, failures, or
unresolved concerns invalidate it. If version metadata embeds commits, establish
the final source checkpoint before expensive builds and put evidence-only changes
last, respecting the user's commit instructions.

Update the target's existing adoption/coverage row if present, preserving its
frozen source identities and earlier evidence. Record durable decisions in local
ADRs when appropriate. Stage 3 requires complete current classification, zero
pending or unresolved findings, fresh semantic evidence, and passing executed
acceptance. Do not waive findings as debt or claim an unexecuted platform passed.
If an external blocker prevents completion, preserve the exact remaining work and
report the stage as incomplete. On rerun, reuse and reconcile that work.

Finish with the actual changes, coverage and resolution totals, test results,
evidence locations and any remaining limitations. A successful Seihou provider
session/receipt is not itself semantic or behavioral acceptance.
