from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check-keiro-reexports.py"

SPEC = importlib.util.spec_from_file_location("check_keiro_reexports", SCRIPT)
assert SPEC and SPEC.loader
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


CORE_CABAL = """\
name: keiro-core
version: 0.1.0.0

library
  import: warnings, shared
  exposed-modules:
    Keiro.Codec
    Keiro.Codec.CalendarDay
    Keiro.Codec.Refined
    Keiro.Prelude

  hs-source-dirs: src
  build-depends:
    base >=4.21 && <5,
"""

KEIRO_CABAL = """\
name: keiro
version: 0.1.0.0

library
  reexported-modules:
    keiro-core:Keiro.Codec,
    keiro-core:Keiro.Codec.CalendarDay,
    keiro-core:Keiro.Prelude,

  hs-source-dirs: src
"""


class ParsingTest(unittest.TestCase):
    """The policy is only as good as its reading of the two cabal files."""

    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.core = self.root / "keiro-core.cabal"
        self.keiro = self.root / "keiro.cabal"
        self.core.write_text(CORE_CABAL)
        self.keiro.write_text(KEIRO_CABAL)
        self.emitters = self.root / "src"
        self.emitters.mkdir()

    def tearDown(self) -> None:
        self.directory.cleanup()

    def test_reads_exposed_modules_from_the_library_stanza(self) -> None:
        self.assertEqual(
            CHECKER.exposed_modules(self.core),
            {"Keiro.Codec", "Keiro.Codec.CalendarDay", "Keiro.Codec.Refined", "Keiro.Prelude"},
        )

    def test_reads_reexports_and_drops_the_package_prefix(self) -> None:
        self.assertEqual(
            CHECKER.reexported_modules(self.keiro),
            {"Keiro.Codec", "Keiro.Codec.CalendarDay", "Keiro.Prelude"},
        )

    def test_finds_modules_named_inside_emitted_import_literals(self) -> None:
        (self.emitters / "Scaffold.hs").write_text(
            'emit = ["import Keiro.Codec.CalendarDay (encodeCalendarDay)"]\n'
        )
        sites = CHECKER.imported_in_emitters(
            CHECKER.exposed_modules(self.core), self.emitters
        )
        self.assertIn("Keiro.Codec.CalendarDay", sites)

    def test_ignores_a_real_haskell_import_outside_a_string_literal(self) -> None:
        # keiro-dsl's own library imports Keiro.Codec.Refined directly. That is
        # not generated-code surface and must not demand a re-export.
        (self.emitters / "TypeGraph.hs").write_text(
            "import Keiro.Codec.Refined (base16BytesCodecPolicyIdentity)\n"
        )
        sites = CHECKER.imported_in_emitters(
            CHECKER.exposed_modules(self.core), self.emitters
        )
        self.assertNotIn("Keiro.Codec.Refined", sites)

    def test_ignores_a_module_that_is_not_part_of_keiro_core(self) -> None:
        (self.emitters / "Scaffold.hs").write_text(
            'emit = ["import Keiro.Dsl.Grammar (TypeExpr (..))"]\n'
        )
        sites = CHECKER.imported_in_emitters(
            CHECKER.exposed_modules(self.core), self.emitters
        )
        self.assertEqual(sites, {})


class PolicyTest(unittest.TestCase):
    """End-to-end: the exit status is what `just verify` consumes."""

    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.core = self.root / "keiro-core.cabal"
        self.keiro = self.root / "keiro.cabal"
        self.core.write_text(CORE_CABAL)
        self.emitters = self.root / "src"
        self.emitters.mkdir()

    def tearDown(self) -> None:
        self.directory.cleanup()

    def run_policy(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--core-cabal",
                str(self.core),
                "--keiro-cabal",
                str(self.keiro),
                "--emitter-root",
                str(self.emitters),
            ],
            capture_output=True,
            text=True,
        )

    def test_passes_when_every_generated_import_is_reexported(self) -> None:
        self.keiro.write_text(KEIRO_CABAL)
        (self.emitters / "Scaffold.hs").write_text(
            'emit = ["import Keiro.Codec.CalendarDay (encodeCalendarDay)"]\n'
        )
        self.assertEqual(self.run_policy().returncode, 0)

    def test_fails_when_a_generated_import_is_not_reexported(self) -> None:
        # This is the 0.7.0.0 Keiro.Codec.IdDomain defect, and the
        # Keiro.Codec.CalendarDay one caught at the 0.18.0.0 release gate.
        self.keiro.write_text(KEIRO_CABAL.replace("    keiro-core:Keiro.Codec.CalendarDay,\n", ""))
        (self.emitters / "Scaffold.hs").write_text(
            'emit = ["import Keiro.Codec.CalendarDay (encodeCalendarDay)"]\n'
        )
        result = self.run_policy()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Keiro.Codec.CalendarDay", result.stderr)

    def test_fails_on_a_stale_allowlist_entry(self) -> None:
        # A stale entry is how this policy would rot into uselessness: it would
        # keep excusing a module long after the reason expired.
        self.keiro.write_text(KEIRO_CABAL)
        (self.emitters / "Scaffold.hs").write_text("emit = []\n")
        argv = [
            str(SCRIPT),
            "--core-cabal",
            str(self.core),
            "--keiro-cabal",
            str(self.keiro),
            "--emitter-root",
            str(self.emitters),
        ]
        original_allowlist = CHECKER.ALLOWLIST
        original_argv = sys.argv
        try:
            CHECKER.ALLOWLIST = {"Keiro.Codec.Refined"}
            sys.argv = argv
            self.assertEqual(CHECKER.main(), 1)
        finally:
            CHECKER.ALLOWLIST = original_allowlist
            sys.argv = original_argv

    def test_allows_an_allowlisted_module_that_is_still_mentioned(self) -> None:
        self.keiro.write_text(KEIRO_CABAL)
        (self.emitters / "Scaffold.hs").write_text(
            'note = ["Keiro.Codec.Refined is not an import"]\n'
        )
        argv = [
            str(SCRIPT),
            "--core-cabal",
            str(self.core),
            "--keiro-cabal",
            str(self.keiro),
            "--emitter-root",
            str(self.emitters),
        ]
        original_allowlist = CHECKER.ALLOWLIST
        original_argv = sys.argv
        try:
            CHECKER.ALLOWLIST = {"Keiro.Codec.Refined"}
            sys.argv = argv
            self.assertEqual(CHECKER.main(), 0)
        finally:
            CHECKER.ALLOWLIST = original_allowlist
            sys.argv = original_argv


if __name__ == "__main__":
    unittest.main()
