# Pool timer attribution: temporary roots and a shared buffer step

Two pooled and two direct-connection probes run in separate durable fixtures and
processes, ordered pooled/direct/direct/pooled. Each issues SELECT 1 at 200/s for
60 seconds, samples after a major GC every five seconds, and samples again after
a twelve-second drain. The pool's default acquisition timeout stays unchanged.

Pooled live bytes rise from about 150 kB into a roughly 420 kB band during
timer warmup. Both direct controls stay in a roughly 214 kB band initially.
Around 35 seconds every mode also takes a 32 KiB large-object step. Final pooled
live bytes are about 455 kB, falling to 213 kB after the drain; direct controls
end near 245 kB and fall to 149 kB. Raw byte counts, rather than these rounded
labels, are authoritative.

The complete 20–60 second fit is still positive in every leg (about 4.8–5.1
bytes/op) because it spans that shared step. Do not call this a strict retention
pass or subtract the control's growth to manufacture one. Extend the observation
window and retain the raw late samples before judging a persistent trend.
This probe only attributes timer lifetime; it does not measure domain workers,
HTTP mounting, subscription churn, or the complete cohort matrix.

The released hasql-pool 1.4.2.3 source registers an acquisition timer on every
Pool.use, including immediate acquisition, with a ten-second default. The Mori
source project is mori://hasql/hasql, with local project-relative sources
hasql-pool/src/library/exposed/Hasql/Pool.hs and
hasql-pool/src/library/exposed/Hasql/Pool/Config/Defaults.hs; artifact-level
source URIs are pending. The exact release archive was also inspected (its
Pool.hs path is src/library/Hasql/Pool.hs). No dependency or runtime timeout
policy changed.
