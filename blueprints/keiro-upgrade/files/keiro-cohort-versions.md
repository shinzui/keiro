# Keiro release cohort map

Which upstream releases each Keiro version pairs with. Keiro's eight published
packages share one version and are released together, so a row describes the
whole set.

Use this to answer "what else moves when I move Keiro?" — not to decide what to
edit. What to edit is in the edge prompt.

| Keiro | `kiroku-store` | `kiroku-store-migrations` | `keiki` | `shibuya-core` |
|---|---|---|---|---|
| 0.22.0.0 | `^>=0.12.0.0` | `^>=0.7.2.0` | `>=0.9 && <0.10` | `^>=0.12.0.0` |
| 0.21.0.0 | `^>=0.11.0.0` | `^>=0.7.1.0` | `>=0.9 && <0.10` | `^>=0.10.0.1` |
| 0.20.0.0 | `^>=0.11.0.0` | `^>=0.7.1.0` | `>=0.9 && <0.10` | `^>=0.10.0.1` |
| 0.19.0.1 | `>=0.9.0.1 && <0.10` | `^>=0.6.0.0` | `>=0.9 && <0.10` | `^>=0.10.0.0` |
| 0.19.0.0 | `>=0.9.0.1 && <0.10` | `^>=0.6.0.0` | `>=0.9 && <0.10` | `^>=0.10.0.0` |
| 0.18.0.0 | `>=0.8 && <0.9` | `^>=0.4.0.0` | `>=0.9 && <0.10` | `^>=0.9.0.0` |
| 0.17.0.0 | `>=0.8 && <0.9` | `^>=0.4.0.0` | `>=0.9 && <0.10` | `^>=0.9.0.0` |
| 0.16.0.0 | `>=0.8 && <0.9` | `^>=0.4.0.0` | `>=0.9 && <0.10` | `^>=0.9.0.0` |
| 0.15.0.0 | `>=0.8 && <0.9` | `^>=0.4.0.0` | `>=0.9 && <0.10` | `^>=0.9.0.0` |
| 0.14.0.0 | `>=0.8 && <0.9` | `^>=0.4.0.0` | `>=0.9 && <0.10` | `^>=0.9.0.0` |
| 0.13.0.0 | `>=0.8 && <0.9` | `^>=0.4.0.0` | `>=0.9 && <0.10` | `^>=0.9.0.0` |
| 0.12.0.0 | `>=0.7 && <0.8` | `^>=0.3.2.0` | `>=0.9 && <0.10` | `^>=0.9.0.0` |
| 0.11.0.0 | `>=0.7 && <0.8` | `^>=0.3.1.0` | `>=0.8 && <0.9` | `^>=0.9.0.0` |

Keiro 0.17.0.0 and 0.18.0.0 also require the pgmq 0.6 package family and
`shibuya-pgmq-adapter` 0.16.0.0. Those packages are outside the stable substrate columns above;
the 0.16.0.0 → 0.17.0.0 edge describes the source adaptations they introduce. 0.18.0.0 moves no
upstream cohort member.

Keiro 0.19.0.0 requires `shibuya-pgmq-adapter` 0.16.1.0 (the release on Shibuya 0.10), the
`pg-migrate` 1.2 family, and, where a project uses it, `pgmq-migration >=0.6.1.1`, the first
release that accepts `pg-migrate` 1.2. A project on the Kiroku adapter needs
`shibuya-kiroku-adapter` 0.5.1.5 or later; no earlier release pairs Shibuya 0.10 with Kiroku 0.9.

Keiro 0.20.0.0 requires the queue family `>=0.6.1.1 && <0.7`, retaining
`shibuya-pgmq-adapter ^>=0.16.1.0`, and requires
`shibuya-kiroku-adapter ^>=0.6.0.1` where used. Its edge entails the
hardening and inspection upgrades from mori://shinzui/kiroku in order, covering
validated subscription configuration, typed decoding, target binding and
migrations 0013–0015. Keiro's composed plan contains 47 migrations.

Keiro 0.21.0.0 retains the 0.20.0.0 upstream cohort and composed migration plan.
Its edge covers DSL source API adaptations and generated-code regeneration;
Language 6 remains a candidate and no database ledger fixup is required.

Keiro 0.22.0.0 requires adapter `^>=0.18.0.0` from
mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter and the PGMQ
family `>=0.7.0.0 && <0.8` from mori://shinzui/pgmq-hs. Where used, Kiroku's
Shibuya adapter is `^>=0.7.0.0` and metrics is `^>=0.4.0.0`. The entailed
Kiroku 0.11.0.1 → 0.12.0.0 edge covers stopped-worker migration 0016 and
namespace bindings. The framework plan contains 48 migrations; separately
composed PGMQ adds its own migration 0007. Language 6 remains candidate.

From 0.18.0.0, `keiro-test-support` requires `ephemeral-pg >=0.3.1 && <0.4`. That is a test-only
dependency, but `pg-migrate-test-support 1.1.0.0` still caps it below 0.3, so a build plan holding
both needs `allow-newer: pg-migrate-test-support:ephemeral-pg`. The 0.17.0.0 → 0.18.0.0 edge
covers it. From 0.19.0.0, `pg-migrate-test-support` 1.2 accepts `ephemeral-pg` 0.3 and the
exception is removed; the 0.18.0.0 → 0.19.0.0 edge covers that too.

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
