# Shared point statement: no useful improvement

Five warmed in-process trials add NOINLINE to the point lookup statement.
Point-read allocation remains about 35 KB, its session variant about 27.5 KB,
and the full header about 87.4 KB. Unlike the earlier verifier experiment,
this annotation produces no useful reduction and is removed from the candidate.

Retain the driver, compressed source patch and source/binary hashes with all
raw cases. The prototype session primitive remains separate; the production
header still uses the existing command runner at this checkpoint. This is
attribution evidence, not an interference or retention acceptance result.
