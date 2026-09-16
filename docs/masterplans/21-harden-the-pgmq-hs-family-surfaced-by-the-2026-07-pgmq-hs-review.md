---
id: 21
slug: harden-the-pgmq-hs-family-surfaced-by-the-2026-07-pgmq-hs-review
title: "Harden the pgmq-hs family surfaced by the 2026-07 pgmq-hs review"
kind: master-plan
created_at: 2026-07-23T04:18:29Z
provenance:
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T13:25:58Z
      mode: "update"
      note: "Reconciled upstream ownership, 0.6 adoption, current verification, and remaining work"
---

# Superseded: Harden the pgmq-hs family surfaced by the 2026-07 pgmq-hs review

This MasterPlan is an archival coordination record. The implementation scope was relocated to
the official pgmq-hs repository, completed there, and released. Keiro's consumer-adoption tail
is also complete. Do not reimplement any of the original findings in this repository.


## Vision & Scope

The 2026-07 review found eleven defects in the five-package pgmq-hs family: incorrect SQL
`NULL` handling, notification crash and startup races, queue-name aliasing, incomplete error
classification, and related public-contract gaps. Those defects belong with the owner of the
affected APIs, SQL, migrations, and tests, so the authoritative coordination document is
`mori://shinzui/pgmq-hs/masterplans/3-harden-the-pgmq-hs-family-surfaced-by-the-2026-07-review`.

Keiro's scope is deliberately narrower. Keiro consumes the released package family through
`keiro-pgmq`, `keiro-ops`, `keiro-dsl`, and `jitsurei`; it owns compatible dependency bounds,
source adaptation where public records change, focused regression coverage, and verification
that all consumers resolve one coherent released family. It does not own pgmq-hs statements,
migrations, validation rules, notification functions, or release notes.

This refresh also distinguishes later work from the original review. PGMQ 1.12/1.13 grouped
reads and partition controls were released through
`mori://shinzui/pgmq-hs/plans/12-expose-grouped-reads-on-the-umbrella-api-and-release-0-5-0-0`
(the stable path now describes release 0.6.0.0), with Keiro adoption tracked locally in
[ExecPlan 280](../plans/280-complete-the-pgmq-hs-0-6-0-0-upgrade.md). The still-active FIFO
ordering, index, and retention initiative at
`mori://shinzui/pgmq-hs/masterplans/5-correct-the-fifo-grouped-read-ordering-index-and-partition-retention-contracts`
is separate work and does not reopen this MasterPlan.


## Decomposition Strategy

There are no executable child plans left in Keiro. The original implementation was divided in
the owner repository by functional concern, while release and consumer adoption were kept as
separate integration tails:

- `mori://shinzui/pgmq-hs/plans/13-fix-null-parameter-semantics-across-pop-read-and-notify-statements`
  owns SQL optional-parameter semantics and missing-row visibility-timeout results.
- `mori://shinzui/pgmq-hs/plans/14-make-insert-notifications-survive-crashes-and-document-the-channel-contract`
  owns notification recovery, advisory locking, re-entry, and the public channel contract.
- `mori://shinzui/pgmq-hs/plans/15-validate-queue-names-and-classify-transient-errors-across-the-pgmq-layers`
  owns queue-name validation, transient SQLSTATE classification, and SQL `NULL` body decoding.
- The upstream release plan owns public exports, coherent package versions, source archives,
  compatibility documentation, and candidate validation.
- Keiro ExecPlan 280 owns only Keiro's final 0.6-family and adapter-0.15 adoption, documentation,
  regression assertions, and consumer validation.


## Exec-Plan Registry

| ID | Title | Path | Dependencies | Status |
|---:|---|---|---|---|
| U-13 | Fix NULL parameter semantics across pop, read, and notify statements | `mori://shinzui/pgmq-hs/plans/13-fix-null-parameter-semantics-across-pop-read-and-notify-statements` | None | Complete; released in 0.5.0.0 |
| U-14 | Make insert notifications survive crashes and document the channel contract | `mori://shinzui/pgmq-hs/plans/14-make-insert-notifications-survive-crashes-and-document-the-channel-contract` | None | Complete; released in 0.5.0.0 |
| U-15 | Validate queue names and classify transient errors across the pgmq layers | `mori://shinzui/pgmq-hs/plans/15-validate-queue-names-and-classify-transient-errors-across-the-pgmq-layers` | None | Complete; released in 0.5.0.0 |
| U-12 | Expose the complete API and prepare the 0.6.0.0 release | `mori://shinzui/pgmq-hs/plans/12-expose-grouped-reads-on-the-umbrella-api-and-release-0-5-0-0` | Upstream PGMQ 1.12/1.13 implementation plans | Complete; released in 0.6.0.0 |
| K-280 | Complete the pgmq-hs 0.6.0.0 upgrade | [docs/plans/280-complete-the-pgmq-hs-0-6-0-0-upgrade.md](../plans/280-complete-the-pgmq-hs-0-6-0-0-upgrade.md) | pgmq-hs 0.6.0.0 and shibuya-pgmq-adapter 0.15.0.0 releases | Complete |


## Dependency Graph

The three original upstream hardening plans were independent implementation streams and all
landed before the 0.5.0.0 family release. The later 0.6.0.0 release preserved those fixes while
adding PGMQ 1.12/1.13 capabilities. Keiro could complete its 0.6 adoption only after both the
pgmq-hs family and a compatible shibuya adapter were published:

```text
U-13 + U-14 + U-15 -> pgmq-hs 0.5.0.0
completed PGMQ 1.12/1.13 plans -> U-12 -> pgmq-hs 0.6.0.0
pgmq-hs 0.6.0.0 + shibuya-pgmq-adapter 0.15.0.0 -> K-280 -> Keiro adoption complete
```

No remaining hard dependency blocks this MasterPlan. The unchecked external-follow-through
item still present in upstream MasterPlan 3 is stale coordination text: upstream plan 12 is
complete, Hackage publishes the five-package 0.6.0.0 family, tag `v0.6.0.0` resolves to release
commit `7269f4de0a6e4e6f138c849758c18c7324410ac2`, and Keiro adoption is committed.


## Integration Points

The pgmq-hs repository owns the `Pgmq` and `Pgmq.Effectful` public APIs, Hasql statements,
Effectful interpreter, declarative queue configuration, native schema migration ledger, and
all compatibility claims about PGMQ server versions. Keiro consumes those artifacts through
the canonical package family rooted at `mori://shinzui/pgmq-hs`.

`mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter` is the second release
boundary. Its 0.15.0.0 release admits the pgmq-hs 0.6 family without changing the adapter API
used by Keiro. Keiro must move the pgmq family and adapter together whenever their declared
bounds require it; overrides such as `allow-newer` are not acceptable completion evidence.

Within Keiro, `keiro-pgmq/keiro-pgmq.cabal` is the central bounded consumer. The direct bounds
in `keiro-pgmq`, `keiro-ops`, and `jitsurei` require the pgmq 0.6 family, and adapter consumers
require 0.15.0.0. `keiro-dsl` participates through its queue-runtime conformance components.
The generated Cabal plan selects exactly one copy of every shared `QueueName`, `Message`,
configuration, and metrics type.

[ADR 1](../adr/0001-keiro-pgmq-job-processing-telemetry-contract.md) remains the relevant local
behavioral constraint: dependency adoption must preserve one truthful process span per delivery
on both Keiro execution paths. This refresh changes no API ownership or telemetry contract, so
no ADR update is required.


## Progress

- [x] (2026-08-05) Upstream plans 13, 14, and 15 implemented all eleven original findings and
  pinned the fixes with focused tests.
- [x] (2026-08-06) The original hardening shipped in pgmq-hs 0.5.0.0.
- [x] (2026-09-10) Upstream plan 12 completed the PGMQ 1.12/1.13 follow-through and produced
  the coherent pgmq-hs 0.6.0.0 family. All five Hackage package-version documents list 0.6.0.0
  as a normal version, and the upstream release tag resolves to commit `7269f4de`.
- [x] (2026-09-14) `shibuya-pgmq-adapter` 0.15.0.0 was published with pgmq 0.6 bounds; tag
  `v0.15.0.0` resolves to release commit `22f5c4dae97722727f2f2ed47d1bf2ed9603d4ed`.
- [x] (2026-09-14) Keiro ExecPlan 280 completed the consumer rollout at commit `9b595352`.
  Every bounded consumer now requires pgmq `>=0.6 && <0.7`, and every direct adapter consumer
  requires `^>=0.15.0.0`.
- [x] (2026-09-16) Re-verified current released versions, upstream tags, checked-in bounds,
  the resolved Cabal graph, the full build, and all affected Keiro consumer suites.


## Surprises & Discoveries

- The August snapshot in this file was no longer current. Keiro has since moved from pgmq
  0.5.0.0 and adapter 0.13.0.0 to pgmq 0.6.0.0 and adapter 0.15.0.0. Local ExecPlan 280 records
  the intervening solver gate, source-visible record changes, documentation, and complete
  validation evidence.
- Upstream MasterPlan 3 still shows its external plan-12 follow-through as unchecked even
  though plan 12 marks every milestone complete, upstream tag `v0.6.0.0` exists, and all five
  packages are normal Hackage releases. This is upstream documentation drift, not missing code
  or a Keiro blocker. The only in-scope upstream follow-up is to reconcile that checkbox and
  close its retrospective.
- Mori currently discovers `mori://shinzui/pgmq-hs`, all five package handles, the repository
  path, and curated documentation, but this registry snapshot cannot resolve the plan-level
  URIs with `mori path`. The canonical intended URIs remain the durable references; source
  verification used the repository Mori located.
- The separate upstream FIFO/index/retention MasterPlan 5 remains Not Started. Its three child
  plans concern deterministic grouped-read return order, a supplemental usable FIFO index, and
  truthful FIFO/retention documentation. None is one of this MasterPlan's eleven original
  findings, so they remain separate rather than making this archival plan In Progress again.
- Current verification increased the test counts recorded in the older adoption evidence. On
  2026-09-16, `keiro-pgmq-test` ran 65 examples with zero failures and the same two documented
  environment/fault-injection pending cases; `keiro-ops-test` ran 50, `keiro-migrations-test`
  ran 36, and `jitsurei-test` ran 25, all with zero failures. The queue-runtime conformance
  executable also passed.


## Decision Log

- Decision: Supersede Keiro MasterPlan 21 with pgmq-hs MasterPlan 3 and preserve this file as
  a redirect and consumer-status record.
  Rationale: The findings change pgmq-hs APIs, migrations, tests, and release artifacts; the
  source-of-truth plans belong beside that code. Keiro only owns adoption and compatibility.
  Date: 2026-07-23

- Decision: Move the pgmq family and `shibuya-pgmq-adapter` together whenever the adapter's
  released bounds require the matching family.
  Rationale: The pgmq 0.5 rollout proved that a direct-bound-only edit can leave the adapter
  uncompilable. The same release-first rule was applied successfully to the 0.6/0.15 rollout.
  Date: 2026-08-09; reaffirmed 2026-09-16

- Decision: Treat upstream plan 12 and Keiro plan 280 as completed integration tails, not as
  new children of this superseded MasterPlan.
  Rationale: They extend release and consumer compatibility beyond the original defects while
  preserving the ownership boundary. Referencing them gives a restartable history without
  pretending their broader PGMQ 1.12/1.13 scope originated here.
  Date: 2026-09-16

- Decision: Leave the newer upstream FIFO/index/retention initiative outside this plan.
  Rationale: It was discovered by a separate FIFO review, has its own upstream MasterPlan and
  acceptance criteria, and is still executable work. Folding it into this completed archive
  would obscure both initiatives' status.
  Date: 2026-09-16


## Outcomes & Retrospective

This initiative is complete in both repositories. Upstream owns and has shipped all original
correctness fixes. It subsequently published the 0.6.0.0 family, preserving the hardening while
adding its PGMQ 1.12/1.13 feature set. Keiro consumes that released family together with
`shibuya-pgmq-adapter` 0.15.0.0 and needs no source override, relaxed bound, or local dependency
checkout.

The 2026-09-16 generated Cabal plan contains:

```text
pgmq-config             0.6.0.0
pgmq-core               0.6.0.0
pgmq-effectful          0.6.0.0
pgmq-hasql              0.6.0.0
pgmq-migration          0.6.0.0
shibuya-pgmq-adapter    0.15.0.0
```

Validation from the Keiro repository root produced:

```text
cabal build all:                              PASS
keiro-pgmq-test:                 65 examples, 0 failures, 2 pending
keiro-ops-test:                  50 examples, 0 failures
keiro-migrations-test:           36 examples, 0 failures
keiro-dsl-conformance-queue-runtime:          PASS
jitsurei-test:                   25 examples, 0 failures
```

Therefore nothing remains to implement in Keiro for this MasterPlan, and nothing remains to
implement upstream for its original findings. The only in-scope upstream cleanup is to update
MasterPlan 3's stale external-follow-through checkbox and retrospective to match the already
published 0.6.0.0 release and completed Keiro rollout. Upstream MasterPlan 5 remains real but
separate future work.


## Revision Note

2026-07-23: Replaced the executable plan with this supersession record after relocating and
updating it in the official pgmq-hs repository.

2026-08-09: Validated all original findings as fixed and released in pgmq-hs 0.5.0.0, then
completed Keiro's paired pgmq-0.5 and adapter-0.13 adoption with focused consumer validation.

2026-09-16: Refreshed the entire coordination boundary against Mori-located source,
authoritative Hackage version documents, upstream release tags, current Keiro dependency
bounds, local ExecPlan 280, the generated Cabal plan, and a new full build plus affected-suite
run. Recorded pgmq-hs 0.6.0.0 and adapter 0.15.0.0 adoption as complete, identified upstream
MasterPlan 3's remaining checkbox as documentation drift only, and explicitly excluded the
separate active FIFO/index/retention initiative.
