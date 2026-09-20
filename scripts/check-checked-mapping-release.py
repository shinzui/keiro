#!/usr/bin/env python3
"""Validate the checked-mapping initiative's four independent release gates."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


SCHEMA = "keiro.checked-mapping-release/v1"
GATES = {
    "package-release",
    "language-publication",
    "consumer-adoption",
    "implementation-retirement",
}


def load(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, json.JSONDecodeError) as problem:
        raise ValueError(f"{path}: {problem}") from problem
    if not isinstance(value, dict):
        raise ValueError(f"{path}: top-level JSON value must be an object")
    return value


def repository_paths(manifest: dict[str, Any]) -> list[str]:
    evidence = manifest.get("repositoryEvidence", {})
    paths = [
        evidence.get("compatibilityPlan"),
        evidence.get("integratedPlan"),
        evidence.get("integratedFixture"),
    ]
    paths.extend(evidence.get("featurePlans", []))
    for policy in manifest.get("wirePolicies", []):
        if isinstance(policy, dict):
            paths.extend(policy.get("vectors", []))
            paths.extend(policy.get("goldens", []))
    return [path for path in paths if isinstance(path, str)]


def validate(manifest: dict[str, Any], root: Path) -> list[str]:
    errors: list[str] = []
    if manifest.get("schema") != SCHEMA:
        errors.append(f"unsupported release manifest schema: {manifest.get('schema')!r}")

    gates = manifest.get("gates")
    if not isinstance(gates, dict):
        return errors + ["gates must be an object"]
    missing = GATES - set(gates)
    extra = set(gates) - GATES
    errors.extend(f"missing independent gate: {gate}" for gate in sorted(missing))
    errors.extend(f"unsupported gate: {gate}" for gate in sorted(extra))

    for gate_name in sorted(GATES & set(gates)):
        gate = gates[gate_name]
        if not isinstance(gate, dict):
            errors.append(f"gate {gate_name} must be an object")
            continue
        if gate.get("result") not in {"eligible", "pending", "ineligible"}:
            errors.append(f"gate {gate_name} has unsupported result: {gate.get('result')!r}")
        if gate.get("action") != "not-performed":
            errors.append(f"gate {gate_name} must remain not-performed in repository evidence")
        if not gate.get("basis"):
            errors.append(f"gate {gate_name} must record its basis")

    policies = manifest.get("wirePolicies")
    if not isinstance(policies, list) or not policies:
        errors.append("wirePolicies must be a non-empty array")
    else:
        identities: set[str] = set()
        for policy in policies:
            if not isinstance(policy, dict):
                errors.append("wirePolicies contains a non-object entry")
                continue
            identity = policy.get("identity")
            if not isinstance(identity, str) or not identity:
                errors.append("wire policy is missing identity")
            elif identity in identities:
                errors.append(f"duplicate wire policy identity: {identity}")
            else:
                identities.add(identity)
            if policy.get("status") != "frozen":
                errors.append(f"wire policy {identity!r} is not frozen")
            for field in ("vectors", "goldens"):
                if not isinstance(policy.get(field), list) or not policy[field]:
                    errors.append(f"wire policy {identity!r} has no {field}")

    for relative in repository_paths(manifest):
        if Path(relative).is_absolute():
            errors.append(f"evidence path must be repository-relative: {relative}")
        elif not (root / relative).is_file():
            errors.append(f"evidence path does not exist: {relative}")

    evidence = manifest.get("repositoryEvidence", {})
    milestones = evidence.get("milestones", {}) if isinstance(evidence, dict) else {}
    package = gates.get("package-release", {})
    publication = gates.get("language-publication", {})
    adoption = gates.get("consumer-adoption", {})
    retirement = gates.get("implementation-retirement", {})

    if package.get("result") == "eligible" and errors:
        errors.append("package-release cannot be eligible while repository evidence is invalid")
    if publication.get("result") == "eligible":
        if package.get("result") != "eligible":
            errors.append("language-publication eligibility requires package-release eligibility")
        if not milestones.get("integratedCorpus") or not milestones.get("evolutionMatrix"):
            errors.append("language-publication eligibility requires integrated corpus and evolution matrix evidence")
    if adoption.get("result") == "eligible":
        if not milestones.get("consumerHistory"):
            errors.append("consumer-adoption eligibility requires consumerHistory evidence")
        if adoption.get("missingEvidence"):
            errors.append("consumer-adoption eligibility cannot retain missingEvidence")
    elif adoption.get("result") == "pending" and not adoption.get("missingEvidence"):
        errors.append("pending consumer-adoption must name missingEvidence")
    if retirement.get("result") == "eligible":
        if adoption.get("result") != "eligible":
            errors.append("implementation-retirement eligibility requires consumer-adoption eligibility")
        if not milestones.get("retirementRehearsal"):
            errors.append("implementation-retirement eligibility requires a retirement rehearsal")
    elif retirement.get("result") == "pending" and "consumer-adoption" not in retirement.get("blockedBy", []):
        errors.append("pending implementation-retirement must remain blocked by consumer-adoption")
    if retirement.get("legacyReadersRetained") is not True:
        errors.append("legacy readers must remain retained until retirement is eligible")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    arguments = parser.parse_args()
    try:
        manifest = load(arguments.manifest)
    except ValueError as problem:
        print(problem, file=sys.stderr)
        return 2
    errors = validate(manifest, arguments.root)
    if errors:
        for error in errors:
            print(f"release gate: {error}", file=sys.stderr)
        return 1
    statuses = ", ".join(f"{name}={manifest['gates'][name]['result']}" for name in sorted(GATES))
    print(f"checked-mapping release manifest: PASS ({statuses})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
