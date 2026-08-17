# keiro-upgrade

> Agent-guided upgrade guidance for projects consuming Keiro, published as one
> edge per released version window that needs judgement work. Upstream cohort
> edges are **entailed**, so a project that depends only on Keiro — and has never
> heard of Kiroku — still crosses Kiroku's edges, exactly once, in the right
> order.

**Version:** `0.1.0`

**Kind:** Blueprint migration (run with `seihou agent migrate`, not
`seihou agent run` — this blueprint declares no baseline and applies no modules)

## For consumers

Bump the Keiro dependency first, then migrate the source up to it:

```sh
seihou install https://github.com/shinzui/keiro.git   --module keiro-upgrade
seihou install https://github.com/shinzui/kiroku.git  --module kiroku-upgrade

seihou agent --debug migrate keiro-upgrade --from 0.12.0.0   # preview
seihou agent migrate keiro-upgrade --from 0.12.0.0           # run
```

`--to` is inferred from the [version probe](#version-probe); `--from` is
inferred from your recorded receipts after the first run. The entailed
`kiroku-upgrade` blueprint **must be installed** — a run that cannot resolve it
refuses rather than silently skipping a cohort member, because a half-migrated
project with no signal is worse than a stopped one.

Start from a clean working tree. Agent edits are not transactional and Seihou
cannot roll them back; version control is the undo.

## Declared edges

| From | To | Entails |
|---|---|---|
| `0.12.0.0` | `0.13.0.0` | `kiroku-upgrade` `0.7.0.1 -> 0.8.0.0` |

Gaps between edges are deliberate and legal: they mean no agent intervention was
needed in that interval. Edges are append-only — an edge stays correct for as
long as the release it describes exists, which is why this blueprint does not go
stale the way a single "migrate to the current cohort" document does.

## Version probe

```
jq -r '."install-plan"[] | select(."pkg-name"=="keiro") | ."pkg-version"' \
  dist-newstyle/cache/plan.json 2>/dev/null | sort -u | tail -1 | grep .
```

Read-only, fast, and honest: it reports the version this project's **build plan**
actually resolved, not a bound. It requires a configured Cabal build — a project
that has not run `cabal build`/`configure`, or that has no `jq`, gets a warning
and is asked for `--to`. That is the intended degradation. A probe that guessed
would be worse than none, because a window off by one release runs the wrong
edges against real source.

## Reference files

Mounted read-only for every edge of this blueprint:

- `files/keiro-cohort-versions.md` — which upstream cohort each Keiro release
  pairs with, how to read what a project actually resolved, deprecated upstream
  releases, and which PostgreSQL majors each layer of the stack covers.

## For maintainers

**Add an edge in the same change that cuts a release**, or this blueprint rots.
The failure mode is not hypothetical: `migrate-keiro-stack` in `agent-seihou`
still pins `kiroku-store 0.3.1.0` because it describes "the current cohort"
rather than a sequence of edges, and nothing forced it forward. See the release
skill (`agents/skills/release/SKILL.md`), which carries this as a step.

When a release absorbs an upstream breaking change, declare the exact upstream
edge in `entails` rather than copying that library's guidance into this
repository. The rules that are not visible from the field's type:

- Entailed edges run **first**, and several run in declaration order.
- Expansion is **recursive**; a cycle is an authoring error.
- The reference is to **one exact edge**, matched on both `from` and `to`. Seihou
  will not window-plan inside the entailed blueprint, because that would let a
  Keiro release silently change which upstream work it implies.
- The receipt is filed under the **entailed** blueprint's identity, which is what
  makes a shared edge crossed once from either entry point.
- The entailed blueprint's own `launch` declaration is ignored; provider, model,
  and effort stay a property of the command.

Write each edge's precondition explicitly. One blueprint serves projects in very
different states, and an edge that does not apply is a normal result — Seihou
records it as *not applicable* and plans it again later, rather than marking it
done. Never tell an edge to exit nonzero when it does not apply: that reports a
provider failure and halts every remaining edge.

Validate before publishing:

```sh
seihou validate-blueprint blueprints/keiro-upgrade
```

Validation checks everything resolvable without a filesystem search. Whether the
entailed blueprint exists and declares the named edge is resolved by
`seihou agent migrate`, so preview a real chain before shipping an edge that
entails one:

```sh
seihou agent --debug migrate keiro-upgrade --from <prev> --to <next>
```
