"""Run integration/truth validation only on an ephemeral GitHub Actions Mac."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

if os.environ.get("GITHUB_ACTIONS") != "true":
    raise SystemExit("Validation runs exclusively in GitHub Actions.")
mode = sys.argv[1]
out = Path("build/privacy-tests").resolve()
out.mkdir(parents=True, exist_ok=True)
runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "-j"]))["runtimes"]
ios = [r for r in runtimes if r.get("isAvailable") and "iOS" in r["name"]]
runtime = max(ios, key=lambda r: tuple(int(v) for v in r["version"].split(".")))
build = Path("submodules/TelegramCore/BUILD")
build.write_text(build.read_text().replace('os_version = "26.5"', 'os_version = "' + runtime["version"] + '"'))
print("Integration runtime:", runtime["name"], flush=True)
original_rc = Path(".bazelrc").read_text()
make = [sys.executable, "-u", "build-system/Make/Make.py",
        "--cacheDir=" + os.environ["RUNNER_TEMP"] + "/bazel-cache", "test",
        "--configurationPath=build/unsigned-configuration.json",
        "--codesigningInformationPath=build-system/fake-codesigning",
        "--target=//submodules/TelegramCore:TelegramCoreTests"]
phases = [("suite", None, {})] if mode == "suite" else []
if mode in ("small", "large"):
    last = 5000 if mode == "small" else 1000
    for start in range(1, last + 1, 250):
        end = min(start + 249, last)
        phases.append((f"{mode}-{start}-{end}", "TruthSessionTests/testRandomSessionsLong", {
            "TRUTH_SEEDS": f"{start}-{end}", "TRUTH_SHAPE": mode,
            "TRUTH_TIMING": "jitter" if mode == "large" else "instant",
            "TRUTH_REPORT_DIR": str(out), "BY_HISTORY_VALIDATION": "1",
        }))
status = 0
summary = []
for name, test_filter, environment in phases:
    options = "\ntest --test_timeout=21600\ntest --test_output=all\n"
    options += "".join(f"test --test_env={key}={value}\n" for key, value in environment.items())
    Path(".bazelrc").write_text(original_rc + options)
    command = make + (["--testFilter=" + test_filter] if test_filter else [])
    with (out / (name + ".log")).open("w") as stream:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in process.stdout:
            stream.write(line)
            print(line, end="", flush=True)
        code = process.wait()
    testlog = Path("bazel-testlogs/submodules/TelegramCore/TelegramCoreTests/test.log")
    if testlog.exists():
        shutil.copy2(testlog, out / (name + ".test.log"))
        text = testlog.read_text(errors="replace")
        summaries = re.findall(r"TRUTH summary[^\r\n]*", text)
        summary.extend(summaries)
        if test_filter:
            seeds = re.findall(r"TRUTH seed=(\d+)", text)
            expected = int(environment["TRUTH_SEEDS"].split("-")[1]) - int(environment["TRUTH_SEEDS"].split("-")[0]) + 1
            if len(set(seeds)) != expected or not summaries or not any("failing=0" in line for line in summaries):
                print("ERROR: incomplete or failing truth coverage", flush=True)
                code = code or 1
    elif code == 0:
        code = 1
    summary.append(f"{name}: exit={code}")
    (out / "summary.txt").write_text("\n".join(summary) + "\n")
    status = max(status, int(code != 0))
    if code:
        break
Path(".bazelrc").write_text(original_rc)
raise SystemExit(status)
