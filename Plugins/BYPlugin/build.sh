#!/bin/bash
set -euo pipefail
if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  echo "Build this project with GitHub Actions; local builds are disabled by project policy." >&2
  exit 1
fi
features="${BY_PLUGIN_FEATURES:-511}"
if ! [[ "$features" =~ ^[0-9]{1,3}$ ]] || ((10#$features > 511)); then
  echo "BY_PLUGIN_FEATURES must be an integer from 0 to 511." >&2
  exit 1
fi
features=$((10#$features))
output_dir="${1:-build/plugin}"
mkdir -p "$output_dir"
xcrun --sdk iphoneos clang \
  -target arm64-apple-ios15.0 \
  -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -dynamiclib -DBY_PLUGIN_FEATURES="$features" -O2 -Wall -Wextra -Werror -fvisibility=hidden \
  -install_name @rpath/BYPlugin.dylib \
  -Wl,-no_adhoc_codesign \
  Plugins/BYPlugin/Sources/BYPlugin.c -o "$output_dir/BYPlugin.dylib"
xcrun lipo -verify_arch arm64 "$output_dir/BYPlugin.dylib"
xcrun otool -L "$output_dir/BYPlugin.dylib"
xcrun nm -gU "$output_dir/BYPlugin.dylib" > "$output_dir/exports.txt"
for symbol in BYPluginABIVersion BYPluginFeatureFlags BYPluginDownloadPartSize BYPluginPendingParts; do
  grep -q " _$symbol$" "$output_dir/exports.txt"
done
xcrun otool -l "$output_dir/BYPlugin.dylib" > "$output_dir/load-commands.txt"
grep -Eq 'platform[[:space:]]+(2|IOS)$' "$output_dir/load-commands.txt"
if grep -q LC_CODE_SIGNATURE "$output_dir/load-commands.txt"; then
  echo "The plugin must be signed by the IPA signing tool, not CI." >&2
  exit 1
fi
python3 - "$output_dir/plugin.json" "$features" <<'PY'
import json
import os
import sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "plugin_version": "2.0",
    "host_abi": 1,
    "feature_flags": int(sys.argv[2]),
    "commit": os.environ["GITHUB_SHA"],
    "signed": False,
}, indent=2) + "\n")
PY
cp Plugins/BYPlugin/README.md "$output_dir/README.md"
(cd "$output_dir" && shasum -a 256 BYPlugin.dylib > SHA256SUMS.txt)
