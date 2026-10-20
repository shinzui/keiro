# Rejected offered-load qualification

The first matched attempt stops before any candidate leg: the pre-change runtime offered 480 operations/second completes about 452.8/second and accumulates about 0.95 seconds of queue delay. This baseline lacks headroom and cannot establish an inspection regression or pass. The raw rejected leg is retained. The later `matched-http-qualified/` run uses explicit paced qualification and retains every rejected proposal.
