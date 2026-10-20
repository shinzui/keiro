# Header allocation attribution

Using the request thread and the RTS timeout manager reduces repeated-header allocation to about 87.3 KB/call, with verification about 10.3 KB/call.

Five repetitions warm ten calls and measure 100 calls each. The process includes the WAI test client. These are attribution experiments, not the full matched deployment/retention gate. The final deployment comparison uses external clients.
