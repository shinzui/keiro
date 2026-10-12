# Keiro Agent Instructions

## Use the Nix development shell for verification

Run builds, tests, and repository verification in the project's Nix development
shell, even when GHC, Cabal, and PostgreSQL are already available on the host.
Their presence does not prove that the full test environment is available.

Z3 is required by the DSL symbolic conformance tests and is already included in
`flake.module.nix` through `haskellProject.extraDevPackages`. Before running
those tests, verify `nix develop -c z3 --version`. Use commands such as:

```bash
nix develop -c cabal build all --enable-tests --enable-benchmarks
nix develop -c cabal test keiro-dsl:tests --test-show-details=direct
nix develop -c just verify
```

Commands may run directly after entering `nix develop`; check `z3 --version`
inside that shell. If a symbolic test fails, check the shell and solver before
changing assertions or dependency bounds.
