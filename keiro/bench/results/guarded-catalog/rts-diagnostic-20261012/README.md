# RTS diagnostic

One original/current ordinary sample each with identical workload, fresh databases,
and `+RTS -N2 -s -RTS`, using the executables identified by
`../candidate-20261012/environment.json`. This is a diagnostic, not five-pair
acceptance. Shared-host builds remained active.

Original/current heap allocation is 2,382,670,576/2,362,643,872 bytes; measured
workload time is 26.319418/12.587346 seconds. The single pair does not reproduce
the initial slowdown, but neither proves acceptance nor isolates its cause.

A second diagnostic repeats the failed eight-connection/four-event/paused-worker
configuration (`batch4-*`). Original/current allocation is
3,245,478,168/3,245,877,264 bytes; mutator CPU is 3.680/3.674 seconds and measured
workload time is 6.644878/6.564350 seconds. This one pair also does not reproduce
the fixed-budget failure. Neither diagnostic establishes acceptance.
