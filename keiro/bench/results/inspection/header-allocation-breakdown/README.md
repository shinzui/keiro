# Header allocation attribution

Five warmed 100-call trials attribute in-process WAI allocation through the
supported operations test seam. The production header is about 87,328 bytes per
call; the ordinary transactional point lookup is about 35,297 and fresh schema
verification about 10,358. Replacing database work but retaining row-to-JSON
presentation gives 39,656; supplying a prebuilt JSON value gives 22,350. These
variants isolate costs and are never production behavior or acceptance evidence.

The fake operations read their row/value from an IORef on each call. The
no-database row variant still builds the canonical JSON representation on each
request. A separate static-JSON control removes that construction deliberately.
The real route translation, admission, deadline and response size checks remain.

Each case warms ten calls before sampling. Raw RTS counters, command timings,
retained driver and source/binary hashes identify this candidate. These figures
include WAI.Test client allocation and omit real socket costs, so they must not
be substituted for the external-client matched writer experiment.
