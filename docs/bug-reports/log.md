# Bundle Update Log

## 2026-10-14
* **Update**: BUG-11 fixed: whole-name generated stems and bounded import audit pass Language 6 keyword-segment conformance and full verification
* **Update**: BUG-11 in progress: Language 6 conformance suite reproduces GHC-61689
* **Update**: BUG-10 fixed/unreleased: history-backed aggregate and whole-service proofs, all eight witness mutations, corpus freshness, and the full Nix-shell verification gate pass.

## 2026-10-13
* **Update**: BUG-10 confirmed: the compiled history-dependent fixture fails both initial clear harness rows while its behavior report passes.
* **Update**: BUG-12 is tracked by ExecPlan 311, which makes live-schema verification consult keiro.keiro\_managed\_read\_objects so runtime-created binding views are expected while unregistered views stay reported; status remains reported until the compiled fixture fails.
* **Update**: BUG-11 is tracked by ExecPlan 310, which derives every generated declaration stem once from the whole logical name, shares the read-model stem between the definition and the harness import, adds a compiled keyword-segment conformance suite, and audits generated-to-generated explicit imports before scaffold writes.
* **Update**: BUG-11 is confirmed by the owning repository: the report's minimal specification reproduces on master after 0.20.0.0 with keiro-dsl scaffold and GHC 9.12.4 (GHC-61689 on the untouched read-model harness; the renamed control type-checks); the transcript is retained under evidence/.
* **Update**: BUG-10 is tracked by ExecPlan 309, which validates the generator diagnosis from source, reproduces the generated probe shape in keiro, and plans witness-backed harness rows for hole-owned initial edges; status remains reported until the compiled fixture fails.
* **Addition**: BUG-10 records false failing initial-hole acceptance and forward/replay probes for Rei's history-dependent ClearProperty. Retain consumer gate evidence, generator diagnosis and repair acceptance; owner investigation remains pending, separate from completed IR-18.

## 2026-10-03
* **Addition**: BUG-9 records that `keiro-ops --json pgmq dlq read` renders `dlq_message_id` with pgmq-core's derived `Show` instead of a number.
* **Addition**: BUG-8 records a parent left suspended permanently when its child's process dies between the child's completion marker and the parent wake.

## 2026-09-30
* **Update**: BUG-7 is tracked by ExecPlan 301, which confirms from adapter and shibuya source that the retry ceiling runs on the adapter's source stream before the supervised runner opens the process span, and plans the fix inside keiro's handler.
* **Update**: Audit all seven lifecycle statuses and plan coverage: BUG-1/BUG-2 remain duplicate with completed plans 297/298; BUG-4/BUG-6 link unimplemented plan 300; BUG-5 links unimplemented plan 299; BUG-3/BUG-7 remain reported with no plan addressing their specific failures. Add per-report implementation notes and the index summary.
* **Addition**: BUG-12 records keiro-ops reporting Keiro's own `external_read_<function>_binding` view as schema drift, because the expected snapshot is generated from migrations alone; every mutating operator command on a service with an all-rows external-read contract refuses without `--allow-schema-drift`.

## 2026-09-28
* **Addition**: BUG-11 records released read-model generation producing different definition and harness-import spellings when a snake-case name contains the Haskell keyword segment `type`; an untouched minimal harness fails compilation and a renamed control succeeds.

## 2026-09-25
* **Update**: BUG-2 attribution controls pass with released Kiroku 0.9.0.1 and bounded verification threads
* **Update**: BUG-1 and BUG-2 duplicates now point to released kiroku-store 0.9.0.1
* **Update**: BUG-2 is a duplicate of mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-3: a single-change Kiroku publisher fix reduced matched command-soak post-major live growth from 93.13 MB to 1.63 MB.
* **Update**: BUG-1 is a duplicate of mori://shinzui/kiroku/okf/bug-reports/concepts/BUG-3: both released worker profiles identify the Kiroku publisher thunk, and a strict-update comparison removes the large-object growth.

## 2026-09-24
* **Addition**: BUG-7 records a pre-handler retry-ceiling DLQ delivery that has no per-message process span despite traced enqueue.
* **Addition**: BUG-6 records a six-processor long-poll stall on the fixed three-connection job runtime pool; a one-processor replacement recovered the queued job.
* **Report**: Recorded a durable stale-publisher finalization race after outbox maintenance reclaims a row.
* **Addition**: BUG-3 records a continuous job worker exiting after polling backend termination; BUG-4 records long-poll read attempts consumed without handler delivery after process death. Both were reproduced by the Kenshou queue scenarios and remain reported pending upstream investigation.
* **Update**: BUG-1 and BUG-2 are tracked by ExecPlans 297 and 298, which attribute the retention across keiro, kiroku, and the Kenshou harness before any fix.
* **Addition**: BUG-1 records process-manager and router worker heap growth in
the steady write-side soak; BUG-2 records command-workload heap growth with
seed verification disabled. Both remain reported pending component isolation.

## 2026-09-23
* **Bootstrap**: Establish the bug-report bundle under the shared
`coordination.bugReports` profile.
