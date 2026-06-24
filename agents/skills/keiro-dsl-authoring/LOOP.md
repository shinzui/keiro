# The authoring loop

Run everything from the repo root (`/Users/shinzui/Keikaku/bokuno/keiro`).

### 1. Write the spec

Author `service.keiro` in the notation (`NOTATION.md`). Start from `context <name>` and add
exactly the nodes the feature needs. Prefer the smallest spec that captures the decisions;
the deterministic boilerplate is derived, so don't hand-write it.

### 2. Parse (sanity)

```bash
cabal run keiro-dsl -- parse service.keiro
```

It echoes the spec pretty-printed. A parse error is line-numbered; fix the notation.

### 3. Check (the gate — before any Haskell)

```bash
cabal run keiro-dsl -- check service.keiro ; echo "exit=$?"
# add --emit to pretty-print the parsed spec on success (folds parse + check)
```

`OK` / exit 0 means every required decision is present and no dangerous inversion is stated
the wrong way. Any `error[Code]` (exit non-zero) names the rule and line — fix the spec, not
the generated code. Warnings (e.g. benign-inversion notices) are informational and pass.
Common rejections you must resolve in the spec:

- `StatusMapNotTotal`, `EvtVersionMissingUpcaster`, `ClockSampled`,
  `ProcessFireAtNotInjected`, `ProcessDispatchIdSupplied`, `*UnresolvedRef`/`*Unresolved*`,
  `Disposition*` (duplicate/previouslyFailed retry, decode unbounded retry, incomplete),
  `EmitSkipMissing`, `WqPhysicalDivergence`, `Wq*` inversions, `AwaitSignalMismatch`.

### 4. Scaffold (emit generated layer + holes)

```bash
cabal run keiro-dsl -- scaffold service.keiro --out gen/
```

You get `-- @generated` modules (overwritten every run) and create-if-absent hole modules
(`Holes.hs`, `ProcessHoles.hs`). **Re-scaffolding never clobbers a filled hole module.**

`scaffold` now checks its own firewall and prints a report to stderr: every module written
with its disposition (`overwritten`/`created`/`skipped: already present`), the firewall
verdict (`firewall: OK (N generated modules scanned, 0 forbidden operators)`), the harness
component(s) to run, and the manifest path. It **exits non-zero on a firewall breach**, so the
manual `grep` is no longer needed — a non-zero exit means a `-- @generated` module contains a
forbidden keiki operator (`./=`, `.==`, `.||`, `lit`, `B.slot`, `B.requireGuard`).

To place the generated layer next to your domain code instead of a parallel `Generated.*`
tree, pass `--module-root <Prefix>` and/or `--collocate` (or set `module <Prefix>` / `layout
collocated` in the spec): with both, modules land at `<Prefix>.<Ctx>.<Node>.Generated.*`. The
emitted `keiro-dsl-manifest.<context>.txt` carries paste-ready `other-modules:`/`build-depends:`
blocks for the consuming Cabal stanza.

### 5. Fill the holes

Open the hole modules. Each hole is a typed signature with a `-- HOLE …` annotation carrying
the spec decision to encode (e.g. `-- HOLE guard: divertStatus != TotalDivert || …`). Fill
the body against the **generated** names (the TH-produced `inCtor…`/`wire…`/`…TermFields`,
the `Keiro.Codec`, the `ProcessManager` wiring). Use the corpus
(`docs/corpus/keiro-dsl-corpus.md`) to see how a real spec's holes were filled. **Never edit
a `-- @generated` module** — change the `.keiro` and re-scaffold instead.

### 6. Run the harness (pin behaviour)

The scaffolder emits a harness (`Harness.hs` for aggregates; a facts harness for processes)
plus golden round-trips. Compile and run it (via the relevant `cabal test` component). It
asserts `validateTransducer == []`, codec round-trips, the disposition/time-injection/id
decisions, and a behavioural accept. A wrong fill turns a **specific** named test red. Green
harness = your fill matches the spec.

### 7. Diff (gate evolution over time)

When you later change the spec, gate the change against history:

```bash
cabal run keiro-dsl -- diff --since <git-ref> service.keiro ; echo "exit=$?"
```

`BREAKING` (exit non-zero) means an on-disk event payload could now fail to decode — add a
versioned event + `upcast from v(N-1) = HOLE`, or a `deprecated event`, until it reports
`ADDITIVE` (exit 0).
