# Functional mixed-feed smoke

This normal (non-retention) 20-second run checks the read-side workflow queries
through the composed server with 32 views and 256 clients. It overlapped full
repository verification and is not latency acceptance or heap-stability
evidence. All clients obtained initial snapshots; updates and bounded
inspection_busy refusals are recorded in the log. Feed resources returned to
zero. Dedicated retention and final matched interference evidence follow.
