"""External loopback poller so runtime RTS counters exclude client allocation."""

import http.client
import json
import sys
import threading
import time


def main():
    port, clients, seconds = map(int, sys.argv[1:])
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

    def poll(index):
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        due = started + index / 32
        try:
            while due < started + seconds:
                if stop.wait(max(0, due - time.monotonic())):
                    break
                good = False
                try:
                    connection.request(
                        "GET", f"/wf/inspect/header/index-evidence/warm-{index + 1}"
                    )
                    response = connection.getresponse()
                    response.read()
                    good = response.status == 200
                except (OSError, http.client.HTTPException):
                    connection.close()
                with lock:
                    counts[0 if good else 1] += 1
                due += 1
        finally:
            connection.close()

    workers = [threading.Thread(target=poll, args=(index,)) for index in range(clients)]
    for worker in workers:
        worker.start()
    try:
        stop.wait(seconds)
    finally:
        stop.set()
        for worker in workers:
            worker.join()
    print(json.dumps(counts))


if __name__ == "__main__":
    main()
