---
type: Architecture Decision Record
title: Workspace scaffold history is workspace-keyed with attributable adoption
description: A whole-workspace scaffold keys its record and build manifest by the service name, remembers which member produced each module, and imports pre-workspace output only where attribution exists.
timestamp: 2026-08-04T14:40:00Z
docId: ADR-15
status: Accepted
date: 2026-07-29
---

# 15. Workspace scaffold history is workspace-keyed with attributable adoption

Date: 2026-07-29

Status: Accepted


## Context

[ADR 0014](0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)
made a service workspace a checked graph: several `.keiro` members composed
through a `.keiro-workspace` manifest whose `service` name is the durable
identity. That decided what a workspace *is*. It did not decide what a workspace
*leaves on disk*.

The artifacts that record scaffold output were keyed only by the spec's context
name — `keiro-dsl-scaffold-record.<context>.txt` and
`keiro-dsl-manifest.<context>.txt` — and carried no notion of which source file
produced which module. Two same-context specs scaffolded into one output
directory therefore replaced each other's record, reported each other's modules
as stale, and each rewrote the context-level structural facade from its own
partial mapped-type graph.

Fixing that raises three durable questions. What names workspace history, given
that legacy records already occupy the directory? What does the history have to
remember so that moving an aggregate between member files is not mistaken for
another tool's leftovers? And what may the first workspace run do with output it
finds but did not produce?


## Decision

**History is keyed by the service, in a slot no context name can reach.** A
whole-workspace run writes `keiro-dsl-scaffold-record.workspace.<service>.txt`
and `keiro-dsl-manifest.workspace.<service>.txt`. A context name is lexed as
ASCII letters, digits, `_`, and `-`, so it can never contain a dot; the
`workspace.` segment therefore provably cannot alias a legacy context-keyed
name, even for the very likely case where a service is named after its context.
The bare `keiro-dsl-scaffold-record.<service>.txt` spelling was rejected for
exactly that aliasing: an older keiro-dsl binary running a single-file scaffold
would fail to parse a workspace record sitting at the legacy path, conclude the
directory had no history, and overwrite it — silent destruction of workspace
history by an older tool. Distinct names make old binaries structurally
incapable of touching workspace history.

**The two paths coexist; only the workspace path is new.** The single-file path
keeps its context-keyed names, its bytes, and its report format unchanged. The
workspace path never reads or writes a context-keyed name, with one deliberate
exception: the adoption step, below.

**The record remembers per-module source ownership.** Each module row carries
the member file that produced it. An absent owner means *context-level*: emitted
once for the whole service from the merged graph — the structural projection
facade, the replay-audit assembly, and any binding skeleton whose obligations
span more than one member. A module the workspace still produces whose owner
changed is reported as an **ownership move**: not stale, not new, and not a
content change. Whole-workspace diffing must classify it identically.

**Attribution is structural.** Ownership comes from the emitters themselves —
which mapped declarations a structural module was emitted for, and which node
identity produced a node's modules — resolved through the workspace's ownership
index. It is never recovered by parsing the human-readable origin string, which
exists for refusal messages and carries no contract.

**Idempotence is observable.** The workspace write path compares bytes before
overwriting a Generated module and reports `unchanged` without writing when they
match. A re-run with no source edits therefore proves it changed nothing, rather
than asserting it.

**One golden-payload root per workspace.** Golden payload fixtures are keyed
`<context>/<Aggregate>/<Event>.v<N>.json`, i.e. by aggregate, and an aggregate
has exactly one owner across a workspace — so one root cannot collide. Per-member
roots would make a fixture's location depend on which file currently owns the
aggregate, which would make an ownership move a content change. A fixture found
beside a member that the workspace root lacks is refused before any write, naming
the files to move; silently failing to find it would swap a file-owned golden for
a synthesized stand-in and change harness bytes with no diagnostic at all.

**Adoption claims only what is attributable.** The first workspace scaffold into
a directory that already holds pre-workspace output imports a file into workspace
history only when it is listed in a legacy record for this workspace's own
effective context (`record` evidence), or sits at a path this workspace produces
as Generated and carries the `-- @generated` banner while no surviving record
lists it (`banner` evidence — the orphan case created when one legacy record
overwrote another). Hole paths are never claimed; the create-once rule keeps
governing them. Everything else is reported as unclaimed and left untouched. A
bannerless file at a planned Generated path still refuses the whole run: adoption
never weakens the banner check.

**Adoption deletes nothing and renames nothing.** The superseded legacy record
gains exactly one appended `superseded-by:` line, which its own v1 parser ignores,
so an older binary keeps reading it unchanged. Files the legacy record lists that
this workspace no longer produces are reported as likely stale and deliberately
*not* merged into the workspace record: the record states what this workspace
produces and adopted, not what an abandoned scaffold once produced. A migration
report is printed and persisted once as
`keiro-dsl-migration-report.workspace.<service>.txt`, which is the reviewed
baseline a human works from. Adoption is a one-shot, guarded by the absence of
workspace history, and the provenance it records is carried forward by every
later run.

**Stale evidence is provenance, never proof of disposable bytes.** Single-file,
workspace, and adoption reports inspect every recorded stale Generated path for
the exact current keiro-dsl banner line. A present banner establishes generated
provenance only; deletion additionally requires a clean version-control
comparison or a byte comparison with output regenerated from the same source in
a disposable directory. A missing exact banner is an explicit preserve-and-review
result. Hole paths are always preserved for review. When no earlier record exists,
there is no stale report: operators reconcile the regenerated build manifest with
the old module tree and Cabal stanza manually. Ordinary stale reconciliation
deletes no files and edits no Cabal stanza.

**A recorded generated-name edition permits one explicit, backup-backed source-move
exception.** When a legacy record's stable module role pairs an old path with a current path and
component-wise legacy naming normalization produces exactly that current module name, ordinary
scaffolding refuses before writes and reports the complete move. The operator must rerun with
`--apply-name-migrations`; neither `--force-generated-overwrite` nor ordinary stale authority can
substitute for that opt-in. Module-root and placement changes remain ordinary stale paths even
when their semantic roles pair.

The apply path completes all workspace/package/banner/conflict preflights first, transforms exact
Haskell module references outside comments and literals, hydrates source/transformed content
digests, and prepares every destination beside its final path. It then renames each original under
`.keiro-dsl-name-migrations/legacy-v1-to-idiomatic-v1/` before installing prepared bytes by a
same-filesystem rename. A durable per-move state records paths and digests, so a rerun can resume
an exact prepared/backup/installed crash state or refuse conflicting evidence. Backups are never
deleted or listed in the current manifest/record; create-once bodies remain byte-preserved apart
from exact code-token module references.

**Generated provenance has two permanently recognized banner forms.** Output
created before the 0.9 generator uses the exact historical line
`-- @generated by keiro-dsl; do not edit. Regenerated from the .keiro spec.`.
Current output uses the frozen shape
`-- @generated by keiro-dsl <package-version> (language keiro-dsl
<effective-version>) from <stable-node-origin>; do not edit.`. The package
version is compiled into the running executable, the language version comes
from the checked service boundary, and the origin names the stable context or
node identity without member paths or source-line numbers. Overwrite preflight,
stale evidence, and workspace adoption recognize exactly the historical line or
the stamped shape; an arbitrary comment containing `@generated` is not
provenance. Later banner formats must extend recognition without retiring
either shipped form.


## Consequences

- Two aggregates in one context can live in separate files without overwriting
  each other's records, flagging each other's modules as stale, or clobbering the
  context facade from an incomplete graph.
- Moving an aggregate between member files is a reviewable ownership move with
  no stale churn and no regenerated bytes.
- A directory can hold legacy per-context records and a workspace record at the
  same time, indefinitely. Cleanup is a human decision informed by the migration
  report plus unchanged-byte evidence, never a tool action.
- Adopting a workspace can surface pre-existing files the tool will not claim.
  That list is the point: it is the set a human has to decide about, and it was
  previously invisible.
- A workspace whose members keep their own `golden-payloads` directories must
  consolidate them under one root before the first workspace scaffold succeeds.
- Whole-workspace "atomicity" remains detection-before-write, as ADR 0014
  established: every preflight runs over the complete member set before active
  output changes. An explicitly authorized generated-name migration prepares all
  transformed files first and journals recoverable rename states; ordinary runs
  retain the existing write path.
- Regenerating a legacy tree migrates its generated banners in place while
  preserving the same overwrite authority. Package, language, and stable-node
  provenance become inspectable without making source movement or workspace
  ownership movement churn unchanged generated bytes.


## Alternatives considered

**Version 2 of the existing context-keyed record.** Rejected because the v1 line
grammar cannot carry per-module owners, a member list, and adoption provenance
without ambiguity, and because leaving `ScaffoldRecord` untouched makes
"single-file record names and bytes unchanged" provable by its existing pinned
tests instead of by argument.

**Keying workspace history by context.** Rejected: a context does not identify a
service (several workspaces may share one context in principle, and a context
name cannot survive as an identity across member renames), and it collides with
the legacy naming it must coexist with.

**First-wins or claim-everything adoption.** Rejected because it would take
ownership of hand-written code and overwrite it on the next run. Claim-nothing
was also rejected: it would report an entire existing tree as unrelated and leave
a human to reconcile it by hand, when the record and the banner already provide
real evidence for most of it.

**Deleting or rewriting the superseded legacy record.** Rejected. keiro-dsl never
deletes, and a rewritten record would stop parsing for the older binaries that
may still be in use during a migration. An appended line that v1 ignores is the
only in-place option that preserves both.

**Per-member golden-payload roots.** Rejected because it makes a fixture's
location a function of current ownership, so moving an aggregate would silently
change the generated harness.


## Related decisions

- ADR 0014 defines the workspace itself: the manifest, the single-owner rule,
  and the service name this record is keyed by.
- ADR 0004 assigns every hazard to the earliest boundary with enough evidence,
  which is why the golden-root divergence and the banner check are pre-write
  refusals rather than post-hoc surprises.
- ADR 0012 requires one schema authority per structural mapping, which is why
  the structural projection facade is emitted exactly once from the merged graph
  and recorded as context-level rather than attributed to a member.
