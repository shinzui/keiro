# Real TCP header allocation attribution

Five trials use external sequential Python clients, with 1,000 requests per
measured connection and ten warm requests before each case. One TCP setup per
bulk measurement is included; client allocations are outside the RTS counters.
This is attribution, not the fixed-load matched writer gate.

The transactional point read is about 35.4 KB and its owning-session variant
27.6 KB. Real headers use about 101.5 KB; a canonical row presentation with no
database work uses 52.1 KB; a prebuilt JSON value with no database uses 34.9 KB.
The static-JSON case with real schema verification uses about 47.6 KB. Test seams
deliberately remove selected work and are never production behavior.

The manifest identifies the exact parent-relative session prototype, retained
driver, binary hash and raw case data. The fixture has a running header with
two non-null timestamps; the completed-workflow writer probe also renders its
completion timestamp. Do not substitute this smaller fixture for that workload.
