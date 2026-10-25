fresh-factory-statements-legacy-producer-lookup [0, 1000, 0]
replay-factory-statements-legacy-producer-lookup [0, 1000, 1000]
legacy-same-envelope-statements-legacy-producer-lookup [1000, 0, 0]

| Preparation for 1,000 events | median (ms) | range (ms) |
|---|---:|---:|
| legacy-actual-preparation | 5.747 | 5.039–5.848 |
| deterministic-equivalent-preparation | 1.082 | 1.021–1.116 |

| Prepared SQL inputs | transaction shape | legacy median (ms) | deterministic median (ms) | median paired ratio |
|---|---|---:|---:|---:|
| identical envelopes | one batch | 35.274 | 37.337 | 1.0732 |
| identical envelopes | one per event | 69.287 | 69.330 | 1.0051 |
| each path actual identity layout | one batch | 33.723 | 36.775 | 1.0905 |
| each path actual identity layout | one per event | 68.070 | 69.471 | 1.0191 |

PRODUCER_PROBE_ACCEPTED=true
