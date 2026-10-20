# Header allocation attribution

Preserving prepared-statement sharing reduces verification to about 10.34 KB/call; HTTP header parsing is not yet cached.

Five repetitions warm ten calls and measure 100 calls each. The process includes the WAI test client. These are attribution experiments, not the full matched deployment/retention gate. The final deployment comparison uses external clients.
