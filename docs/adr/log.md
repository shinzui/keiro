# Bundle Update Log

## 2026-07-27
* **Added**: Record the Kafka consumer fatal-observability contract: fatals are reported in-band as RdKafkaRespErrFatal from every poll in both callback poll modes, via a commit-pinned hw-kafka-client fork.
* **Migration**: Adopt the shared architecture-decision profile.
