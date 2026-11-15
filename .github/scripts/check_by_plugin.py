"""Run source and packaging checks on GitHub, without compiling the full app."""
import json
import os
from pathlib import Path
import py_compile
import subprocess

if os.environ.get("GITHUB_ACTIONS") != "true":
    raise SystemExit("Validation is restricted to GitHub Actions.")
manifest = json.loads(Path("Plugins/BYPlugin/migration.json").read_text())
if json.loads(Path("versions.json").read_text())["app"] != manifest["upstream_version"]:
    raise SystemExit("Update the plugin migration record for the new upstream version.")
for name in manifest["adapter_files"]:
    path = Path(name)
    if path.suffix == ".swift":
        subprocess.run(["xcrun", "swiftc", "-frontend", "-parse", str(path)], check=True)
for path in Path(".github/scripts").glob("*.py"):
    py_compile.compile(str(path), doraise=True)
for path in Path("Plugins/BYPlugin").glob("*.sh"):
    subprocess.run(["bash", "-n", str(path)], check=True)
print("Adapter syntax, Python scripts and shell scripts checked.")
