# Bundle Update Log

## 2026-07-28
* **Update**: Record the generated-harness forward/replay equality assertion as the conformance-CI gate for forward-versus-replay state divergence (plan 147).
* **Update**: Name defaultStateCodecWithFold and FoldVersion as the first-class hand-written fold-discriminator contract.
* **Added**: Record one private-event schema authority, total structural bindings, explicit snapshot-cache invalidation, and schema-derived Keiki projection provenance.

## 2026-07-27
* **Update**: Add the scope-sequenced close rule: an unclosed Kafka consumer keeps polling and starves its partitions, so close must never be deferred to the garbage collector.
* **Update**: Extend the consumer contract with the converse obligation: routine partition conditions and idle commits must not kill a consumer, and trace context is per-record.
* **Added**: Record the Kafka consumer fatal-observability contract: fatals are reported in-band as RdKafkaRespErrFatal from every poll in both callback poll modes, via a commit-pinned hw-kafka-client fork.
* **Migration**: Adopt the shared architecture-decision profile.
