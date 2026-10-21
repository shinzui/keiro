"""Qualify fresh pre-change capacity for a declared matched RTS profile."""
from pathlib import Path
import hashlib,json,subprocess
root=Path("keiro/bench/results/inspection/prechange-writer-capacity-n8-a16m")
binary=Path("/tmp/keiro-http-n8-prechange")
command=[str(binary),str(root),"saturation","5","unmounted","+RTS","-N8","-A16m","-T","-RTS"]
manifest={"baseline_commit":"3bf3ac229f21d6c95179ce49b5e8f6323322f99b","rts":["-N8","-A16m","-T"],"ghc":"9.12.4","library_optimization":"O1","driver_optimization":"O2","binary_sha256":hashlib.sha256(binary.read_bytes()).hexdigest(),"driver_sha256":hashlib.sha256((root/"driver.hs").read_bytes()).hexdigest(),"runner_sha256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),"command":command,"checkpoint_before_writer_warmup":True,"selection_rule":"75% of minimum of five pre-change saturation throughputs rounded down to nearest ten; paced headroom qualification uses fixed 20% reductions"}
(root/"manifest.json").write_text(json.dumps(manifest,indent=2)+"\n")
subprocess.run(command,check=True)
