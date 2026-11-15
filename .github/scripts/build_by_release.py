"""Build only on GitHub; forward cancellation to Make and its Bazel client."""
import os
from pathlib import Path
import signal
import subprocess
import sys

if os.environ.get("GITHUB_ACTIONS") != "true":
    raise SystemExit("Builds run exclusively in GitHub Actions.")
Path("build/artifacts").mkdir(parents=True, exist_ok=True)
command = [
    sys.executable, "-u", "build-system/Make/Make.py",
    "--cacheDir=" + os.environ["RUNNER_TEMP"] + "/bazel-cache", "build",
    "--configurationPath=build/unsigned-configuration.json",
    "--codesigningInformationPath=build-system/fake-codesigning",
    "--configuration=release_arm64",
    "--buildNumber=" + os.environ["GITHUB_RUN_NUMBER"],
]
process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, start_new_session=True)
interrupted = 0

def forward_signal(signum, frame):
    global interrupted
    interrupted = signum
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass

signal.signal(signal.SIGINT, forward_signal)
signal.signal(signal.SIGTERM, forward_signal)
with Path("build/build.log").open("w") as stream:
    for line in process.stdout:
        stream.write(line)
        stream.flush()
        print(line, end="", flush=True)
code = process.wait()
raise SystemExit(128 + interrupted if interrupted else (code if code >= 0 else 128 - code))
