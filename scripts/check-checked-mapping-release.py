#!/usr/bin/env python3
"""Validate the checked-mapping initiative's four independent release gates."""

from __future__ import annotations

import argparse
import json
import re
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
SHA256 = re.compile(r"[0-9a-f]{64}")


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

    retained = manifest.get("retainedImplementations")
    if not isinstance(retained, list) or not retained:
        errors.append("retainedImplementations must be a non-empty array")
    else:
        roles: set[str] = set()
        for implementation in retained:
            if not isinstance(implementation, dict):
                errors.append("retainedImplementations contains a non-object entry")
                continue
            role = implementation.get("role")
            relative = implementation.get("path")
            anchor = implementation.get("anchor")
            if not isinstance(role, str) or not role:
                errors.append("retained implementation is missing role")
            elif role in roles:
                errors.append(f"duplicate retained implementation role: {role}")
            else:
                roles.add(role)
            if not isinstance(relative, str) or not relative:
                errors.append(f"retained implementation {role!r} is missing path")
                continue
            if Path(relative).is_absolute():
                errors.append(f"retained implementation path must be repository-relative: {relative}")
                continue
            implementation_path = root / relative
            if not implementation_path.is_file():
                errors.append(f"retained implementation path does not exist: {relative}")
                continue
            if not isinstance(anchor, str) or not anchor:
                errors.append(f"retained implementation {role!r} is missing anchor")
            elif anchor not in implementation_path.read_text(encoding="utf-8"):
                errors.append(f"retained implementation anchor missing for {role!r}: {anchor}")

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
    consumer_evidence = evidence.get("consumerHistoryEvidence") if isinstance(evidence, dict) else None
    retirement_evidence = evidence.get("retirementEvidence") if isinstance(evidence, dict) else None

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
        if not isinstance(consumer_evidence, dict):
            errors.append("consumer-adoption eligibility requires structured consumerHistoryEvidence")
        else:
            for field in (
                "archiveSha256",
                "baselineBinarySha256",
                "candidatePatchSha256",
                "candidateBinarySha256",
                "processHarnessBinarySha256",
                "baselineCandidateReportSha256",
            ):
                if not SHA256.fullmatch(str(consumer_evidence.get(field, ""))):
                    errors.append(f"consumerHistoryEvidence has invalid {field}")
            if consumer_evidence.get("consumer") != adoption.get("consumer"):
                errors.append("consumerHistoryEvidence consumer must match the adoption gate")
            if consumer_evidence.get("privatePayloadsCommitted") is not False:
                errors.append("consumer history evidence must not commit private payloads")
            stream_replay = consumer_evidence.get("streamReplay", {})
            if stream_replay.get("baselineCandidateReportsIdentical") is not True:
                errors.append("consumer adoption requires identical baseline/candidate replay reports")
            if stream_replay.get("unexpectedFailures") != 0:
                errors.append("consumer adoption requires zero unexpected replay failures")
            process = consumer_evidence.get("processContinuation", {})
            if process.get("outboundEffectsEnabled") is not False:
                errors.append("consumer process continuation must disable outbound effects")
            if process.get("checkpointAfter") != process.get("checkpointBefore"):
                errors.append("consumer process continuation must restore the retained checkpoint")
            if process.get("deadLettersBeforeAfter") != 0:
                errors.append("consumer process continuation must not create dead letters")
            workflow = consumer_evidence.get("workflowInventory", {})
            if workflow.get("instances") == 0:
                if workflow.get("result") != "not-applicable-empty-history":
                    errors.append("empty workflow history must be reported explicitly as not applicable")
            elif workflow.get("result") != "passed":
                errors.append("non-empty workflow history requires a passed continuation result")
    elif adoption.get("result") == "pending" and not adoption.get("missingEvidence"):
        errors.append("pending consumer-adoption must name missingEvidence")
    if retirement.get("result") == "eligible":
        if adoption.get("result") != "eligible":
            errors.append("implementation-retirement eligibility requires consumer-adoption eligibility")
        if not milestones.get("retirementRehearsal"):
            errors.append("implementation-retirement eligibility requires a retirement rehearsal")
        if not isinstance(retirement_evidence, dict):
            errors.append("implementation-retirement eligibility requires structured retirementEvidence")
        else:
            if retirement_evidence.get("oldHistoryPassed") is not True:
                errors.append("retirement rehearsal requires old-history replay")
            if retirement_evidence.get("processContinuationPassed") is not True:
                errors.append("retirement rehearsal requires process continuation")
            if retirement_evidence.get("requiredReaderNegativeMutationPassed") is not True:
                errors.append("retirement rehearsal requires the reader-removal negative mutation")
            if retirement_evidence.get("genericOpaqueSupportRetained") is not True:
                errors.append("bounded retirement must retain generic opaque support")
            adopted_patch = consumer_evidence.get("candidatePatchSha256") if isinstance(consumer_evidence, dict) else None
            if retirement_evidence.get("candidatePatchSha256") != adopted_patch:
                errors.append("retirement rehearsal must use the adopted candidate patch")
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
