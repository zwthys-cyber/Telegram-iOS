"""Configure the ephemeral GitHub runner, never the user's server."""
import os
from pathlib import Path
import subprocess

if os.environ.get("GITHUB_ACTIONS") != "true":
    raise SystemExit("This task is built and validated exclusively in GitHub Actions.")
cpu = int(subprocess.check_output(["sysctl", "-n", "hw.ncpu"], text=True))
memory = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True))
jobs = max(1, min(cpu, memory // (2 * 1024 ** 3)))
with Path(".bazelrc").open("a") as stream:
    stream.write(f"\nbuild --features=disable_legacy_signing\nbuild --jobs={jobs}\n")
print(f"ARM64 build: {cpu} CPUs, {memory // 1024 ** 3} GiB RAM, {jobs} concurrent actions.")
