#!/usr/bin/env python3
"""Audit this release's explicitly reviewed timing exception without altering receipts."""
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[5]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'scripts'))
from release_workflow import (
    EVIDENCE, GUARDS, SCHEMA, atomic_json, check_artifacts, digest, file_digest,
    identity, preflight, require_clean, reusable, source_identity, version,
    workspace_lock,
)

assert os.environ.get('IN_NIX_SHELL'), 'Use the Nix development shell'
with workspace_lock():
    require_clean()
    review_path = HERE / 'performance-review.json'
    review = json.loads(review_path.read_text())
    assert version() == review['version'] == '0.24.0.0'
    assert source_identity() == review['source']
    assert set(review['reviewed_stages']) == {'inbox'}
    for name, checksum in review['supporting_assessments'].items():
        assert file_digest(ROOT / name) == checksum, name
    focused = ROOT / EVIDENCE / '20261105-focused-noise'
    for name, checksum in json.loads((focused / 'sha256.json').read_text()).items():
        assert file_digest(ROOT / name) == checksum, name
    native_path = HERE / 'native-nix.json'
    native = json.loads(native_path.read_text())
    assert native['status'] == 0 and native['source_unchanged']
    assert native['source'] == review['source']
    assert file_digest(HERE / 'native-nix.log') == native['log_sha256']
    plan = preflight()
    inputs = identity(plan=plan)
    manifest_path = ROOT / review['manifest']
    assert file_digest(manifest_path) == review['manifest_sha256']
    manifest = json.loads(manifest_path.read_text())
    assert manifest['schema'] == SCHEMA and manifest['identity'] == digest(inputs)
    assert set(manifest['stages']) == {'correctness', *GUARDS}
    for name, reference in manifest['stages'].items():
        path = ROOT / reference['receipt']
        assert file_digest(path) == reference['sha256'], name
        receipt = json.loads(path.read_text())
        command = ['just', '_verify'] if name == 'correctness' else ['scripts/bench-regression.sh', name]
        expected = digest(dict(inputs=inputs, command=command))
        assert receipt['identity'] == expected and receipt['command'] == command
        if name in review['reviewed_stages']:
            approved = review['reviewed_stages'][name]
            assert reference['status'] == receipt['status'] == 1
            assert reference['receipt'] == approved['receipt']
            assert file_digest(path) == approved['sha256']
            assert file_digest(ROOT / receipt['log']) == receipt['log_sha256']
        else:
            assert reference['status'] == 0 and reusable(receipt, expected, ROOT), name
        for later_path in (ROOT / EVIDENCE).glob('*-' + name + '.json'):
            later = json.loads(later_path.read_text())
            assert not (later.get('identity') == expected and later['started'] > receipt['started']), f'Newer {name} attempt requires review'
    inventory = check_artifacts()
    consumer = ROOT / 'dist-release/0.24.0.0/consumer-staged/result.json'
    atomic_json(HERE / 'readiness.json', dict(
        status='ready_with_reviewed_performance_exception', version='0.24.0.0',
        source=source_identity(), manifest=str(manifest_path.relative_to(ROOT)),
        manifest_sha256=file_digest(manifest_path), performance_review_sha256=file_digest(review_path),
        native_nix_receipt_sha256=file_digest(native_path),
        artifact_inventory_sha256=file_digest(ROOT / 'dist-release/0.24.0.0/artifacts.json'),
        staged_consumer_result_sha256=file_digest(consumer),
        reviewed_failed_stage='inbox', original_manifest_accepted=manifest['accepted'],
    ))
    print('RELEASE_READY_WITH_REVIEWED_PERFORMANCE_EXCEPTION: correctness, native Nix, sixteen archives and staged consumer verified; original inbox failure preserved.')
