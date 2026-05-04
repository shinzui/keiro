# keiro — 経路

A Haskell library that composes an event store, a pure functional core, and
a subscription engine into a single production-quality framework for **event
sourcing and workflow orchestration** — with an upgrade path to durable
execution.

> **⚠️ Research phase**
>
> keiro is in design. There is no Haskell source yet. The current contents
> of this repository are the research surveys, the MasterPlan that
> decomposes the design effort, and the six child ExecPlans that produce
> the design documents and validating spikes. See [Status](#status) below.

## The name

**経路** (*keiro*) is the Japanese word for **"route"**, **"path"**,
**"course"** — the way a thing travels from origin to destination, both
literally (a route on a map) and figuratively (the course an event takes
through a system).

| Kanji | Reading | Meaning |
|---|---|---|
| 経 | *kei* | to pass through, to elapse, a way, a longitude (cf. *keiki* 継起 — succession of events) |
| 路 | *ro*  | a road, a path, a way |

The choice is literal. Every concept this framework cares about is a
*route*:

- An **event log** is the route a single aggregate's history has taken —
  one event after another, in order.
- A **subscription** traces a route across the global stream, advancing a
  cursor as events flow past it.
- A **process manager** routes events from one bounded context into
  commands directed at another.
- A **workflow**, in the durable-execution sense, is a route through
  state space whose itinerary survives crashes and redeployments.

Where its sibling [keiki](https://github.com/shinzui/keiki) — 継起,
"successive occurrence" — names the *succession* of events, *keiro* names
the *paths* those events take and the *routes* that downstream processes
follow.

## What it is

keiro is a thin, opinionated, library-shaped framework — *not* a server.
You import it into a Haskell application that already connects to
PostgreSQL; keiro turns the underlying components into a single coherent
runtime:

- **[kiroku](https://github.com/shinzui/kiroku)** — Postgres-backed
  append-only event store. Provides optimistic-concurrency append, stream
  and category reads, gap-free contiguous global positions (Strategy E),
  and live subscriptions.
- **[keiki](https://github.com/shinzui/keiki)** — pure functional core.
  Provides the symbolic-register finite-state transducer
  (`SymTransducer phi rs s ci co`) that keiro consumes directly: it
  carries the typed register file, the ε-edges, and the symbolic
  predicates that workflow features depend on.
- **[shibuya](https://github.com/shinzui/shibuya)** — supervised
  subscription / queue-processing engine. Provides NQE supervision,
  Streamly backpressure, OpenTelemetry tracing, and adapters for kiroku,
  pgmq, Kafka, etc.
- **[pgmq-hs](https://github.com/shinzui/pgmq-hs)** plus
  **shibuya-pgmq-adapter** — Postgres-native durable queue, used for
  outbox relays and durable-timer wakeups.
- **effectful** and **hasql** — the runtime substrate keiro is written
  against.

On top of that stack, keiro v1 will deliver the canonical command cycle —
*load events, fold to state, decide via the transducer, append the new
events with optimistic concurrency, retry on conflict* — plus inline and
async projections, event-sourced process managers, transactional
outbox/inbox, snapshots, and durable timers. v2 layers a deterministic
durable-execution runtime (Inngest-style named steps) over the same
substrate.

## Status

This repository currently contains:

- **Five current-state surveys** covering the dependencies and prior art.
  Start at [`docs/research/00-overview.md`](docs/research/00-overview.md).
- **One MasterPlan**,
  [`docs/masterplans/1-keiro-research-foundation.md`](docs/masterplans/1-keiro-research-foundation.md),
  decomposing the research into six child plans (command cycle, codecs,
  subscriptions/projections/process managers, snapshots, workflow roadmap,
  upstream gaps).
- **Six child ExecPlans** under [`docs/plans/`](docs/plans/).

When the MasterPlan completes, three of the six child plans will have
landed working Haskell spikes under `spikes/` validating the design; the
six design documents (`docs/research/06-…` through `11-…`) will fix the
contracts; and the upstream-roadmap document will hand kiroku and keiki a
prioritized backlog to develop in parallel. After that, a separate
implementation MasterPlan will ship the production keiro library.

## License

TBD.
