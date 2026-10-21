# Pending timer read evidence

The driver calls public `findPendingTimers` with a one-connection read pool,
then captures that API's actual Hasql statement from `pg_prepared_statements`.
`plans.json` retains 72 full EXPLAIN ANALYZE/BUFFERS/SETTINGS plans for 10k/100k
rows, four filter shapes with hot/rare/absent variants, first/deep cursors, and
forced custom/generic plans. PostgreSQL durability and normal autovacuum are
recorded and asserted. No experimental index is installed in these fixtures.

At 100k rows, the generic-plan samples range from 0.038 to 15.785 ms. Broad
shapes scan/sort pending rows. Those are observations, not a claim of bounded
search cost or passing writer interference. We retain existing timer indexes:
M0's faster correlation indexes reject valid writer keys, and an additional
global index incurs write maintenance. Manual pages remain deadline-bound.
Automatic timer refresh must stay within the measured 100k-row envelope and
refresh each shared view no more than once per five seconds; EP-5/EP-7 own that
admission and composed writer-interference proof. Larger ledgers need fresh
evidence. No blanket latency target applies to the inspection read itself.

Rebuild with the repository Nix shell and the library dependency response file,
`ghc -fforce-recomp -threaded -rtsopts -O2`, then run the driver with an output
JSON path and `+RTS -N2 -RTS`. `driver.hs.txt` is the retained compiler input.
