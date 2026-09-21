set shell := ["zsh", "-cu"]

pg_host := env_var_or_default("PGHOST", "db")
pg_data := env_var_or_default("PGDATA", "db/db")
pg_log := env_var_or_default("PGLOG", "db/postgres.log")
pg_user := env_var_or_default("PGUSER", `whoami`)
pg_database := env_var_or_default("PGDATABASE", "keiro")
jitsurei_database := env_var_or_default("JITSUREI_DATABASE", "jitsurei")

[group('meta')]
default:
    just --list

[group('meta')]
verify: process-compose-check jitsurei haskell-verify adr-validate research-validate capabilities-validate reviews-validate user-documentation-validate terminology-validate extension-policy dsl-api-boundaries keiro-reexports record-migration-policy generated-name-policy conformance-corpus-policy process-reaction-proof replay-compatibility checked-mapping-adoption
    cabal test keiro-migrations-test

# Strict OKF enforcement for the architecture-decision bundle (docs/adr,
# registered as OKF bundle "adrs" in mori.dhall). Fails on any profile
# deviation, missing required/recommended frontmatter, malformed/duplicate
# docId, or stale log.md.
[group('docs')]
adr-validate:
    okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce

[group('meta')]
extension-policy:
    scripts/check-extension-policy.sh

[group('meta')]
dsl-api-boundaries:
    python3 scripts/check-keiro-dsl-api-boundaries.py

# A consumer of a generated service is expected to need one direct `keiro`
# dependency, but the scaffolder emits `keiro-core` imports as string literals,
# so nothing forces `keiro` to re-export a newly exposed module. The in-repo
# conformance suites depend on keiro-core directly and cannot catch it. This
# gap shipped in 0.7.0.0 and was caught only at the 0.18.0.0 release gate.
[group('meta')]
keiro-reexports:
    python3 scripts/check-keiro-reexports.py
    python3 -m unittest discover -s scripts/tests -p test_keiro_reexports.py

# Repository-only migration inventories and omission detectors. This policy
# identifies serialized surfaces for review; exact byte contracts live in the
# package test goldens.
[group('meta')]
record-migration-policy:
    python3 scripts/generate-record-migration-manifests.py --check

[group('meta')]
generated-name-policy:
    scripts/check-generated-name-policy.sh

[group('haskell')]
corpus-regen:
    cabal run -v0 keiro-dsl-corpus-regen -- regenerate

[group('meta')]
conformance-corpus-policy:
    scripts/check-conformance-corpus.sh

[group('meta')]
process-reaction-proof:
    bash keiro-dsl/test/process-reaction-mutation-test.sh
    bash keiro-dsl/test/process-hydration-test.sh

[group('meta')]
replay-compatibility:
    python3 scripts/check-replay-compatibility.py --baseline scripts/tests/fixtures/replay-compatibility/baseline-v1.json --candidate scripts/tests/fixtures/replay-compatibility/candidate-v1.json --inventory scripts/tests/fixtures/replay-compatibility/inventory-v1.json --require-all
    python3 -m unittest discover -s scripts/tests -p test_replay_compatibility.py
    python3 scripts/check-checked-mapping-release.py keiro-dsl/test/fixtures/checked-mapping-replay-workspace/release-manifest.json
    python3 -m unittest discover -s scripts/tests -p test_checked_mapping_release.py

[group('meta')]
checked-mapping-adoption:
    bash keiro-dsl/test/checked-mapping-adoption-test.sh

# Strict OKF enforcement for the research bundle (docs/research, registered as
# OKF bundle "research" in mori.dhall). Stable RES-N handles and review
# provenance follow the shared documentation.researchDocuments profile.
[group('docs')]
research-validate:
    okf validate docs/research --strict --profile docs/research/profile.dhall --profile-enforce --log-enforce

# Not `--strict`: the records are machine-authored and carry no `reviews` family,
# which `--strict` would report. Enforces the shared coordination.capabilities
# profile and the log for the "capabilities" bundle registered in mori.dhall, and
# checks that every `requires` is mirrored as a graph edge.
[group('docs')]
capabilities-validate:
    okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
    okf graph docs/capabilities

# Strict OKF enforcement for the assurance.reviews bundle. Every record names
# one exact subject and immutable reviewed commit; findings remain in the review
# body until the owning bug-report profile is adopted.
[group('docs')]
reviews-validate:
    okf validate docs/reviews --strict --profile docs/reviews/profile.dhall --profile-enforce --log-enforce

# Strict OKF enforcement for user-facing documentation. Both bundles share the
# published documentation.userDocumentation profile while retaining independent
# DOC-N handle namespaces and change logs.
[group('docs')]
user-documentation-validate:
    okf validate docs/user --strict --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce
    okf graph docs/user
    okf validate docs/guides --strict --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce
    okf graph docs/guides

# Strict OKF enforcement for the published controlled vocabulary, then Mori's
# repository gate: relation resolution, replaces/replacedBy mirrors, discouraged
# wording, and file/doc/module anchors against this checkout.
[group('docs')]
terminology-validate:
    okf validate docs/terminology --strict --profile mori/terminology-profile.dhall --profile-enforce --log-enforce
    mori terms validate --path .

[group('haskell')]
haskell-build:
    cabal build all

[group('haskell')]
haskell-test:
    cabal test keiro-test
    cabal test keiro-pgmq-test
    cabal test keiro-ops-test
    # `<package>:tests`, not `<package>`. A bare package name resolves to a
    # single component, so `cabal test keiro-dsl` ran only keiro-dsl-test and
    # silently skipped the other 37 suites — the conformance corpus compiled
    # under `cabal build all` but never had its assertions run. The `:tests`
    # target expands to every declared test-suite, so adding one is enough to
    # get it run. keiro, keiro-pgmq, and jitsurei each declare exactly one.
    cabal test keiro-dsl:tests
    cabal test jitsurei-test
    cabal run jitsurei:exe:jitsurei-diagrams -- --check

# Manual/local benchmark guard. The committed baseline reflects the primary
# dev machine; this is deliberately not wired into verify/CI. Cabal runs the
# benchmark from the keiro package directory, so the baseline path is
# package-relative.
[group('haskell')]
bench-regression:
    cabal bench keiro-bench --benchmark-options="-p producer-identity -j1 --time-mode wall --hide-progress --stdev 1 --timeout 120s +RTS -N2 -RTS"
    cabal bench keiro-bench --benchmark-options="-p outbox --time-mode wall --baseline bench/baseline-outbox.csv --fail-if-slower 25"
    cabal bench keiro-bench --benchmark-options="-p inbox --time-mode wall --baseline bench/baseline-inbox.csv --fail-if-slower 25"
    cabal bench keiro-bench --benchmark-options="-p command --time-mode wall --hide-progress --baseline bench/baseline-command.csv --fail-if-slower 25"
    KEIRO_READ_MODEL_P95=1 cabal bench keiro-bench --benchmark-options="-p projection --time-mode wall --hide-progress --timeout 1 --baseline bench/baseline-projection.csv --fail-if-slower 25"
    cabal bench keiro-bench --benchmark-options="-p read-model --time-mode wall --hide-progress --timeout 1 --baseline bench/baseline-read-model.csv --fail-if-slower 25"

[group('haskell')]
haskell-verify: haskell-build haskell-test

[group('database')]
postgres-init:
    mkdir -p "{{pg_host}}" .dev
    if [ ! -d "{{pg_data}}" ]; then PGDATA="{{pg_data}}" initdb --auth=trust --no-locale --encoding=UTF8; fi

[group('database')]
postgres-start: postgres-init
    pg_ctl status -D "{{pg_data}}" >/dev/null || pg_ctl start -w -D "{{pg_data}}" -l "{{pg_log}}" -o "--unix_socket_directories='{{pg_host}}'" -o "-c listen_addresses=''"

[group('database')]
postgres-stop:
    pg_ctl stop -D "{{pg_data}}"

[group('database')]
process-compose:
    PGHOST="{{pg_host}}" PGDATA="{{pg_data}}" PGLOG="{{pg_log}}" PGUSER="{{pg_user}}" PGDATABASE="{{pg_database}}" JITSUREI_DATABASE="{{jitsurei_database}}" process-compose up -f process-compose.yaml

[group('database')]
process-compose-check:
    PGHOST="{{pg_host}}" PGDATA="{{pg_data}}" PGLOG="{{pg_log}}" PGUSER="{{pg_user}}" PGDATABASE="{{pg_database}}" JITSUREI_DATABASE="{{jitsurei_database}}" process-compose -f process-compose.yaml --dry-run

[group('database')]
create-database db=pg_database:
    PGHOST="{{pg_host}}" createdb "{{db}}" 2>/dev/null || PGHOST="{{pg_host}}" psql -d "{{db}}" -Atqc 'SELECT 1' >/dev/null

[group('database')]
db-create db=pg_database: postgres-start
    just create-database "{{db}}"

[group('jitsurei')]
jitsurei-db-create:
    just db-create "{{jitsurei_database}}"

[group('jitsurei')]
jitsurei-migrate: jitsurei-db-create
    cabal run keiro-migrate -- up --database-url "host={{pg_host}} dbname={{jitsurei_database}} user={{pg_user}}"

[group('jitsurei')]
jitsurei-fulfillment: jitsurei-migrate
    PGHOST="{{pg_host}}" PGDATABASE="{{jitsurei_database}}" PG_CONNECTION_STRING="host={{pg_host}} dbname={{jitsurei_database}} user={{pg_user}}" cabal run jitsurei-demo

[group('jitsurei')]
jitsurei-paging: jitsurei-migrate
    PGHOST="{{pg_host}}" PGDATABASE="{{jitsurei_database}}" PG_CONNECTION_STRING="host={{pg_host}} dbname={{jitsurei_database}} user={{pg_user}}" cabal run jitsurei-demo -- paging

[group('jitsurei')]
jitsurei-snapshots: jitsurei-migrate
    PGHOST="{{pg_host}}" PGDATABASE="{{jitsurei_database}}" PG_CONNECTION_STRING="host={{pg_host}} dbname={{jitsurei_database}} user={{pg_user}}" cabal run jitsurei-demo -- snapshots

[group('jitsurei')]
jitsurei-escalation: jitsurei-migrate
    PGHOST="{{pg_host}}" PGDATABASE="{{jitsurei_database}}" PG_CONNECTION_STRING="host={{pg_host}} dbname={{jitsurei_database}} user={{pg_user}}" cabal run jitsurei-demo -- escalation

[group('jitsurei')]
jitsurei-agent-qual: jitsurei-migrate
    PGHOST="{{pg_host}}" PGDATABASE="{{jitsurei_database}}" PG_CONNECTION_STRING="host={{pg_host}} dbname={{jitsurei_database}} user={{pg_user}}" cabal run jitsurei-demo -- agent-qual

[group('jitsurei')]
jitsurei-workflow: jitsurei-migrate
    PGHOST="{{pg_host}}" PGDATABASE="{{jitsurei_database}}" PG_CONNECTION_STRING="host={{pg_host}} dbname={{jitsurei_database}} user={{pg_user}}" cabal run jitsurei-demo -- workflow

[group('jitsurei')]
jitsurei-all: jitsurei-migrate
    PGHOST="{{pg_host}}" PGDATABASE="{{jitsurei_database}}" PG_CONNECTION_STRING="host={{pg_host}} dbname={{jitsurei_database}} user={{pg_user}}" cabal run jitsurei-demo -- all

[group('jitsurei')]
jitsurei: jitsurei-all
