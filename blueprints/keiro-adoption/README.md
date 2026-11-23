# Adopt the Keiro runtime and DSL

Run this blueprint in each consumer checkout. It verifies the actual Keiro
runtime and generator, crosses any required upgrade window, and prepares
a project-specific MasterPlan and child ExecPlans from the
[Keiro DSL adoption guide](mori://shinzui/keiro-runtime-patterns/docs/keiro-dsl-adoption).
Adoption starts from a released Keiro cohort at 0.26.0.0 or newer.

After publication, install the blueprint and its companion audit from Keiro:

```sh
seihou install https://github.com/shinzui/keiro.git --module keiro-adoption
seihou install https://github.com/shinzui/keiro.git --module domain-scalar-identity-decoder-audit
```

Run `prepare` (the default) to verify or upgrade the cohort, write or reconcile
the plans, and classify the domain audit baseline. Run `implement` to resume
and execute the plans through integrated verification and final audit closure.

```sh
seihou agent run keiro-adoption --var adoption.mode=prepare
seihou agent run keiro-adoption --var adoption.mode=implement
```

Use an authenticated local agent provider with access to the consumer
development environment. When the dependency window needs migration, install
[keiro-upgrade](../keiro-upgrade/README.md) and the entailed blueprint artifacts
for that window using their owning registries. The adoption agent previews
the edge order and runs the migration. The latest audit blueprint in this
registry provides the classification-only mode. A rerun uses the existing
plans, source-bound evidence and applied migration receipts.

For an unpublished local checkout, run from the consumer and name that checkout
as the source of the companion blueprints as well:

```sh
keiro_checkout="$(mori path mori://shinzui/keiro | tail -n 1)"
seihou agent run "$keiro_checkout/blueprints/keiro-adoption" \
  "Use the companion blueprints in $keiro_checkout/blueprints." \
  --var adoption.mode=prepare
```

Any entailed upgrade artifacts still resolve by their installed names. Run
prompt previews in a disposable checkout because some Seihou versions
record preview receipts.

Maintainer checks from the Keiro checkout:

```sh
nix develop -c seihou validate-blueprint blueprints/keiro-adoption --lint
nix develop -c seihou validate-blueprint blueprints/domain-scalar-identity-decoder-audit --lint
nix develop -c seihou registry validate
```
