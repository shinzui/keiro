#!/usr/bin/env python3
"""Retain original command output and an honest status for publication checks."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[5]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'scripts'))
from release_workflow import atomic_json, source_identity

assert os.environ.get('IN_NIX_SHELL'), 'Use the Nix development shell'
name, *command = sys.argv[1:]
if command[:1] == ['--']:
    command = command[1:]
assert command
receipt = HERE / (name + '.json')
log = HERE / (name + '.log')
assert not receipt.exists() and not log.exists(), 'Preserve previous attempts'
value = dict(command=command, started=time.time(), source=source_identity(ROOT), status=None)
atomic_json(receipt, value)
with log.open('w') as handle:
    process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        for line in process.stdout:
            handle.write(line)
            handle.flush()
            print(line, end='', flush=True)
        status = process.wait()
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait()
        process.stdout.close()
value.update(finished=time.time(), status=status, source_unchanged=source_identity(ROOT) == value['source'], log_sha256=hashlib.sha256(log.read_bytes()).hexdigest())
atomic_json(receipt, value)
if not value['source_unchanged']:
    raise RuntimeError('Source changed during the check')
raise SystemExit(status)
