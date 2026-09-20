#!/usr/bin/env python3
"""Validate and compare Keiro replay-compatibility report v1 files."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


REPORT_VERSION = "keiro.replay-compatibility/report/v1"
INVENTORY_VERSION = "keiro.replay-compatibility/inventory/v1"
INVENTORY_SOURCES = {
    "baseline-persisted-surfaces",
    "candidate-persisted-surfaces",
    "ordinary-compatibility-findings",
    "aggregate-replay-impacts",
    "mapped-consequences",
    "checked-process-reactions",
    "application-owned-obligations",
}


class ContractError(ValueError):
    pass


def object_without_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ContractError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as handle:
            value = json.load(handle, object_pairs_hook=object_without_duplicates)
    except (OSError, json.JSONDecodeError, ContractError) as problem:
        raise ContractError(f"{path}: {problem}") from problem
    if not isinstance(value, dict):
        raise ContractError(f"{path}: top-level JSON value must be an object")
    return value


def canonical(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def surface_key(surface: Any) -> str:
    if not isinstance(surface, dict):
        return "<invalid-surface>"
    return "/".join(str(surface.get(field, "?")) for field in ("kind", "owner", "identity"))


def first_difference(baseline: Any, candidate: Any, path: str = "") -> str | None:
    if type(baseline) is not type(candidate):
        return f"{path or '/'} type changed from {type(baseline).__name__} to {type(candidate).__name__}"
    if isinstance(baseline, dict):
        for key in sorted(set(baseline) - set(candidate)):
            return f"{path}/{key} missing from candidate"
        for key in sorted(set(candidate) - set(baseline)):
            return f"{path}/{key} unexpected in candidate"
        for key in sorted(baseline):
            difference = first_difference(baseline[key], candidate[key], f"{path}/{key}")
            if difference:
                return difference
        return None
    if isinstance(baseline, list):
        if len(baseline) != len(candidate):
            return f"{path or '/'} length changed from {len(baseline)} to {len(candidate)}"
        for index, (old, new) in enumerate(zip(baseline, candidate, strict=True)):
            difference = first_difference(old, new, f"{path}/{index}")
            if difference:
                return difference
        return None
    if baseline != candidate:
        return f"{path or '/'} changed from {canonical(baseline)} to {canonical(candidate)}"
    return None


def indexed(items: Any, key_path: tuple[str, ...], label: str, errors: list[str]) -> dict[str, Any]:
    if not isinstance(items, list):
        errors.append(f"{label} must be an array")
        return {}
    result: dict[str, Any] = {}
    for item in items:
        value: Any = item
        for key in key_path:
            if not isinstance(value, dict):
                value = None
                break
            value = value.get(key)
        if not isinstance(value, str) or not value:
            errors.append(f"{label} contains an item without {'/'.join(key_path)}")
            continue
        if value in result:
            errors.append(f"{label} repeats {value}")
        else:
            result[value] = item
    return result


def observation_empty(observation: Any) -> bool:
    if not isinstance(observation, dict):
        return True
    return not any(
        observation.get(field)
        for field in ("durableState", "continuations", "durableIdentities", "freshAllocations")
    )


def validate_inventory(inventory: dict[str, Any], require_all: bool, errors: list[str]) -> dict[str, dict[str, Any]]:
    if inventory.get("inventoryVersion") != INVENTORY_VERSION:
        errors.append(f"unsupported inventory version: {inventory.get('inventoryVersion')!r}")
    contributions = indexed(inventory.get("contributions"), ("source",), "inventory contributions", errors)
    if require_all:
        for source in sorted(INVENTORY_SOURCES - set(contributions)):
            errors.append(f"inventory omits source: {source}")
        for source in sorted(set(contributions) - INVENTORY_SOURCES):
            errors.append(f"inventory has unsupported source: {source}")

    cases: dict[str, dict[str, Any]] = {}
    for source, contribution in contributions.items():
        applicability = contribution.get("applicability")
        status = applicability.get("status") if isinstance(applicability, dict) else None
        contribution_cases = contribution.get("cases")
        if not isinstance(contribution_cases, list):
            errors.append(f"inventory source {source} cases must be an array")
            continue
        if status == "unverified":
            errors.append(f"inventory source {source} is unverified: {applicability.get('reason', '')}")
        elif status == "applicable" and not contribution_cases:
            errors.append(f"inventory source {source} is applicable but has no cases")
        elif status == "not-applicable":
            if not applicability.get("reason"):
                errors.append(f"inventory source {source} has no not-applicable reason")
            if contribution_cases:
                errors.append(f"inventory source {source} is not applicable but supplies cases")
        elif status not in {"applicable", "not-applicable", "unverified"}:
            errors.append(f"inventory source {source} has unsupported applicability: {status!r}")
        for case in contribution_cases:
            if not isinstance(case, dict) or not isinstance(case.get("caseId"), str):
                errors.append(f"inventory source {source} has a malformed case")
                continue
            case_id = case["caseId"]
            previous = cases.get(case_id)
            if previous is not None and canonical(previous) != canonical(case):
                errors.append(f"inventory gives conflicting definitions for case: {case_id}")
            else:
                cases[case_id] = case
    if require_all and not cases:
        errors.append("inventory has no required replay cases")
    return cases


def validate_report(
    report: dict[str, Any],
    role: str,
    inventory: dict[str, Any],
    required_cases: dict[str, dict[str, Any]],
    require_all: bool,
    errors: list[str],
) -> dict[str, dict[str, Any]]:
    if report.get("reportVersion") != REPORT_VERSION:
        errors.append(f"{role} report has unsupported version: {report.get('reportVersion')!r}")
    if report.get("role") != role:
        errors.append(f"expected {role} report, got {report.get('role')!r}")
    if report.get("buildPair") != inventory.get("buildPair"):
        errors.append(f"{role} buildPair does not match inventory")
    if report.get("inventoryId") != inventory.get("inventoryId"):
        errors.append(f"{role} report names a different inventory")

    marks = indexed(report.get("highWaterMarks"), ("stream",), f"{role} high-water marks", errors)
    if not marks:
        errors.append(f"{role} report has no stream high-water marks")
    selected = {canonical(surface): surface for surface in report.get("selectedSurfaces", []) if isinstance(surface, dict)}
    results = indexed(report.get("results"), ("requiredCase", "caseId"), f"{role} case results", errors)

    cases_to_check = required_cases if require_all else {key: required_cases[key] for key in results.keys() & required_cases.keys()}
    for case_id, required in cases_to_check.items():
        result = results.get(case_id)
        surface = required.get("surface")
        coordinate = f"case {case_id} surface {surface_key(surface)}"
        if result is None:
            errors.append(f"{role} report omits required {coordinate}")
            continue
        if result.get("requiredCase") != required:
            errors.append(f"{role} report changes the definition of {coordinate}")
        if canonical(surface) not in selected:
            errors.append(f"{role} report omits selected {coordinate}")
        verdict = result.get("verdict")
        status = verdict.get("status") if isinstance(verdict, dict) else None
        if status != "passed":
            reason = verdict.get("reason", "") if isinstance(verdict, dict) else ""
            errors.append(f"{role} {coordinate} is {status or 'malformed'}: {reason}")
        if status == "passed" and observation_empty(result.get("observation")):
            errors.append(f"{role} {coordinate} passed with an empty observation")
    return results


def compare_reports(
    baseline: dict[str, Any],
    candidate: dict[str, Any],
    required_cases: dict[str, dict[str, Any]],
    baseline_results: dict[str, dict[str, Any]],
    candidate_results: dict[str, dict[str, Any]],
    require_all: bool,
    errors: list[str],
) -> None:
    for field, message in (
        ("corpusHash", "baseline and candidate corpus hashes differ"),
        ("observationContractVersion", "baseline and candidate observation contracts differ"),
        ("determinismInputs", "baseline and candidate determinism inputs differ"),
    ):
        if baseline.get(field) != candidate.get(field):
            errors.append(message)

    baseline_marks = {item.get("stream"): item.get("revision") for item in baseline.get("highWaterMarks", []) if isinstance(item, dict)}
    candidate_marks = {item.get("stream"): item.get("revision") for item in candidate.get("highWaterMarks", []) if isinstance(item, dict)}
    if baseline_marks != candidate_marks:
        errors.append("baseline and candidate high-water marks differ")

    case_ids = set(required_cases) if require_all else set(baseline_results) & set(candidate_results)
    if not case_ids:
        errors.append("baseline and candidate have no matched replay cases")
    for case_id in sorted(case_ids):
        old_result = baseline_results.get(case_id)
        new_result = candidate_results.get(case_id)
        if old_result is None or new_result is None:
            continue
        old_observation = old_result.get("observation")
        new_observation = new_result.get("observation")
        difference = first_difference(old_observation, new_observation)
        if difference:
            surface = required_cases.get(case_id, {}).get("surface")
            errors.append(f"case {case_id} surface {surface_key(surface)} first divergence: {difference}")


def check(
    baseline: dict[str, Any], candidate: dict[str, Any], inventory: dict[str, Any], require_all: bool
) -> list[str]:
    errors: list[str] = []
    required_cases = validate_inventory(inventory, require_all, errors)
    baseline_results = validate_report(baseline, "baseline", inventory, required_cases, require_all, errors)
    candidate_results = validate_report(candidate, "candidate", inventory, required_cases, require_all, errors)
    compare_reports(
        baseline,
        candidate,
        required_cases,
        baseline_results,
        candidate_results,
        require_all,
        errors,
    )
    return errors


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--inventory", type=Path, required=True)
    parser.add_argument("--require-all", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        baseline = load_json(args.baseline)
        candidate = load_json(args.candidate)
        inventory = load_json(args.inventory)
    except ContractError as problem:
        print(problem, file=sys.stderr)
        return 1
    errors = check(baseline, candidate, inventory, args.require_all)
    if errors:
        for error in errors:
            print(f"replay compatibility: {error}", file=sys.stderr)
        return 1
    print(f"replay compatibility: {len(validate_inventory(inventory, args.require_all, []))} matched cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
