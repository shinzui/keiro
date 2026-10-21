# Rejected inspection writer DDL

Five alternating saturation comparisons at matched GHC 9.12.4/O1 and
`+RTS -N8 -A16m -T` found -9.22% median ordinary-writer capacity and +12.91%
p95 with inspection unmounted. The 100/s paced matrix had concealed this loss
of headroom. Candidate runtime was 88b56fc1 with the original 0033/0034 stored
class/indexes; the pre-change baseline was 3bf3ac22. Both use the strict-counter
benchmark source, normal durability, identical 100k workflow/timer ledgers and
one reserved writer connection. See raw settings and summary.json.

This fails the core-path requirement. The unpublished writer DDL is withdrawn;
classification moves to read predicates using existing status/key access, with
read costs governed by inspection budgets. These are rejection evidence, not
passing release gates.
