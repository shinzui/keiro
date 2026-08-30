#!/usr/bin/env python3
"""Enforce the constructor and private-module boundaries of keiro-dsl."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CABAL_FILE = ROOT / "keiro-dsl" / "keiro-dsl.cabal"
SOURCE_ROOT = ROOT / "keiro-dsl" / "src"
PRIVATE_SOURCE_ROOT = ROOT / "keiro-dsl" / "internal"
GENERATED_LANGUAGE_MODULE = "Keiro.Dsl.GeneratedHaskellLanguage"
PRIVATE_LIBRARY = "generated-haskell-language-internal"
PREPARED_CONSTRUCTOR_ALLOWLIST: set[tuple[str, str]] = set()

PROTECTED_EXPORTS: dict[str, tuple[set[str], set[str]]] = {
    "Keiro.Dsl.AggregateType": ({"AggregateHaskellSource"}, set()),
    "Keiro.Dsl.NominalType": ({"NominalTypeRegistry"}, {"nominalTypes"}),
    "Keiro.Dsl.Diff": ({"ChangeContext"}, {"changeContextRoot", "changeContextPaths"}),
    "Keiro.Dsl.SidecarMigration": ({"PreparedSidecarMove"}, {"preparedSidecarMove"}),
    "Keiro.Dsl.ScaffoldRun": (
        {"PreparedGeneratedHaskellEditionMigration"},
        {"preparedGeneratedHaskellEditionImpact"},
    ),
}

COMPONENT_HEADER = re.compile(
    r"^(?:library(?:[ \t]+[A-Za-z0-9_-]+)?|executable[ \t]+\S+|"
    r"test-suite[ \t]+\S+|benchmark[ \t]+\S+|foreign-library[ \t]+\S+)\s*$",
    re.MULTILINE,
)
MODULE_HEADER = re.compile(
    r"^module\s+(?P<name>[A-Z][A-Za-z0-9_.']*)\s*\n"
    r"\s*\((?P<exports>.*?)\n\s*\)\s*\nwhere\s*$",
    re.MULTILINE | re.DOTALL,
)
TYPE_EXPORT = re.compile(
    r"^(?:type\s+)?(?P<name>[A-Z][A-Za-z0-9_']*)"
    r"(?:\s*\((?P<members>.*)\))?$"
)


class ParseFailure(ValueError):
    """The narrow source-policy parser encountered an unsupported shape."""


@dataclass(frozen=True)
class Component:
    header: str
    body: str


@dataclass(frozen=True)
class ExportItem:
    text: str
    name: str | None
    members: str | None


def parse_components(cabal_text: str) -> list[Component]:
    matches = list(COMPONENT_HEADER.finditer(cabal_text))
    if not matches:
        raise ParseFailure(f"{CABAL_FILE.relative_to(ROOT)}: no Cabal components found")
    components: list[Component] = []
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(cabal_text)
        components.append(Component(match.group(0).strip(), cabal_text[match.end() : end]))
    return components


def component(components: list[Component], header: str) -> Component:
    matches = [candidate for candidate in components if candidate.header == header]
    if len(matches) != 1:
        raise ParseFailure(
            f"{CABAL_FILE.relative_to(ROOT)}: expected exactly one `{header}` stanza, found {len(matches)}"
        )
    return matches[0]


def component_field(component_value: Component, field: str) -> list[str]:
    field_pattern = re.compile(rf"^  {re.escape(field)}:\s*(?P<inline>.*)$", re.MULTILINE)
    matches = list(field_pattern.finditer(component_value.body))
    if len(matches) != 1:
        raise ParseFailure(
            f"{CABAL_FILE.relative_to(ROOT)}: `{component_value.header}` must have exactly one `{field}` field"
        )
    match = matches[0]
    values = match.group("inline").split()
    remaining = component_value.body[match.end() :].splitlines()
    for line in remaining:
        if not line.strip() or line.lstrip().startswith("--"):
            continue
        if line.startswith("    "):
            values.extend(line.strip().split())
            continue
        break
    return values


def module_source(module_name: str) -> Path:
    return SOURCE_ROOT.joinpath(*module_name.split(".")).with_suffix(".hs")


def split_top_level_exports(exports: str) -> list[str]:
    if "{-" in exports or "-}" in exports:
        raise ParseFailure("block comments in module export lists are not supported")
    uncommented = "\n".join(line.split("--", 1)[0] for line in exports.splitlines())
    items: list[str] = []
    current: list[str] = []
    depth = 0
    for character in uncommented:
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth < 0:
                raise ParseFailure("unbalanced parenthesis in module export list")
        if character == "," and depth == 0:
            item = " ".join("".join(current).split())
            if item:
                items.append(item)
            current = []
        else:
            current.append(character)
    if depth != 0:
        raise ParseFailure("unbalanced parenthesis in module export list")
    item = " ".join("".join(current).split())
    if item:
        items.append(item)
    return items


def parse_exports(source_text: str, expected_module: str) -> list[ExportItem]:
    match = MODULE_HEADER.search(source_text)
    if match is None:
        raise ParseFailure(f"{expected_module}: explicit formatted module export list was not found")
    if match.group("name") != expected_module:
        raise ParseFailure(
            f"{expected_module}: source declares unexpected module `{match.group('name')}`"
        )
    exports: list[ExportItem] = []
    for text in split_top_level_exports(match.group("exports")):
        type_match = TYPE_EXPORT.fullmatch(text)
        exports.append(
            ExportItem(
                text=text,
                name=type_match.group("name") if type_match else None,
                members=type_match.group("members") if type_match else None,
            )
        )
    if not exports:
        raise ParseFailure(f"{expected_module}: export list was empty")
    return exports


def check_export_contract(
    path_label: str,
    exports: list[ExportItem],
    abstract_types: set[str],
    required_functions: set[str],
) -> list[str]:
    failures: list[str] = []
    texts = {item.text for item in exports}
    for type_name in sorted(abstract_types):
        matches = [item for item in exports if item.name == type_name]
        if not matches:
            failures.append(f"{path_label}: `{type_name}` is not exported")
        elif len(matches) != 1 or matches[0].text != type_name:
            rendered = ", ".join(f"`{item.text}`" for item in matches)
            failures.append(
                f"{path_label}: `{type_name}` must be exported abstractly; found {rendered}"
            )
    for function_name in sorted(required_functions):
        if function_name not in texts:
            failures.append(f"{path_label}: required projection `{function_name}` is not exported")
    return failures


def check_prepared_exports(
    module_name: str, path_label: str, exports: list[ExportItem]
) -> list[str]:
    failures: list[str] = []
    for item in exports:
        if item.name is None or not item.name.startswith("Prepared"):
            continue
        if item.members is not None and (module_name, item.name) not in PREPARED_CONSTRUCTOR_ALLOWLIST:
            failures.append(
                f"{path_label}: prepared type `{item.name}` must be abstract; found `{item.text}`"
            )
    return failures


def check_cabal(cabal_text: str) -> tuple[list[str], list[str]]:
    components = parse_components(cabal_text)
    main_library = component(components, "library")
    private_library = component(components, f"library {PRIVATE_LIBRARY}")
    main_exposed = component_field(main_library, "exposed-modules")
    private_exposed = component_field(private_library, "exposed-modules")
    visibility = component_field(private_library, "visibility")
    private_source_dirs = component_field(private_library, "hs-source-dirs")
    failures: list[str] = []
    cabal_label = str(CABAL_FILE.relative_to(ROOT))
    if GENERATED_LANGUAGE_MODULE in main_exposed:
        failures.append(
            f"{cabal_label}: `{GENERATED_LANGUAGE_MODULE}` must not be exposed by the main library"
        )
    if private_exposed.count(GENERATED_LANGUAGE_MODULE) != 1:
        failures.append(
            f"{cabal_label}: `{GENERATED_LANGUAGE_MODULE}` must be exposed exactly once by `library {PRIVATE_LIBRARY}`"
        )
    if visibility != ["private"]:
        failures.append(
            f"{cabal_label}: `library {PRIVATE_LIBRARY}` must declare `visibility: private`"
        )
    if private_source_dirs != ["internal"]:
        failures.append(
            f"{cabal_label}: `library {PRIVATE_LIBRARY}` must declare `hs-source-dirs: internal`"
        )
    private_source = PRIVATE_SOURCE_ROOT.joinpath(*GENERATED_LANGUAGE_MODULE.split(".")).with_suffix(".hs")
    if not private_source.is_file():
        failures.append(
            f"{private_source.relative_to(ROOT)}: private source for `{GENERATED_LANGUAGE_MODULE}` was not found"
        )
    return failures, main_exposed


def run_policy() -> list[str]:
    cabal_text = CABAL_FILE.read_text()
    failures, main_exposed = check_cabal(cabal_text)
    parsed: dict[str, tuple[str, list[ExportItem]]] = {}

    for module_name in main_exposed:
        source = module_source(module_name)
        path_label = str(source.relative_to(ROOT))
        if not source.is_file():
            failures.append(f"{path_label}: source for exposed module `{module_name}` was not found")
            continue
        try:
            exports = parse_exports(source.read_text(), module_name)
        except ParseFailure as error:
            failures.append(f"{path_label}: {error}")
            continue
        parsed[module_name] = (path_label, exports)
        failures.extend(check_prepared_exports(module_name, path_label, exports))

    for module_name, (abstract_types, required_functions) in PROTECTED_EXPORTS.items():
        if module_name not in main_exposed:
            failures.append(
                f"{CABAL_FILE.relative_to(ROOT)}: protected module `{module_name}` is not exposed by the main library"
            )
            continue
        parsed_module = parsed.get(module_name)
        if parsed_module is None:
            continue
        path_label, exports = parsed_module
        failures.extend(
            check_export_contract(path_label, exports, abstract_types, required_functions)
        )
    return failures


def run_self_test() -> None:
    accepted = """module Example.Accepted
  ( PreparedExample,
    preparedExampleImpact,
  )
where
"""
    rejected = """module Example.Rejected
  ( PreparedExample (..),
    PreparedFuture (PreparedFuture),
  )
where
"""
    accepted_exports = parse_exports(accepted, "Example.Accepted")
    accepted_failures = check_export_contract(
        "accepted.hs", accepted_exports, {"PreparedExample"}, {"preparedExampleImpact"}
    ) + check_prepared_exports("Example.Accepted", "accepted.hs", accepted_exports)
    if accepted_failures:
        raise AssertionError(f"accepted fixture failed: {accepted_failures}")

    rejected_exports = parse_exports(rejected, "Example.Rejected")
    rejected_failures = check_export_contract(
        "rejected.hs", rejected_exports, {"PreparedExample"}, {"preparedExampleImpact"}
    ) + check_prepared_exports("Example.Rejected", "rejected.hs", rejected_exports)
    if len(rejected_failures) != 4:
        raise AssertionError(f"rejected fixture produced unexpected failures: {rejected_failures}")
    print("keiro-dsl API boundary policy self-test: OK")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    arguments = parser.parse_args()
    if arguments.self_test:
        run_self_test()
        return
    try:
        failures = run_policy()
    except ParseFailure as error:
        failures = [str(error)]
    if failures:
        for failure in failures:
            print(f"keiro-dsl API boundary policy: {failure}", file=sys.stderr)
        raise SystemExit(1)
    print("keiro-dsl API boundary policy: OK")


if __name__ == "__main__":
    main()
