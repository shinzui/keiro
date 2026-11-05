#!/usr/bin/env python3
"""Publish only this release's audited, prebuilt archives, in dependency order."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[5]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'scripts'))
from release_workflow import PACKAGES, atomic_json, check_artifacts, file_digest, output, require_clean, source_identity, version

assert os.environ.get('IN_NIX_SHELL')
assert version() == '0.24.0.0'
require_clean()
ready = json.loads((HERE / 'readiness.json').read_text())
assert ready['status'] == 'ready_with_reviewed_performance_exception'
assert source_identity() == ready['source']
assert file_digest(HERE / 'performance-review.json') == ready['performance_review_sha256']
assert file_digest(HERE / 'native-nix.json') == ready['native_nix_receipt_sha256']
inventory = check_artifacts()
assert file_digest(ROOT / 'dist-release/0.24.0.0/artifacts.json') == ready['artifact_inventory_sha256']
head = output(['git', 'rev-parse', 'HEAD'])
for package in PACKAGES:
    assert output(['git', 'rev-parse', f'{package}-0.24.0.0^{{}}']) == head
result_path = HERE / 'uploads.json'
assert not result_path.exists(), 'Do not repeat or hide a publication attempt'
result = dict(version='0.24.0.0', commit=head, source=ready['source'], readiness_sha256=file_digest(HERE / 'readiness.json'), started=time.time(), status='running', uploads=[])
atomic_json(result_path, result)
for package in PACKAGES:
    for documentation in [False, True]:
        suffix = '-docs' if documentation else ''
        filename = f'{package}-0.24.0.0{suffix}.tar.gz'
        archive = ROOT / 'dist-release/0.24.0.0' / filename
        assert file_digest(archive) == inventory['sha256'][filename]
        assert source_identity() == ready['source']
        command = ['cabal', 'upload', '--publish'] + (['--documentation'] if documentation else []) + [str(archive)]
        log = HERE / (filename + '.upload.log')
        print('UPLOAD', filename, flush=True)
        started = time.time()
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
        result['uploads'].append(dict(archive=filename, documentation=documentation, sha256=inventory['sha256'][filename], started=started, finished=time.time(), status=status, log=log.name, log_sha256=file_digest(log)))
        if status:
            result.update(status='failed', finished=time.time())
            atomic_json(result_path, result)
            raise SystemExit(status)
        atomic_json(result_path, result)
result.update(status='passed', finished=time.time())
atomic_json(result_path, result)
print('All eight source and documentation archives published.', flush=True)
