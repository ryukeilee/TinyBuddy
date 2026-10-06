#!/usr/bin/env python3
"""Compare prebuilt Debug bundles using their PID-bound visible-HUD marker.

Runs existing binaries directly (no build, install or Widget registration).
Normal application startup can update its existing stores; this is not a
read-only or isolated-data test. Refuses to interrupt an existing app instance.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("baseline", type=Path)
parser.add_argument("candidate", type=Path)
parser.add_argument("--pairs", type=int, default=3)
parser.add_argument("--evidence-dir", type=Path, required=True)
args = parser.parse_args()
if not 1 <= args.pairs <= 10:
    parser.error("pairs must be between 1 and 10")
binaries = {label: path.resolve() / "Contents/MacOS/TinyBuddy"
            for label, path in [("baseline", args.baseline), ("candidate", args.candidate)]}
if not all(path.is_file() for path in binaries.values()):
    parser.error("both app bundles must contain Contents/MacOS/TinyBuddy")
args.evidence_dir.mkdir(parents=True, exist_ok=True)
results = []
for pair in range(args.pairs):
    # Reverse order on alternating pairs to expose ordering/cache effects.
    order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
    for label in order:
        if subprocess.run(["/usr/bin/pgrep", "-x", "TinyBuddy"],
                          stdout=subprocess.DEVNULL).returncode != 1:
            raise RuntimeError("TinyBuddy is already running; leave it untouched")
        stem = f"startup-{pair + 1}-{label}"
        with (args.evidence_dir / f"{stem}-runtime.log").open("wb") as output:
            launched = time.monotonic()
            process = subprocess.Popen([str(binaries[label])], stdout=output, stderr=output)
            try:
                deadline = launched + 20
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise RuntimeError(f"{label} exited before visible HUD: {process.returncode}")
                    markers = subprocess.run([
                        "/usr/bin/log", "show", "--last", "30s", "--style", "compact",
                        "--predicate", f'processIdentifier == {process.pid} AND subsystem == "local.tinybuddy"',
                    ], capture_output=True, text=True, check=True, timeout=10).stdout
                    duration = re.search(r"Cold start completed duration=(\d+)ms", markers)
                    if duration and "HUD ready identifier=TinyBuddy.HUDWindow" in markers:
                        (args.evidence_dir / f"{stem}-markers.log").write_text(markers)
                        result = dict(pair=pair + 1, variant=label, pid=process.pid,
                                      process_ms=int(duration.group(1)),
                                      observed_ms=round((time.monotonic() - launched) * 1000))
                        results.append(result)
                        print(json.dumps(result), flush=True)
                        break
                    time.sleep(0.25)
                else:
                    raise TimeoutError(f"{label}: no PID-bound visible HUD marker within 20s")
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                        raise RuntimeError("owned process did not terminate cleanly")
        (args.evidence_dir / "startup-results.json").write_text(json.dumps(results, indent=2) + "\n")
        time.sleep(1)
# observed_ms includes unified-log retrieval; process_ms is the app's existing
# startup clock to visible, restored HUD. Neither is disk-cache-cold launch.
