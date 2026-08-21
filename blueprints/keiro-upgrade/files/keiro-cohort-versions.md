# Keiro release cohort map

Which upstream releases each Keiro version pairs with. Keiro's six published
packages share one version and are released together, so a row describes the
whole set.

Use this to answer "what else moves when I move Keiro?" — not to decide what to
edit. What to edit is in the edge prompt.

| Keiro | `kiroku-store` | `kiroku-store-migrations` | `keiki` | `shibuya-core` |
|---|---|---|---|---|
| 0.14.0.0 | `>=0.8 && <0.9` | `^>=0.4.0.0` | `>=0.9 && <0.10` | `^>=0.9.0.0` |
| 0.13.0.0 | `>=0.8 && <0.9` | `^>=0.4.0.0` | `>=0.9 && <0.10` | `^>=0.9.0.0` |
| 0.12.0.0 | `>=0.7 && <0.8` | `^>=0.3.2.0` | `>=0.9 && <0.10` | `^>=0.9.0.0` |
| 0.11.0.0 | `>=0.7 && <0.8` | `^>=0.3.1.0` | `>=0.8 && <0.9` | `^>=0.9.0.0` |

Bounds are what the published `.cabal` files declare, not the exact versions a
given project resolved. To read what *this* project actually resolved, prefer
its own build plan:

```sh
jq -r '."install-plan"[] | select(."pkg-name"=="kiroku-store") | ."pkg-version"' \
  dist-newstyle/cache/plan.json | sort -u
```

## Deprecated upstream releases

Some releases in this table's history are deprecated on Hackage and must not be
resolved:

- **`kiroku-store-migrations` 0.3.2.0 and 0.3.2.1.** Their payload of migration
  `0010` cannot be applied on PostgreSQL 17 outside a bootstrap session. Superseded
  by 0.4.0.0, which corrects the payload and adds converging migration `0011`.
  Moving off them changes a recorded checksum; see the `kiroku-upgrade` edge that
  the Keiro 0.12.0.0 → 0.13.0.0 edge entails.

## PostgreSQL versions

Keiro's own test suites run on **PostgreSQL 18** only. Kiroku runs acceptance
shells on **17 and 18**. A project deploying on PostgreSQL 17 should treat
Kiroku's 17 coverage as the authority for anything in the `kiroku` schema, and
should not assume Keiro's suites would have caught a 17-specific defect — the
`0010` payload bug is exactly one that they did not.
