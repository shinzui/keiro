# Superseded diagnostic heap probes

These short probes used the original benchmark's shared operation enumeration.
The pre-change 120-second control reproduced its approximately 40 B/operation
retention, traced in optimized Core to the list floated outside all trial/mode
callbacks. These samples are not heap acceptance evidence. They remain here
with client codes and cleanup observations to preserve the diagnosis.

The benchmark's heap branch now uses a strict recursive counter. See
../composed-retention-controls/ for ownership evidence and
../composed-feed-retention-corrected/ for corrected measurements. No product
runtime code changed as part of that correction.
