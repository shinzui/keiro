# Header allocation attribution

Initial server-side comparison: verification still allocates about 1.55 MB/call without preserving prepared-statement CAF sharing.

Five repetitions warm ten calls and measure 100 calls each. The process includes the WAI test client. These are attribution experiments, not the full matched deployment/retention gate. The final deployment comparison uses external clients.
