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
    cp ${root + "/keiro/bench/GuardedCatalogWorkload.hs"} "$out/share/keiro/bench/"
    cp ${root + "/keiro/test/GuardedCatalogFixture.hs"} "$out/share/keiro/test/"
    cp ${root + "/keiro/bench/GuardedCatalogBaselineMain.hs"} "$out/share/keiro/bench/"
    mkdir -p "$out/share/keiro-test-support/src/Keiro/Test"
    cp ${root + "/keiro-test-support/src/Keiro/Test/Postgres.hs"} "$out/share/keiro-test-support/src/Keiro/Test/"
    cp ${./run-guarded-catalog-cell.py} ${./run-guarded-catalog-comparison.py} ${./summarize-guarded-catalog-evidence.py} "$out/share/scripts/"
    cat > "$out/bin/guarded-catalog-cell" <<EOF
  #!${pkgs.bash}/bin/bash
  export PATH=${runtimePath}
  exec ${pkgs.python3}/bin/python3 "$out/share/scripts/run-guarded-catalog-cell.py" "$out" "\$@"
  EOF
    chmod +x "$out/bin/guarded-catalog-cell"
''
