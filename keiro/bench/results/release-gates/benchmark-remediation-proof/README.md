# Benchmark remediation proof

The name listings are byte-identical. The selected tracer fixture closes before
the historical legacy case starts; both selected cases pass and retain their
work-count checks. Listing/filtering does not acquire tracing fixtures.

Acceptance controls cover common environment drift, actual added candidate cost,
ambiguous/missing confirmations, corrupt or stale cached measurements, invalid
CSV data, preserved within-run controls and benchmark execution failures.
Whole-run tests preserve historical CSV bytes and reject a deliberately 60% more
expensive candidate after retaining both opposite-order confirmations. The
release-driver control refuses reuse after supplementary measurement tampering.

The real first command family comparison passes all 15 required workloads;
ratios range 0.918–1.139 against original recording source on this machine.
See the adjacent `benchmark-remediation-command-1` evidence. Historical CSVs,
workload quantities, RTS settings and numerical ceilings are unchanged.
