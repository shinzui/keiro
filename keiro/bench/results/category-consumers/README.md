# Category-consumer allocation probe

Plan 324 was implemented from `5897f222`. The user requested focused performance
verification and excluded DSL conformance. This store-free probe uses the actual
`prepareConsumers` and HTTP bounded encoder, with 1,000 consumers, two subscriptions
each, and a 500-item first page. It forces `OpsResult` as the HTTP outcome does,
then consumes the direct bytes. Canonical JSON is forced separately afterward.

Reproduce from the repository root in the Nix shell:

```bash
nix develop -c cabal build keiro-ops keiro-ops-http --enable-tests
nix develop -c cabal exec -- ghc -O2 -threaded -rtsopts -package keiro -package keiro-ops -package keiro-ops-http keiro/bench/results/category-consumers/Profile.hs -outputdir /tmp/keiro-324-profile-build -o /tmp/keiro-324-profile
nix develop -c /tmp/keiro-324-profile +RTS -N2 -T -RTS
```

The probe was compiled with GHC 9.12.4 and `-O2`; Cabal's libraries used the
project's `-O1` profile. `getAllocationCounter` measures current-thread allocation,
with a major collection before each section. The retained output is in
[allocation-profile.log](allocation-profile.log).

The registry allocated 8,471,608 bytes to construct and digest 2,000 descriptions.
The maximum page encoded to 222,221 bytes and allocated 6,515,320 bytes through
the direct path. Its encoded body fits the host's 1,048,576-byte response cap. Forcing the unused
canonical value and generic encoding afterward allocated another 8,996,336 bytes;
this is additional work on an already prepared page, not a separate full-path
baseline. Decoding the direct bytes equals the canonical value.

The 500-item ceiling is retained as a finite page bound. These figures characterize
this fixture; names, scopes and binding cardinality affect cost. There is no claimed
polling-rate envelope, writer-latency guarantee, or statistical regression result.
The user explicitly replaced the plan's paired-cohort and retention campaign with
focused verification. Existing HTTP tests retain schema/admission/deadline/byte-cap
policies, including rejection of a single oversized item.

Runtime library scope is additive: the only existing implementation file changed
is `Keiro.Projection.Catalog.Operations`, which gains new declarations/imports/exports;
`Keiro.Inspection.Consumers` is new. Catalog validation, per-event paths, the SQL status
relation, and production HTTP transport source are unchanged.
