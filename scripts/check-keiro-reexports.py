#!/usr/bin/env python3
"""Every keiro-core module that generated code imports must be re-exported by keiro.

A consumer of a generated service is expected to need one direct `keiro`
dependency. The scaffolder emits imports of `keiro-core` modules as string
literals, so a new public `keiro-core` module reaches consumer source without
anything forcing `keiro` to re-export it. The in-repo conformance suites cannot
catch the omission because they depend on `keiro-core` directly.

That gap has shipped twice: `Keiro.Codec.IdDomain` in 0.7.0.0, and
`Keiro.Codec.Base16Bytes` / `.CalendarDay` / `.TextSet` were caught only at the
0.18.0.0 release gate. This policy replaces the prose reminder with a check.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE_CABAL = ROOT / "keiro-core" / "keiro-core.cabal"
KEIRO_CABAL = ROOT / "keiro" / "keiro.cabal"
EMITTER_ROOT = ROOT / "keiro-dsl" / "src"

# Modules named in emitter string literals that generated code does not import.
# Keep this empty unless a mention is provably not an import; a wrong entry here
# silently restores the gap this policy exists to close.
ALLOWLIST: set[str] = set()

STRING_LITERAL = re.compile(r'"(?:[^"\\]|\\.)*"')
MODULE_TOKEN = re.compile(r"[A-Z][A-Za-z0-9_.']*")


def exposed_modules(cabal: Path) -> set[str]:
    """The `exposed-modules` of the cabal file's top-level `library` stanza."""
    text = cabal.read_text()
    match = re.search(r"^library\s*$", text, re.MULTILINE)
    if not match:
        raise SystemExit(f"{cabal}: no top-level library stanza")
    rest = text[match.end() :]
    end = re.search(
        r"^(library|executable|test-suite|benchmark|foreign-library)\b",
        rest,
        re.MULTILINE,
    )
    stanza = rest[: end.start()] if end else rest
    field = re.search(r"^  exposed-modules:(.*?)(?=^  \S)", stanza, re.MULTILINE | re.DOTALL)
    if not field:
        raise SystemExit(f"{cabal}: library stanza has no exposed-modules")
    return {
        token
        for line in field.group(1).splitlines()
        for token in MODULE_TOKEN.findall(line.strip())
        if token
    }


def reexported_modules(cabal: Path) -> set[str]:
    """The keiro-core modules re-exported by keiro, without the package prefix."""
    text = cabal.read_text()
    field = re.search(
        r"^  reexported-modules:(.*?)(?=^  \S)", text, re.MULTILINE | re.DOTALL
    )
    if not field:
        raise SystemExit(f"{cabal}: no reexported-modules field")
    found: set[str] = set()
    for line in field.group(1).splitlines():
        entry = line.strip().rstrip(",")
        if entry.startswith("keiro-core:"):
            found.add(entry.split(":", 1)[1])
    return found


def display(path: Path) -> str:
    """Repo-relative where possible; an explicit --emitter-root may sit outside."""
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def imported_in_emitters(core_modules: set[str], root: Path) -> dict[str, list[str]]:
    """Map each keiro-core module mentioned in an emitter string literal to its sites."""
    sites: dict[str, list[str]] = {}
    for source in sorted(root.rglob("*.hs")):
        for number, line in enumerate(source.read_text().splitlines(), start=1):
            for literal in STRING_LITERAL.findall(line):
                for token in MODULE_TOKEN.findall(literal):
                    if token in core_modules:
                        sites.setdefault(token, []).append(f"{display(source)}:{number}")
    return sites


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--core-cabal", type=Path, default=CORE_CABAL, help=argparse.SUPPRESS
    )
    parser.add_argument(
        "--keiro-cabal", type=Path, default=KEIRO_CABAL, help=argparse.SUPPRESS
    )
    parser.add_argument(
        "--emitter-root", type=Path, default=EMITTER_ROOT, help=argparse.SUPPRESS
    )
    args = parser.parse_args()

    core = exposed_modules(args.core_cabal)
    reexported = reexported_modules(args.keiro_cabal)
    sites = imported_in_emitters(core, args.emitter_root)

    missing = {
        module: where
        for module, where in sites.items()
        if module not in reexported and module not in ALLOWLIST
    }

    if missing:
        print("keiro re-export policy: FAILED", file=sys.stderr)
        print(
            "\nGenerated code imports these keiro-core modules, but keiro does not\n"
            "re-export them. A consumer with only a direct `keiro` dependency cannot\n"
            "compile its own generated service.\n",
            file=sys.stderr,
        )
        for module in sorted(missing):
            print(f"  {module}", file=sys.stderr)
            for where in missing[module][:3]:
                print(f"      emitted at {where}", file=sys.stderr)
        print(
            "\nAdd each to `reexported-modules` in keiro/keiro.cabal as\n"
            "`keiro-core:<module>,` and record it in keiro's changelog.",
            file=sys.stderr,
        )
        return 1

    stale = sorted(ALLOWLIST - sites.keys())
    if stale:
        print("keiro re-export policy: FAILED", file=sys.stderr)
        print(
            "\nThese allowlist entries are no longer mentioned by any emitter and\n"
            "should be removed, so the allowlist cannot hide a future omission:\n",
            file=sys.stderr,
        )
        for module in stale:
            print(f"  {module}", file=sys.stderr)
        return 1

    print(f"keiro re-export policy: OK ({len(sites)} generated-import module(s) checked)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
