"""Run an already-built measurement and refuse observed compiler/test overlap.

Usage: python3 run-quiet.py [--diagnostic] PROCESS_LOG COMMAND [ARG...]
Diagnostic mode runs through observed overlap but still exits nonzero for it.
Process-name observations supplement a reserved quiet window, not an OS-wide
resource-isolation guarantee. Monitor work is identical for both binaries.
"""
import datetime
import json
import re
import shlex
import subprocess
import sys
import threading
from pathlib import Path


def cabal_operation(arguments):
    try:
        words = shlex.split(arguments)
    except ValueError:
        return 'unknown'
    operations = {'build', 'test', 'bench', 'run', 'exec', 'repl', 'haddock',
                  'install', 'configure', 'list-bin', 'path', 'update', 'check'}
    for word in words[1:]:
        operation = word.removeprefix('v2-').removeprefix('v1-')
        if operation in operations:
            return operation
    return 'unknown'


def busy_processes():
    rows = []
    output = subprocess.check_output(['ps', '-axo', 'pid,ppid,comm'], text=True)
    for line in output.splitlines()[1:]:
        pid, parent, command = line.strip().split(None, 2)
        name = Path(command).name
        row = dict(pid=int(pid), parent=int(parent), command=command)
        if name in ('cabal', '.cabal-wrapped'):
            # Keep only the operation, never arbitrary process arguments.
            arguments = subprocess.run(['ps', '-ww', '-p', pid, '-o', 'args='],
                                       text=True, capture_output=True).stdout.strip()
            if not arguments:  # Process already exited.
                continue
            row['operation'] = cabal_operation(arguments)
            if row['operation'] in ('list-bin', 'path'):
                continue
            rows.append(row)
        elif (name in ('ghc', 'z3', 'keiro-retention')
              or re.match(r'^ghc-[0-9]', name)
              or name.startswith('haddock-ghc-')
              or name.endswith(('-test', '-bench'))):
            rows.append(row)
    return rows


def run(log, command, diagnostic=False):
    stopped = threading.Event()
    observations = []
    with log.open('x') as handle:
        def observe():
            row = dict(at=datetime.datetime.now(datetime.timezone.utc).isoformat(), busy=busy_processes())
            observations.append(row)
            handle.write(json.dumps(row) + '\n')
            handle.flush()
            return row
        first = observe()
        if first['busy'] and not diagnostic:
            print('Quiet window unavailable:', first['busy'], file=sys.stderr)
            return 2
        def monitor():
            while not stopped.wait(2):
                try:
                    observe()
                except Exception as error:
                    observations.append(dict(busy=[dict(monitor_error=repr(error))]))
                    return
        thread = threading.Thread(target=monitor)
        thread.start()
        try:
            result = subprocess.run(command).returncode
        finally:
            stopped.set()
            thread.join()
            observe()
    if any(row['busy'] for row in observations):
        print('Compiler/test overlap observed; timing cohort is not accepted.', file=sys.stderr)
        return 2
    return result


if __name__ == '__main__':
    args = sys.argv[1:]
    diagnostic = args[0] == '--diagnostic'
    if diagnostic:
        args = args[1:]
    sys.exit(run(Path(args[0]), args[1:], diagnostic))
