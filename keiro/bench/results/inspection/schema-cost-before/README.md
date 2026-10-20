# Schema-verification allocation attribution

Five repetitions each warm ten calls, then measure 100 calls. The same store, durable database, inspection pool, and runtime process serve all cases. Median allocated bytes per call: point instance read 35,263; schema verifier 2,314,081; actual HTTP header 2,579,998. Median elapsed time is approximately 0.040 ms, 3.445 ms, and 3.527 ms respectively. These samples attribute most header allocation to schema verification; they do not establish whole-cohort interference or retention acceptance.

The binary uses the verifier at commit `d9960626`. Exact source hashes, build settings, and commands are retained in the manifest. The verifier scans live catalogs on every call; this probe introduces no cache or bypass.
