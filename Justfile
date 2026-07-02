set shell := ["zsh", "-cu"]

site := "site-dist"
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
verify: process-compose-check jitsurei haskell-verify
    cabal test keiro-migrations-test

[group('website')]
install:
    pnpm install --frozen-lockfile

[group('website')]
website-build:
    BUNDLE_PRAGMATA_PRO=1 pnpm run build

[group('website')]
website-dev:
    BUNDLE_PRAGMATA_PRO=1 pnpm run dev

[group('website')]
website-preview:
    BUNDLE_PRAGMATA_PRO=1 pnpm run preview

[group('website')]
website-linkcheck:
    node site/check-links.mjs {{site}}

[group('website')]
website-verify: install website-build website-linkcheck

[group('haskell')]
haskell-build:
    cabal build all

[group('haskell')]
haskell-test:
    cabal test keiro-test
    cabal test keiro-pgmq-test
    cabal test jitsurei-test
    cabal run jitsurei:exe:jitsurei-diagrams -- --check

# Manual/local benchmark guard. The committed baseline reflects the primary
# dev machine; this is deliberately not wired into verify/CI. Cabal runs the
# benchmark from the keiro package directory, so the baseline path is
# package-relative.
[group('haskell')]
bench-regression:
    cabal bench keiro-bench --benchmark-options="-p outbox --time-mode wall --baseline bench/baseline-outbox.csv --fail-if-slower 25"
    cabal bench keiro-bench --benchmark-options="-p inbox --time-mode wall --baseline bench/baseline-inbox.csv --fail-if-slower 25"

[group('haskell')]
haskell-verify: haskell-build haskell-test website-verify

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
    mkdir -p .dev/codd-expected-schema
    KEIRO_MIGRATE_NO_CHECK=1 CODD_CONNECTION="host={{pg_host}} dbname={{jitsurei_database}} user={{pg_user}}" CODD_MIGRATION_DIRS=unused-for-embedded-migrations CODD_EXPECTED_SCHEMA_DIR=.dev/codd-expected-schema CODD_SCHEMAS=kiroku cabal run keiro-migrate

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
