"""Choose full state-sync coverage for source changes, a real smoke run for CI-only edits."""
import json
import os
from pathlib import Path
import subprocess

if os.environ.get("GITHUB_ACTIONS") != "true":
    raise SystemExit("Validation runs exclusively in GitHub Actions.")
event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
full = True
before = event.get("before", "")
if os.environ.get("GITHUB_EVENT_NAME") == "push" and before and set(before) != {"0"}:
    result = subprocess.run(
        ["git", "diff", "--name-only", before, os.environ["GITHUB_SHA"]],
        text=True, capture_output=True,
    )
    if result.returncode == 0:
        paths = result.stdout.splitlines()
        full = not paths or any(not (path.startswith(".github/") or path.endswith(".md")) for path in paths)
matrix = [
    {"label": "suite", "mode": "suite", "first": 0, "last": 0},
    {"label": "small-1", "mode": "small", "first": 1, "last": 2500},
    {"label": "small-2", "mode": "small", "first": 2501, "last": 5000},
    {"label": "large-1", "mode": "large", "first": 1, "last": 250},
    {"label": "large-2", "mode": "large", "first": 251, "last": 500},
    {"label": "large-3", "mode": "large", "first": 501, "last": 750},
    {"label": "large-4", "mode": "large", "first": 751, "last": 1000},
] if full else [{"label": "runner-smoke", "mode": "large", "first": 751, "last": 752}]
with open(os.environ["GITHUB_OUTPUT"], "a") as output:
    output.write("matrix=" + json.dumps(matrix) + "\n")
print("Full source validation" if full else "CI-only change: real large/jitter runner smoke")
