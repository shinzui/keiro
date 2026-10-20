# Prepared SQL length diagnostic

Five repetitions measure 100 successful uses of a shared prepared `SELECT true` with an empty comment or a 180,000-character comment. Both allocate about 4.1 KB/call. Large prepared SQL alone does not explain the intermediate schema-comparison allocation; preserving the prepared value sharing in the optimized caller removes that cost. This diagnostic changes no production statement policy and is not deployment acceptance.
