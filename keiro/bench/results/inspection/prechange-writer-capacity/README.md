# Pre-change burst-capacity qualification

The shared writer source compiled against commit `3bf3ac229f21d6c95179ce49b5e8f6323322f99b` completes 644–690 operations/second over five unmounted, unpaced 1,000-operation legs. All common dependency units match the candidate. The predeclared 75%-of-minimum rule proposes 480/s; the paced check then rejects 480/s and accepts 380/s. Burst throughput alone does not prove headroom. See `matched-http-qualified/` for the paced qualifications and comparisons.
