# Header allocation attribution

A bounded cache of pure parsed read commands reduces repeated-header allocation to about 124 KB/call. Live observations and schema agreement are never cached.

Five repetitions warm ten calls and measure 100 calls each. The process includes the WAI test client. These are attribution experiments, not the full matched deployment/retention gate. The final deployment comparison uses external clients.
