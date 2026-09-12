---

version: "0.5"
log_level: debug
log_location: ./.dev/process-compose.log
processes:
  sanity_check:
    command: "echo $PGLOG"
    availability:
      restart: "exit_on_failure"
  create_schema:
    command: "just create-database"
    availability:
      restart: "no"
    depends_on:
      postgres:
        condition: process_healthy

  postgres:
    command: pg_ctl start -w -l $PGLOG -o "--unix_socket_directories='$PGHOST'" -o "-c listen_addresses=''"
    is_daemon: true
    shutdown:
      command: pg_ctl stop -D $PGDATA
    readiness_probe:
      exec:
        command: "pg_ctl status -D $PGDATA"
      initial_delay_seconds: 2
      period_seconds: 10
      timeout_seconds: 4
      success_threshold: 1
      failure_threshold: 5
    availability:
      restart: on_failure
