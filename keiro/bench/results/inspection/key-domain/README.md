# Index key-domain compatibility: rejected candidates

Every insertion and intentional failure is on a durable disposable clone.
The workflow creation and class indexes are removed before binary-searching
an incompressible text key accepted by the existing primary key. At PostgreSQL
18.6's default block size, a 2684-byte name with short id fits; a 2687-byte id
with short name fits. The proposed larger indexes reject both. A per-class
partial name/id index still rejects the latter: even field reversal can change
index-tuple alignment at the limit. It is not a complete compatibility fix.

The child row has independent 1600-byte parent and child keys, each accepted by
its existing indexes. The proposed compound parent/creation/child index rejects
it. The awakeable owner index accepts a 2684-byte key, but adding creation/id
keys rejects it. Full PostgreSQL errors are retained in key-domain.json.

These are ordinary writer/schema compatibility failures, separate from the
latency and HOT gates. No index may narrow that writer key domain merely to
speed inspection. Candidate workflow indexes must exclude oversized entries
and retain a bounded, explicit read path for those records. Compound owner
indexes remain unselected; manual pages retain host statement/read deadlines.

The retained driver and manifest identify the exact candidate, including the
unreleased migration 0034 prototype. Earlier read-plan improvements alone did
not establish that those schemas could be accepted.
