# Rejected single-array parameter experiment

Five allocation trials repeat the conditional-header prototype with all four input parameters in one nullable text array. It worsens conditional point-read allocation from 19.7 kB to 28.3 kB per call and conditional HTTP allocation from 53.2 kB to 61.9 kB. The experiment is rejected; the four typed parameters are restored.

The exact retained driver, source patch and hashes identify this measurement independently of the later source. Normal schema verification and exact row-image checks remain in every measured conditional request. The single-entry diagnostic seam reuses the canonical JSON value and encoded bytes. These are allocation attribution results, not writer interference acceptance.
