# Longer pool timer attribution

Two fresh-process controls extend the earlier 60-second SELECT-1 probe to 180 seconds at 200 queries/second, followed by 12 seconds of drain. This tests whether the shared 32 KiB large-object step near 35 seconds continues growing. Normal durable PostgreSQL settings and the released pool's default ten-second acquisition timeout remain unchanged.

The direct control stays near 246 kB and the pooled control near 455 kB over 60..180 seconds. The pooled drain falls to about 213 kB. Consult the raw samples and fitted slopes in summary.json: small fluctuations are retained, not rounded into a strict pass. The 32 KiB step does not repeat during this observation window. This supports finite timer/buffer warm-up attribution; it does not replace strict domain-worker or active-inspection retention runs and does not establish a cohort pass.

The retained driver is unchanged from the prior probe. The runner and manifest record duration, execution order, binary/source hashes and build settings. No dependency source, pool timeout or ordinary runtime policy was changed.
