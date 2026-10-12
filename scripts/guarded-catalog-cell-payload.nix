# Package already verified Linux binaries; this does not compile either revision.
# The cell protocol is owned by mori://shinzui/load-testing-infra.
{ pkgs, candidate, baseline, candidateEnvironment, baselineEnvironment, root }:
let
  runtimePath = pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.gzip pkgs.perl pkgs.procps ];
in
pkgs.runCommand "keiro-guarded-catalog-cell" { } ''
    mkdir -p "$out/bin" "$out/share/keiro/bench" "$out/share/keiro/test" "$out/share/scripts"
    cp ${candidate} "$out/bin/keiro-bench"
    cp ${baseline} "$out/bin/ordinary-baseline"
    chmod +x "$out/bin/keiro-bench" "$out/bin/ordinary-baseline"
    cp ${candidateEnvironment} "$out/share/candidate-environment.json"
    cp ${baselineEnvironment} "$out/share/enhanced-environment.json"
    cp ${root + "/keiro/bench/GuardedCatalogWorkload.hs"} "$out/share/keiro/bench/GuardedCatalogWorkload.hs"
    cp ${root + "/keiro/test/GuardedCatalogFixture.hs"} "$out/share/keiro/test/GuardedCatalogFixture.hs"
    cp ${root + "/keiro/bench/GuardedCatalogBaselineMain.hs"} "$out/share/keiro/bench/GuardedCatalogBaselineMain.hs"
    mkdir -p "$out/share/keiro-test-support/src/Keiro/Test"
    cp ${root + "/keiro-test-support/src/Keiro/Test/Postgres.hs"} "$out/share/keiro-test-support/src/Keiro/Test/Postgres.hs"
    cp ${./run-guarded-catalog-cell.py} "$out/share/scripts/run-guarded-catalog-cell.py"
    cp ${./run-guarded-catalog-comparison.py} "$out/share/scripts/run-guarded-catalog-comparison.py"
    cp ${./summarize-guarded-catalog-evidence.py} "$out/share/scripts/summarize-guarded-catalog-evidence.py"
    cat > "$out/bin/guarded-catalog-cell" <<EOF
  #!${pkgs.bash}/bin/bash
  export PATH=${runtimePath}
  exec ${pkgs.python3}/bin/python3 "$out/share/scripts/run-guarded-catalog-cell.py" "$out" "\$@"
  EOF
    chmod +x "$out/bin/guarded-catalog-cell"
    # Exercise the actual launcher before publishing its closure. Bad arguments
    # must reach our usage check, without opening a database or collecting data.
    if "$out/bin/guarded-catalog-cell" > launcher-check.log 2>&1; then
      echo "launcher accepted missing arguments" >&2
      exit 1
    fi
    ${pkgs.gnugrep}/bin/grep -F "usage: guarded-catalog-cell" launcher-check.log
    ${pkgs.python3}/bin/python3 - "$out" <<'PY'
  import json,sys
  from pathlib import Path
  p = Path(sys.argv[1])
  candidate = json.loads((p / "share/candidate-environment.json").read_text())
  baseline = json.loads((p / "share/enhanced-environment.json").read_text())
  Path("check-work.json").write_text(json.dumps({"schema":"keiro.guarded-catalog-cell-work/v1",
      "candidateCommit":candidate["candidateCommit"], "originalLibraryCommit":baseline["originalLibraryCommit"]}))
  Path("check-cell.json").write_text('{"schema":"invalid"}')
  PY
    if CELL_ENV_FILE="$PWD/check-cell.json" CELL_RUN_ID=check "$out/bin/guarded-catalog-cell" "$PWD/check-work.json" "$PWD" > identity-check.log 2>&1; then
      echo "launcher accepted an invalid cell environment" >&2
      exit 1
    fi
    ${pkgs.gnugrep}/bin/grep -F "cell execution identity mismatch" identity-check.log
    PATH=${runtimePath} shasum -a 256 /dev/null > shasum-check.log
    if KEIRO_GUARDED_CATALOG_EVIDENCE=single-ordinary "$out/bin/keiro-bench" > candidate-check.log 2>&1; then
      exit 1
    fi
    ${pkgs.gnugrep}/bin/grep -F "single-ordinary requires workload and result paths" candidate-check.log
    if "$out/bin/ordinary-baseline" > baseline-check.log 2>&1; then
      exit 1
    fi
    ${pkgs.gnugrep}/bin/grep -F "usage: ordinary-baseline" baseline-check.log
''
