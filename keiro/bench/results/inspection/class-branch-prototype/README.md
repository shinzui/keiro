# Fixed-class branch prototype (not acceptance)

This disposable-clone experiment explores a generic-plan-safe key-order query.
Seven literal class branches share one bound class mask and page limit. PostgreSQL
can therefore constrain the class expression index even with a generic plan;
`UNION ALL` and ordered merge stop after the page lookahead. No planner switch
disables sequential scans. Both custom and generic plans are retained at 10,000
and 100,000 rows, with 90% owner skew and a 0.1% rare class.

The generic plans examine 22 workflow rows for all classes, 21 for running,
10/21 for rare failed at 10k/100k, and zero for absent retrying. All use index
scans. `summary.json` derives examined rows from scan rows plus removed rows,
multiplied by loops; full buffers, sorts, settings and timings remain in each raw plan.

The expression index exists only in each clone. This prototype is not the
supported library query and establishes neither write-cost nor API acceptance.
The write experiment must assess crash-counter HOT behavior before choosing
this index. Name/deep pages, complete fixture skew, detail-owner queries, and
manual time windows still need actual-API evidence.

Build the retained driver with `nix develop -c cabal exec -- ghc -O2
-threaded -rtsopts -XGHC2024 -package=keiro -package=keiro-test-support
driver.hs -o /tmp/keiro-class-branch-experiment`, then run it inside
`nix develop` with an output directory. Compiled execution used GHC 9.12.4,
PostgreSQL 18.6, the current Cabal plan and normal durable settings from
`withMigratedBenchmarkSuite`. The retained driver contains the exact SQL.
