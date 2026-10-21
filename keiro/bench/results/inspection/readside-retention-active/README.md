# Final read-side active-view heap probe

Runtime candidate 5893c7eb uses read-side workflow classes, the published writer
schema, strict server connection-registry updates, and a strict heap counter.
The probe drives 32 canonical views / 256 socket clients plus repeated HTTP
polls for 60 seconds at 100 writer operations/second over 100k workflow/timer
ledgers. It records post-major samples every 500 operations, then client cleanup
and a 12-second drain for acquisition-timeout bookkeeping. Repository
verification overlapped this ownership probe; its timing fields are not latency
acceptance.

All feed views/connections/wake pump return to zero. Active threads return to
18 (the starting count). Post-cleanup live heap is 1,598,904 bytes, versus about
10.6 MB in the earlier runner with lazy ownership-map updates. The server and
bounded header/schema caches remain mounted. During load, network connection
buffers and in-flight reads make individual live samples variable; cleanup and
repeated steady-state evidence are considered separately from those peaks.
