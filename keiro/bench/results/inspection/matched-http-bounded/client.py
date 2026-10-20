"""External loopback poller so runtime RTS counters exclude client allocation."""

import http.client
import json
import sys
import threading
import time


def main():
    port, clients, seconds = map(int, sys.argv[1:4])
    options = sys.argv[4:]
    controlled = bool(options) and options[0] == "controlled"
    if options and (not controlled or len(options) > 2):
        raise RuntimeError("unknown client mode")
    views = int(options[1]) if len(options) == 2 else max(1, clients)
    if clients < 0 or views < 1:
        raise RuntimeError("clients must be nonnegative and views positive")
    if clients == 0:
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        try:
            connection.request("GET", "/health")
            response = connection.getresponse()
            response.read()
            if response.status != 200:
                raise RuntimeError(f"health returned {response.status}")
        finally:
            connection.close()
        print(json.dumps([1, 0]))
        return

    stop = threading.Event()
    lock = threading.Lock()
    counts = [0, 0]
    started = time.monotonic()
    warm_errors = []
    warmed = threading.Barrier(clients + 1) if controlled else None
    go = threading.Event()

    def poll(index):
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        assigned = list(range(index, views, clients)) if clients <= views else [index % views]

        def fetch(view):
            try:
                connection.request(
                    "GET", f"/wf/inspect/header/index-evidence/warm-{view + 1}"
                )
                response = connection.getresponse()
                response.read()
                return response.status == 200
            except (OSError, http.client.HTTPException):
                connection.close()
                return False

        try:
            if controlled:
                stop.wait(index / max(clients, views))
                for view in assigned:
                    if not fetch(view):
                        with lock:
                            warm_errors.append((index, view))
                warmed.wait()
                go.wait()
                if stop.is_set():
                    return
            iteration = 0
            while True:
                due = started + index / max(clients, views) + iteration / len(assigned)
                if due >= started + seconds:
                    break
                if stop.wait(max(0, due - time.monotonic())):
                    break
                good = fetch(assigned[iteration % len(assigned)])
                with lock:
                    counts[0 if good else 1] += 1
                iteration += 1
        finally:
            connection.close()

    workers = [threading.Thread(target=poll, args=(index,)) for index in range(clients)]
    for worker in workers:
        worker.start()
    try:
        if controlled:
            warmed.wait()
            if warm_errors:
                raise RuntimeError(f"failed warm-up views: {warm_errors}")
            print("ready", flush=True)
            if sys.stdin.readline().strip() != "go":
                raise RuntimeError("parent did not start the measurement")
            started = time.monotonic()
            go.set()
        stop.wait(seconds)
    finally:
        stop.set()
        go.set()
        for worker in workers:
            worker.join()
    print(json.dumps(counts))


if __name__ == "__main__":
    main()
