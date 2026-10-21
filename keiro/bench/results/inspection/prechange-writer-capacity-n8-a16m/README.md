# Eight-capability pre-change writer capacity

Five fresh durable fixtures use the pre-implementation runtime and the exact shared driver retained here. Both the capacity and upcoming matched profile use GHC 9.12.4, project libraries O1, the driver O2 and RTS -N8 -A16m -T on this 36-logical-CPU / 256-GiB Mac. Other host work is permitted; no exclusive environment is required.

The 100,000-row fixture is analyzed and explicitly checkpointed before the common 50-operation writer warm-up. This finishes setup dirty-page writes before sampling; autovacuum and normal durable settings remain enabled. The five saturation results are retained with raw phase samples and counters. Their minimum selects a proposed fixed offered load of 580/s using the declared 75%-then-round-down rule. Paced qualification must still establish headroom; capacity alone is not a comparison or gate pass.

The manifest hashes the binary and exact retained driver/runner, and records the complete invocation. The matched controller refuses different capacity driver hashes, baseline binary hashes or RTS settings. This is a separate profile from the retained N2 experiments.
