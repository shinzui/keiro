#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
python3 - <<'PY'
from pathlib import Path
import subprocess

root = Path('keiro-dsl/test/conformance-mapped-structural-enum-equality')
binding = root / 'Conformance/MappedStructuralEnumEquality/Bindings.hs'
projection = root / 'Generated/MappedStructuralEnumEquality/StructuralProjections.hs'
originals = {path: path.read_bytes() for path in (binding, projection)}
command = ['cabal', 'test', '-v0', 'keiro-dsl-conformance-mapped-structural-enum-equality', '--test-show-details=direct']

def run():
    return subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

def restore():
    for path, contents in originals.items():
        if path.read_bytes() != contents:
            path.write_bytes(contents)

# Each mutation must reach its specific runtime assertion. A compiler error or
# a missing solver cannot stand in for a detected binding-law failure.
mutations = [
    ('collapsed binding', binding, 'toShape Domain.DiagnosticScope = Scope.DiagnosticScope', 'toShape Domain.DiagnosticScope = Scope.PipelineScope', 'FAIL  exhaustive enum shape round-trip: conformance.RequiredScope.v1'),
    ('omitted fixture branch', binding, '[("diagnostic", Domain.DiagnosticScope)]', '[]', 'FAIL  fixture coverage: conformance.RequiredScope.v1'),
    ('omitted finite-domain alternative', projection, 'finiteProjectionDomain ("pipeline" :| ["diagnostic"])', 'finiteProjectionDomain ("pipeline" :| [])', 'FAIL  projection owner law: conformance.RequiredScope.v1'),
    ('wrong inverse', binding, 'fromShape Scope.DiagnosticScope = Domain.DiagnosticScope', 'fromShape Scope.DiagnosticScope = Domain.PipelineScope', 'FAIL  exhaustive enum shape round-trip: conformance.RequiredScope.v1'),
]
try:
    baseline = run()
    if baseline.returncode:
        raise RuntimeError('baseline failed:\n' + baseline.stdout)
    for label, path, old, new, expected in mutations:
        restore()
        contents = path.read_text()
        if contents.count(old) != 1:
            raise RuntimeError('mutation anchor is not unique: ' + label)
        path.write_text(contents.replace(old, new))
        result = run()
        if result.returncode == 0 or expected not in result.stdout:
            raise RuntimeError('mutation did not fail its named assertion: ' + label + '\n' + result.stdout)
        print('PASS  mutation: ' + label, flush=True)
    restore()
    # Swapping both directions is still a bijection. Only expected wire meaning
    # can reject this accidental change; round-trip assertions alone cannot.
    contents = binding.read_text()
    contents = contents.replace('toShape Domain.PipelineScope = Scope.PipelineScope', 'toShape Domain.PipelineScope = Scope.DiagnosticScope')
    contents = contents.replace('toShape Domain.DiagnosticScope = Scope.DiagnosticScope', 'toShape Domain.DiagnosticScope = Scope.PipelineScope')
    contents = contents.replace('fromShape Scope.PipelineScope = Domain.PipelineScope', 'fromShape Scope.PipelineScope = Domain.DiagnosticScope')
    contents = contents.replace('fromShape Scope.DiagnosticScope = Domain.DiagnosticScope', 'fromShape Scope.DiagnosticScope = Domain.PipelineScope')
    binding.write_text(contents)
    result = run()
    if result.returncode == 0 or 'FAIL  expected enum wire meanings' not in result.stdout:
        raise RuntimeError('bijective swap escaped expected-wire assertion:\n' + result.stdout)
    print('PASS  mutation: bijective meaning swap', flush=True)
    # Fixture order is not a harness contract: generated sampling selects by
    # projected wire key and register initial, so a reordered supply must pass.
    restore()
    contents = binding.read_text()
    old = 'FixtureCases (("pipeline", Domain.PipelineScope) :| [("diagnostic", Domain.DiagnosticScope)])'
    new = 'FixtureCases (("diagnostic", Domain.DiagnosticScope) :| [("pipeline", Domain.PipelineScope)])'
    if contents.count(old) != 1:
        raise RuntimeError('fixture order anchor is not unique')
    binding.write_text(contents.replace(old, new))
    result = run()
    if result.returncode != 0:
        raise RuntimeError('reordered fixtures broke the generated harness:\n' + result.stdout)
    print('PASS  control: fixture order is not a sampling contract', flush=True)
    for label, old, new, marker in [
        ('missing binding symbol', 'requiredScopeBinding = StructuralBinding toShape fromShape', 'requiredScopeBinding = missingScopeBinding', 'missingScopeBinding'),
        ('wrong binding signature', 'requiredScopeBinding :: StructuralBinding Domain.RequiredScope', 'requiredScopeBinding :: StructuralBinding Domain.Request', "Couldn't match type"),
    ]:
        restore()
        contents = binding.read_text()
        if contents.count(old) != 1:
            raise RuntimeError('compiler mutation anchor is not unique: ' + label)
        binding.write_text(contents.replace(old, new))
        result = run()
        if result.returncode == 0 or 'error:' not in result.stdout or marker not in result.stdout:
            raise RuntimeError('compiler mutation did not reach its specific diagnostic: ' + label + '\n' + result.stdout)
        print('PASS  mutation: ' + label, flush=True)
finally:
    restore()
baseline = run()
if baseline.returncode:
    raise RuntimeError('restored baseline failed:\n' + baseline.stdout)
print('PASS  restored baseline', flush=True)
PY
