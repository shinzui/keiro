---
type: Architecture Decision Record
title: Service conformance packages import one runtime-owned facade
description: A configured Keiro service generates at most one local conformance package whose runner imports one generated facade from an explicitly named runtime package while create-once expectations remain application-owned.
timestamp: 2026-08-03T18:16:03Z
docId: ADR-20
status: Accepted
date: 2026-08-03
---

# 20. Service conformance packages import one runtime-owned facade

Date: 2026-08-03

Status: Accepted


## Context

`keiro-dsl scaffold` emits node-level conformance harnesses and a text build
manifest, but a consumer still has to assemble those harnesses into a Cabal test
component and maintain that component as the checked service graph changes. A
workspace may contain several member files and many aggregates, read models,
processes, routers, and workflows, so using a member or node as the package
boundary would multiply runners that all describe parts of one service.

The runtime modules cannot simply move into a generated test package. Hand-owned
Hole modules and application types are compiled by the consumer's runtime
library and are imported by generated runtime modules. Moving their harnesses
across that boundary while importing application code can create a package cycle
or force every generated internal module into the consumer's public API.

The workspace service name also cannot identify the runtime Cabal package. A
service such as `mori` may be implemented by a package such as `mori-core`.
Searching nearby Cabal files or deriving a package name from the service would
make generated output depend on incidental filesystem layout and can select a
package that does not exist.


## Decision

An explicitly configured Keiro service produces at most one local conformance
package. A workspace uses its manifest `service` value as the package identity;
a standalone `.keiro` file uses its existing checked context as the one-file
service identity. Workspace members and semantic nodes never create additional
packages.

The consumer's service runtime and the generated conformance package remain
distinct Cabal packages. Per-node harness implementations stay compiled in the
runtime package beside the generated and hand-owned modules they exercise.
Keiro generates one service-level conformance facade in that runtime package.
The generated conformance runner imports only this facade, so a consumer exposes
one stable generated module without making every per-node implementation module
part of its public API.

The runtime package name is explicit build metadata. A workspace may persist it
with an optional `runtime-package <cabal-name>` clause, and `scaffold` may supply
or override it with `--runtime-package`. Keiro validates the value as a Cabal
package name and never infers it from the service, directory, or nearby Cabal
files. The CLI value has precedence over the workspace value.

Package generation is additive and opt-in for the current language-4 release.
When no effective runtime package is configured, single-file and workspace
scaffold modules, manifests, records, and reports remain unchanged. Configuring
a runtime package adds the facade and the service package under deterministic
service-keyed paths.

The generated package owns its runner and a create-once service expectations
module. Aggregate assertions and read-model derivation checks are self-checking
and need no copied baseline. Process, router, and workflow facts are compared
with the create-once expectation module, which Keiro creates on first adoption
and never overwrites. This makes a changed fact fail until an application owner
reviews and accepts it instead of generating both sides of a tautological test.

The existing `keiro-dsl-manifest.*.txt` remains the authoritative runtime build
inventory and compatibility artifact. A runnable conformance package removes
the need to translate that manifest into a hand-written runner; it does not
remove the runtime library's obligation to compile generated modules and their
dependencies.

All package planning participates in the existing detection-before-write
scaffold boundary. Runtime and package preflights must both succeed before
either writer changes bytes. Generated package files require recognized Keiro
provenance to overwrite, the expectations module is create-once, stale files are
reported without deletion, and workspace-versus-standalone service keys retain
distinct history slots.


## Consequences

- Adding, removing, or moving workspace members and nodes changes one facade and
  one runner's evidence without changing the number of conformance packages.
- A consumer must deliberately expose one generated facade from its runtime
  library and add a stable project glob for generated package Cabal files.
- Existing unconfigured consumers retain byte-for-byte scaffold compatibility.
- Runtime package renames require an explicit workspace or CLI update and are
  visible in generated package provenance rather than silently rediscovered.
- Process, router, and workflow expectation changes are reviewable application
  decisions because the generator never replaces their accepted baseline.
- The text build manifest remains necessary when generated runtime modules or
  their dependencies change.


## Alternatives considered

**One package per member or node.** Rejected because members and nodes are
ownership units inside one checked service graph, not independent service
identities. The package count would churn as authors reorganized a service.

**Compile every runtime module in the conformance package.** Rejected because
generated modules depend on hand-owned application code and moving that closure
can create package cycles or duplicate the consumer's runtime build.

**Import every harness directly from the generated runner.** Rejected because
the runtime package would have to expose a growing set of internal modules and
the runner would become another hand-maintained inventory.

**Infer the runtime package.** Rejected because service and Cabal package names
need not match, and filesystem discovery would make output nondeterministic and
can choose incorrectly.

**Regenerate expected facts on every scaffold.** Rejected because comparing a
generated actual value with a generated expected value proves nothing and hides
behavior changes that require application review.

**Replace the text build manifest.** Rejected because the generated package
does not compile the runtime module closure; the runtime library still needs an
inventory of generated modules, dependencies, and Haskell compilation defaults.


## Related decisions

- [ADR 0014](0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)
  defines the workspace service as the durable whole-service identity and a
  standalone input as a one-member workspace.
- [ADR 0015](0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md)
  defines service-keyed history, detection-before-write atomicity, generated
  provenance, create-once ownership, and non-destructive stale handling.
- [ADR 0017](0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
  establishes the generated-versus-Hole ownership boundary that expectations
  preserve.
- [ADR 0019](0019-generated-haskell-has-an-explicit-edition-and-local-extension-contract.md)
  defines the GHC2024 plus `OverloadedStrings` baseline used by the facade and
  generated package.
- [ExecPlan 188](../plans/188-generate-one-runnable-conformance-package-per-keiro-dsl-service.md)
  implements this decision.
