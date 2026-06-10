---
id: 58
slug: build-the-keiro-dsl-service-dsl-toolchain
title: "Build the keiro-dsl service DSL toolchain"
kind: exec-plan
created_at: 2026-06-10T00:09:18Z
intention: "intention_01ktqdn85xe2btqzr2zghxgrpr"
superseded_by: "docs/masterplans/8-build-the-keiro-dsl-service-dsl-toolchain.md"
---

# Build the keiro-dsl service DSL toolchain — SUPERSEDED (converted to a MasterPlan)

> **This ExecPlan has been converted into a MasterPlan.** Do not implement from this
> file. Its scope grew to span a shared engine plus five independent node verticals, so
> on 2026-06-10 it was decomposed into a MasterPlan with seven child ExecPlans.
>
> **Start here:** [`docs/masterplans/8-build-the-keiro-dsl-service-dsl-toolchain.md`](../masterplans/8-build-the-keiro-dsl-service-dsl-toolchain.md)

All of this plan's research, decisions, surprises, and milestone scope were carried
forward — nothing was lost. They now live in the MasterPlan (Vision & Scope,
Decomposition Strategy, Integration Points, Decision Log, Surprises & Discoveries) and
in the child ExecPlans:

| Child | Scope | Path |
|---|---|---|
| EP-1 | Foundations: grammar, parser, validator, scaffold/harness engine, **aggregate** vertical end-to-end | `docs/plans/59-keiro-dsl-foundations-grammar-parser-validator-scaffold-and-harness-engine-aggregate-vertical.md` |
| EP-2 | Evolution: `schemaVersion`/`upcast`/`deprecated` + `diff --since` | `docs/plans/60-keiro-dsl-evolution-schema-versioning-upcasters-deprecation-and-diff.md` |
| EP-3 | Process managers + durable timers | `docs/plans/61-keiro-dsl-process-manager-and-durable-timer-nodes.md` |
| EP-4 | Integration: inbox/outbox/Kafka + `contract` | `docs/plans/62-keiro-dsl-integration-nodes-inbox-outbox-kafka-and-contract.md` |
| EP-5 | PGMQ workqueue/dispatch | `docs/plans/63-keiro-dsl-pgmq-workqueue-and-dispatch-nodes.md` |
| EP-6 | Workflow + operation | `docs/plans/64-keiro-dsl-workflow-and-operation-nodes.md` |
| EP-7 | Authoring skill + corpus registration | `docs/plans/65-keiro-dsl-authoring-skill-and-corpus-registration.md` |

The defining decisions established here and preserved in the MasterPlan: keiro-dsl is a
**typed spec** with `check` + `scaffold` + `harness` + `diff` (not a full transducer
generator); the scaffolder emits only the symbol-free deterministic layer plus typed
holes and **never** a keiki symbolic operator (the firewall invariant); the behavior-
bearing transducer body and the eight hole-kinds are agent-written and harness-pinned;
and the conformance corpus is the external `keiro-runtime-jitsurei`, captured as
read-only fixtures.
