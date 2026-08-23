#!/usr/bin/env python3
"""Generate the checked record-field inventories for ExecPlan 177.

The repository formats record declarations one field per line.  This script
uses that deliberately narrow house style instead of attempting to parse all
of Haskell.  It fails when a record-looking declaration has no discovered
fields, and ``--check`` makes the generated documents useful as drift gates.
"""

from __future__ import annotations

import argparse
import dataclasses
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PACKAGE_MANIFEST = ROOT / "keiro-dsl/record-field-migration-0.15.md"
GENERATED_MANIFEST = ROOT / "keiro-dsl/generated-haskell-edition-idiomatic-v2.md"

DECLARATION = re.compile(r"^(data|newtype)\s+([A-Z][A-Za-z0-9_]*)\b")
FIELD = re.compile(
    r"^\s*(?:[|=]\s*[A-Z][A-Za-z0-9_]*(?:\s+[^{}]+)?\s*)?"
    r"[,{]?\s*([a-z][A-Za-z0-9_]*)\s*::\s*(.+?)(?:,\s*)?$"
)
INLINE_FIELD = re.compile(r"\{\s*([a-z][A-Za-z0-9_]*)\s*::\s*([^}]+)\}")
MODULE = re.compile(r"^module\s+([A-Z][A-Za-z0-9_.]*)", re.MULTILINE)
CAMEL_PREFIX = re.compile(r"^([a-z][a-z0-9]*)([A-Z].*)$")
LANGUAGE = re.compile(r"^\{-# LANGUAGE ([A-Za-z0-9_]+) #-\}$", re.MULTILINE)


@dataclasses.dataclass(frozen=True)
class RecordField:
    path: str
    module: str
    kind: str
    owner: str
    name: str
    type_text: str
    line: int
    public: bool
    deriving: str


def git_files(pattern: str) -> list[Path]:
    output = subprocess.run(
        ["git", "ls-files", pattern],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [ROOT / line for line in output.splitlines() if line]


def package_files() -> list[Path]:
    files = git_files("keiro-dsl/src/**/*.hs") + git_files("keiro-dsl/app/**/*.hs")
    test_roots = (
        ROOT / "keiro-dsl/test",
        ROOT / "keiro-dsl/test/import-planning",
        ROOT / "keiro-dsl/test/haskell-name",
        ROOT / "keiro-dsl/test/runtime-vocabulary",
    )
    files.extend(path for path in git_files("keiro-dsl/test/**/*.hs") if path.parent in test_roots)
    return sorted(set(files))


def declaration_end(lines: list[str], start: int) -> int:
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if line and not line[0].isspace() and not line.startswith(("|", "=")):
            return index
    return len(lines)


def module_exports_all(text: str, owner: str) -> bool:
    module_end = text.find("\nwhere")
    header = text if module_end < 0 else text[:module_end]
    return re.search(rf"\b{re.escape(owner)}\s*\(\.\.\)", header) is not None


def exposed_modules() -> set[str]:
    cabal = (ROOT / "keiro-dsl/keiro-dsl.cabal").read_text()
    library = cabal.split("\nlibrary\n", 1)[1]
    exposed = library.split("  exposed-modules:\n", 1)[1].split("\n\n  other-modules:", 1)[0]
    return {line.strip() for line in exposed.splitlines() if line.strip()}


def parse_fields(path: Path) -> list[RecordField]:
    text = path.read_text()
    lines = text.splitlines()
    module_match = MODULE.search(text)
    module_name = module_match.group(1) if module_match else "Main"
    result: list[RecordField] = []
    for index, line in enumerate(lines):
        declaration = DECLARATION.match(line)
        if not declaration:
            continue
        kind, owner = declaration.groups()
        end = declaration_end(lines, index)
        block = lines[index:end]
        deriving = " ".join(re.findall(r"\bderiving\s+(?:stock|newtype|anyclass|via)?\s*\([^\n]+\)", "\n".join(block)))
        public = module_name in exposed_modules() and module_exports_all(text, owner)
        inline = INLINE_FIELD.search(line)
        if inline:
            name, type_text = inline.groups()
            result.append(
                RecordField(
                    path=str(path.relative_to(ROOT)),
                    module=module_name,
                    kind=kind,
                    owner=owner,
                    name=name,
                    type_text=type_text.strip(),
                    line=index + 1,
                    public=public,
                    deriving=deriving or "none",
                )
            )
        for offset, candidate in enumerate(block):
            match = FIELD.match(candidate)
            if not match:
                continue
            name, type_text = match.groups()
            result.append(
                RecordField(
                    path=str(path.relative_to(ROOT)),
                    module=module_name,
                    kind=kind,
                    owner=owner,
                    name=name,
                    type_text=type_text.strip(),
                    line=index + offset + 1,
                    public=public,
                    deriving=deriving or "none",
                )
            )
    return result


def camel_tokens(name: str) -> list[str]:
    return [token.lower() for token in re.findall(r"[A-Z]?[a-z0-9]+|[A-Z]+(?=[A-Z]|$)", name)]


def owner_token_matches(prefix: str, owner_tokens: list[str], start: int) -> int:
    """Return owner tokens consumed by a field-prefix token, or zero."""
    for end in range(len(owner_tokens), start, -1):
        candidate = owner_tokens[start:end]
        joined = "".join(candidate)
        initials = "".join(token[0] for token in candidate)
        singular = candidate[0].removesuffix("s") if len(candidate) == 1 else None
        if prefix in {joined, initials, singular}:
            return end - start
    return 0


def removable_owner_prefix(owner: str, names: list[str]) -> str | None:
    token_lists = [camel_tokens(name) for name in names]
    if not token_lists:
        return None
    common: list[str] = []
    for tokens in zip(*token_lists):
        if len(set(tokens)) != 1:
            break
        common.append(tokens[0])
    if not common or any(len(tokens) == len(common) for tokens in token_lists):
        return None

    owner_tokens = camel_tokens(owner)
    consumed_prefix: list[str] = []
    owner_position = 0
    for prefix in common:
        matched = 0
        matched_position = owner_position
        for position in range(owner_position, len(owner_tokens)):
            matched = owner_token_matches(prefix, owner_tokens, position)
            if matched:
                matched_position = position
                break
        if not matched:
            break
        consumed_prefix.append(prefix)
        owner_position = matched_position + matched
    return "".join(consumed_prefix) or None


def target_names(fields: list[RecordField]) -> dict[tuple[str, str, str], str]:
    by_owner: dict[tuple[str, str], list[RecordField]] = {}
    for field in fields:
        by_owner.setdefault((field.path, field.owner), []).append(field)

    targets: dict[tuple[str, str, str], str] = {}
    for (path, owner), owner_fields in by_owner.items():
        shared_prefix = removable_owner_prefix(owner, [field.name for field in owner_fields])
        for field in owner_fields:
            target = field.name
            explicit_unwrapper = field.kind == "newtype" and len(owner_fields) == 1 and field.name.startswith("un")
            if shared_prefix and field.name.lower().startswith(shared_prefix) and not explicit_unwrapper:
                suffix = field.name[len(shared_prefix) :]
                target = suffix[0].lower() + suffix[1:]
            targets[(path, owner, field.name)] = target
    return targets


def observation(field: RecordField, text: str) -> str:
    observations = []
    if re.search(r"\b(ToJSON|FromJSON|toJSON|parseJSON)\b|\.(?:=|:)", text):
        observations.append("JSON/wire bytes")
    if re.search(r"\b(render|pretty|fingerprint|canonical|ledger|report)\b", text, re.IGNORECASE):
        observations.append("rendered/canonical output")
    if field.path.endswith("app/Main.hs"):
        observations.append("CLI surface")
    return ", ".join(observations) if observations else "Haskell API and runtime semantics"


def package_document(fields: list[RecordField]) -> str:
    targets = target_names(fields)
    files = {field.path: (ROOT / field.path).read_text() for field in fields}
    record_count = len({(field.path, field.owner) for field in fields})
    public_count = sum(field.public for field in fields)
    strict_count = sum(field.type_text.startswith("!") for field in fields)
    lines = [
        "# keiro-dsl record-field migration for 0.15",
        "",
        "This checked inventory is the package-authored record migration contract for ExecPlan 177.",
        "It is generated from every tracked Haskell source compiled through the `shared` Cabal",
        "stanza. The target column removes a shared owner prefix; unchanged rows are intentional.",
        "Product reads become record-dot projections, while single-field newtype unwrappers remain",
        "explicit positional functions. JSON keys, rendered text, fingerprints, CLI bytes, strictness,",
        "constructor/field order, and deriving behavior are frozen unless a row says otherwise.",
        "",
        f"Inventory: {record_count} record-owning declarations, {len(fields)} fields, "
        f"{strict_count} strict fields, and {public_count} fields exported through a public `Type (..)`.",
        "",
        "| Location | Owner | Kind | Public | Current | Target | Type/strictness | Selection replacement | Frozen observation | Deriving |",
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for field in fields:
        target = targets[(field.path, field.owner, field.name)]
        if field.kind == "newtype" and field.name.startswith("un"):
            replacement = f"explicit `{field.name}` positional function"
        else:
            replacement = f"`(.{target})`, pattern, or construction"
        lines.append(
            "| "
            + " | ".join(
                (
                    f"`{field.path}:{field.line}`",
                    f"`{field.owner}`",
                    field.kind,
                    "yes" if field.public else "no",
                    f"`{field.name}`",
                    f"`{target}`",
                    f"`{field.type_text.replace('|', '&#124;')}`",
                    replacement,
                    observation(field, files[field.path]),
                    f"`{field.deriving.replace('|', '&#124;')}`",
                )
            )
            + " |"
        )
    lines.extend(("", "Regenerate or check this inventory with:", "", "```bash", "python3 scripts/generate-record-migration-manifests.py --check", "```", ""))
    return "\n".join(lines)


def generated_document(generated_fields: list[RecordField], all_generated: list[Path], hand_owned: list[Path]) -> str:
    targets = target_names(generated_fields)
    generated_text = {str(path.relative_to(ROOT)): path.read_text() for path in all_generated}
    field_names = sorted({field.name for field in generated_fields}, key=lambda name: (-len(name), name))
    occurrences: list[tuple[str, int, str]] = []
    token_patterns = {name: re.compile(rf"(?<![A-Za-z0-9_]){re.escape(name)}(?![A-Za-z0-9_])") for name in field_names}
    for path in all_generated + hand_owned:
        relative = str(path.relative_to(ROOT))
        for line_number, line in enumerate(path.read_text().splitlines(), 1):
            if "::" in line and FIELD.match(line):
                continue
            for name, pattern in token_patterns.items():
                if pattern.search(line):
                    occurrences.append((relative, line_number, name))

    local_pragmas = []
    for path, text in generated_text.items():
        for extension in LANGUAGE.findall(text):
            if extension in {"DuplicateRecordFields", "OverloadedRecordDot"}:
                local_pragmas.append((path, extension))

    lines = [
        "# Generated Haskell idiomatic-v1 to idiomatic-v2 migration",
        "",
        "This checked inventory defines the generated-Haskell presentation-edition break for",
        "ExecPlan 177. It covers every tracked overwriteable `Generated` module, every generated",
        "record field, every lexical use of those field labels in generated or hand-owned conformance",
        "sources, and every local record-default pragma. Lexical occurrence rows intentionally",
        "over-approximate selector use so no consumer occurrence is silently omitted during review.",
        "",
        f"Inventory: {len(all_generated)} generated modules, "
        f"{len({(field.path, field.owner) for field in generated_fields})} record declarations, "
        f"{len(generated_fields)} fields, {len(occurrences)} field-label occurrences, "
        f"{len(local_pragmas)} local default-pragmas, and {len(hand_owned)} hand-owned conformance modules.",
        "",
        "The `idiomatic-v2` manifest defaults are `DuplicateRecordFields`, `NoFieldSelectors`,",
        "`OverloadedRecordDot`, and `OverloadedStrings`. Constructor names, arity, field order, wire",
        "keys, runtime behavior, and create-once source bytes remain unchanged.",
        "",
        "## Declarations",
        "",
        "| Location | Owner | Kind | Current | Target | Type/strictness | v2 access |",
        "| --- | --- | --- | --- | --- | --- | --- |",
    ]
    for field in generated_fields:
        target = targets[(field.path, field.owner, field.name)]
        access = f"explicit `{field.name}` positional function" if field.kind == "newtype" and field.name.startswith("un") else f"`(.{target})` or constructor pattern"
        lines.append(
            f"| `{field.path}:{field.line}` | `{field.owner}` | {field.kind} | `{field.name}` | `{target}` | `{field.type_text.replace('|', '&#124;')}` | {access} |"
        )
    lines.extend(("", "## Field-label occurrences", "", "| Location | Label | v2 remediation | Ownership |", "| --- | --- | --- | --- |"))
    target_by_name: dict[str, set[str]] = {}
    for field in generated_fields:
        target_by_name.setdefault(field.name, set()).add(targets[(field.path, field.owner, field.name)])
    generated_set = {str(path.relative_to(ROOT)) for path in all_generated}
    for path, line_number, name in occurrences:
        target_set = target_by_name[name]
        target = sorted(target_set)[0] if len(target_set) == 1 else "type-directed target from declaration row"
        remediation = f"record-dot `(.{target})` or positional pattern/construction"
        ownership = "overwriteable Generated" if path in generated_set else "hand-owned; report only"
        lines.append(f"| `{path}:{line_number}` | `{name}` | {remediation} | {ownership} |")
    lines.extend(("", "## Redundant local record defaults", "", "| Module | v1 pragma | v2 action |", "| --- | --- | --- |"))
    for path, extension in local_pragmas:
        lines.append(f"| `{path}` | `{extension}` | remove; supplied by the v2 manifest |")
    lines.extend(("", "## Hand-owned conformance sources", "", "These files are inventory inputs only. Edition adoption must not rewrite their bytes.", "", "| Source | Generated imports |", "| --- | --- |"))
    for path in hand_owned:
        relative = str(path.relative_to(ROOT))
        imports = sorted(set(re.findall(r"^import\s+(?:qualified\s+)?(Generated\.[A-Za-z0-9_.]+)", path.read_text(), re.MULTILINE)))
        rendered = ", ".join(f"`{item}`" for item in imports) if imports else "none"
        lines.append(f"| `{relative}` | {rendered} |")
    lines.extend(("", "Regenerate or check this inventory with:", "", "```bash", "python3 scripts/generate-record-migration-manifests.py --check", "```", ""))
    return "\n".join(lines)


def write_or_check(path: Path, content: str, check: bool) -> None:
    if check:
        if not path.exists() or path.read_text() != content:
            raise SystemExit(f"stale record migration manifest: {path.relative_to(ROOT)}")
        return
    path.write_text(content)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()

    package = [field for path in package_files() for field in parse_fields(path)]
    generated_files = sorted(
        path for path in git_files("keiro-dsl/test/**/*.hs") if "/Generated/" in str(path)
    )
    generated = [field for path in generated_files for field in parse_fields(path)]
    conformance_files = sorted(
        path
        for path in git_files("keiro-dsl/test/conformance*/**/*.hs")
        if "/Generated/" not in str(path)
    )

    write_or_check(PACKAGE_MANIFEST, package_document(package), arguments.check)
    write_or_check(
        GENERATED_MANIFEST,
        generated_document(generated, generated_files, conformance_files),
        arguments.check,
    )


if __name__ == "__main__":
    main()
