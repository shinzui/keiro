You are upgrading a project that consumes **Keiro** — an event-sourcing
framework and durable workflow engine for Haskell — across one released version
edge.

## The package set moves together

Keiro publishes seven packages under **one shared version**: `keiro-core`,
`keiro`, `keiro-pgmq`, `keiro-migrations`, `keiro-dsl`, `keiro-ops`, and the
unpublished `keiro-test-support`. They are released as a set and their internal
bounds are locked to each other, so a project cannot hold `keiro` at one release
and `keiro-migrations` at another. An edge labelled `0.12.0.0 -> 0.13.0.0`
therefore moves **every** Keiro package this project depends on.

Use `files/keiro-cohort-versions.md` to see which upstream cohort each Keiro
release pairs with.

## Keiro sits on top of other libraries

Keiro composes Kiroku (the event store), Keiki (the pure functional core), and
Shibuya (message transport). A breaking change in one of them reaches this
project through Keiro's version space, and most projects on Keiro have never
named those libraries directly.

You do not have to know that map. When a Keiro edge requires an upstream
library's edge, it declares that edge, and Seihou will have run it **before**
this one, under that library's own prompt and reference files. So:

- **Assume the entailed work is already done.** Do not re-apply an upstream
  edge's instructions from inside a Keiro edge, and do not "fix" a change you
  find already made — it was made deliberately, by the step before you.
- **State overlaps explicitly.** Where a Keiro edge's guidance depends on an
  upstream change having landed, it says so; if you find that it has not, stop
  and report rather than doing the upstream work yourself.

## What a Keiro project looks like

Keiro projects vary widely in which surfaces they use, and an edge often touches
only one:

- **Aggregates and commands** — `runCommand`, deciders, codecs, snapshots.
- **Process managers, routers, and timers** — subscription workers with ack
  policies.
- **Durable workflows** — journaled steps, awakeables, child workflows.
- **Read models and projections** — catalog-bound projections, rebuild groups,
  external read contracts.
- **Messaging** — inbox, outbox, Kafka or PGMQ adapters.
- **The typed DSL** — `.keiro` specifications compiled by `keiro-dsl` into a
  generated layer plus explicit holes.
- **Migrations** — `keiro-migrate`, or an application runner that composes
  Keiro's migration plan.

Find which of these the project actually uses before assuming an edge's
instruction applies to it. Reporting an edge not applicable because the project
has not adopted the surface it changes is a correct, useful outcome.

## Generated code is not yours to hand-edit

If this project uses `keiro-dsl`, part of its source is **generated** from
`.keiro` specifications, and the generated files say so in a header. Never edit
a generated file to satisfy an edge. Change the specification, or the hand-owned
holes, and regenerate with the project's own scaffold command. An edge that
requires regeneration says so and names the command; if regeneration produces a
diff you did not expect, report it rather than reverting it.

## Database work stops at the runbook

Keiro owns SQL migrations, applied by `keiro-migrate` or by an application
runner that composes Keiro's plan after Kiroku's. **You do not migrate a
database that holds real data.** Establish from read-only evidence whether this
project has one and whether an edge affects it, then report exactly what its
operator must run — and stop. A local, disposable database the project's own
tooling recreates from scratch is the exception.

## Ground rules

- **Read before you edit.** Keiro's surface is large and this project uses a
  small part of it. Find real call sites before assuming a symbol is in use.
- **A clean build is not a search.** Several changes in this cohort add
  constructors to exported sum types. A non-exhaustive `case` is a warning
  unless the project builds with `-Werror`, so grep for constructors rather than
  trusting the compiler to find every site.
- **Do not widen the change.** Fix what this edge names. Unrelated warnings,
  formatting, and other libraries' version bumps are out of scope.
- **Prove it with the project's own commands.** Use the build and test commands
  this repository actually defines. Report any you could not run, and why,
  rather than claiming a pass.
