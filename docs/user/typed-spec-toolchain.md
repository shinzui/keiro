# Typed Specifications With `keiro-dsl`

`keiro-dsl` turns a checked `.keiro` service specification into generated
Haskell modules, create-once typed holes, conformance harnesses, and an evolution
report. It is a build-time toolchain, not a runtime interpreter: generated code
uses the same public Keiro APIs as hand-written services.

## Supported node families

A specification starts with `context <name>` and may declare shared ids, enums,
and total rules. The current grammar covers:

- aggregates, event versions/upcasters, projections, and snapshot policies;
- process managers, timers, worker rejection/poison policies, and target inline
  projections;
- effectful routers backed by a read model or a typed resolver hole;
- integration contracts, inbox intake, outbox emits, and publishers;
- PGMQ work queues, ordering/group keys, provisioning, retry/DLQ policy, and
  read-model-driven dispatch;
- first-class read models, schemas, columns, consistency, scope, and feed;
- durable workflows, named operations, patches, and continue-as-new.

Use `keiro-dsl new <kind>` to print a minimal valid skeleton. The CLI accepts
`aggregate`, `process`, `router`, `contract`, `intake`, `emit`, `publisher`,
`workqueue`, `dispatch`, `workflow`, and `operation`.

## Authoring loop

```bash
cabal run keiro-dsl -- new aggregate > service.keiro
cabal run keiro-dsl -- parse service.keiro
cabal run keiro-dsl -- check service.keiro
cabal run keiro-dsl -- scaffold service.keiro --out src
cabal run keiro-dsl -- diff service.keiro --since HEAD^
```

- `parse` pretty-prints the parsed specification and catches notation errors.
- `check` resolves cross-node references and rejects unsafe or incomplete
  policy. Add `--emit` to print the normalized spec on success.
- `scaffold` validates before writing, emits the generated layer and typed hole
  modules, then reports every created, overwritten, skipped, and stale path.
- `diff` loads the earlier spec from Git and classifies changes as `ADDITIVE`,
  `WARNING`, or `BREAKING`; any breaking change exits non-zero.

Run commands from the repository containing the spec because `diff` resolves
`--since` with `git show`.

## Generated and hand-owned files

Generated modules carry an `-- @generated` banner and may be replaced on every
scaffold. Hole modules are create-once: a later run skips them so filled domain
logic is preserved. Never edit generated modules; change the spec and scaffold
again.

The scaffolder plans the complete write before touching disk. It refuses
invalid specs, module-path/case-fold collisions, scaffold-unsafe identifiers,
unsupported literal/type lowering, policy drift, or an existing generated path
without the banner. `--force-generated-overwrite` bypasses only the missing
banner check and should be used only after confirming the file is disposable.

Each successful run writes a manifest with Cabal `other-modules` and dependency
snippets plus a scaffold record. When the next spec emits fewer modules, the
report marks old paths as stale but never deletes them; review generated and
hand-owned candidates separately.

## Module placement

The default layout puts generated code under `Generated.<Context>...` and holes
under `<Context>...`. A spec may choose a namespace and collocated layout:

```text
context hospital-capacity
module Acme.Services
layout collocated
```

The equivalent CLI flags are `--module-root Acme.Services --collocate`; CLI
values override the spec. Collocation places generated modules below
`Acme.Services.<Context>.<Node>.Generated` while keeping holes beside them in
the domain namespace.

## Important checked contracts

The checker owns the cross-node and persistence contracts that are dangerous to
reconstruct from prose:

- Aggregate status maps are exact and total unless explicitly marked
  `partial`; event evolution needs contiguous upcasters; snapshot policies need
  a valid codec version and captured live shape hash.
- Process and router references resolve to declared aggregates, commands, read
  models, and fields. `CommandAmbiguous` follows the declared rejection policy
  and may not be treated as a benign timer outcome.
- Inbox and work-queue disposition tables are complete. Duplicates acknowledge,
  transient store failures retry, poison decode failures dead-letter, and
  previously failed inbox rows do not become an unbounded retry loop.
- FIFO queues require a group key; unordered queues reject one. Captured
  physical queue, DLQ, and table names must match the logical-name derivation.
- Strong read models use a subscription feed and may declare category scope;
  inline models must be owned by a matching aggregate projection. Captured
  shape changes require a version bump.
- Workflow step/patch labels are unique, signals match awaits, field references
  resolve, and `continueAsNew` is terminal.

Warnings remain visible but do not fail `check`; errors do. Diagnostics include
the source row so the specification, rather than generated Haskell, is the
place to fix the contract.

## Evolution gate

`diff` classifies persistence identity and decode changes across every node
family. Breaking examples include changing an event field type without a new
version/upcaster, renaming stable workflow/router/queue identities, changing a
workflow continuation seed, changing queue ordering/group/provisioning, or
retargeting a dispatch. Treat a non-zero result as a deployment gate, not a
formatting warning.

The executable fixture and conformance index is
[Keiro DSL Corpus](../corpus/keiro-dsl-corpus.md). It links valid and negative
specs, generated runtime modules, full hand-filled examples, mutation tests,
and cold-start conformance packages.
