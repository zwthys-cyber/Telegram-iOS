#!/bin/bash
set -euo pipefail
if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  echo "Tests run exclusively on GitHub Actions." >&2
  exit 1
fi
test_dir="$RUNNER_TEMP/by-plugin-tests"
mkdir -p "$test_dir"
xcrun swiftc -warnings-as-errors \
  Swiftgram/SGSimpleSettings/Sources/BYPlugin.swift \
  Plugins/BYPlugin/Tests/BridgeTests.swift -o "$test_dir/bridge-tests"
"$test_dir/bridge-tests" absent
for scenario in enabled legacy disabled incompatible; do
  extra=(-DBY_PLUGIN_FEATURES=127)
  if [[ "$scenario" == "legacy" ]]; then extra=(-DBY_PLUGIN_FEATURES=63); fi
  if [[ "$scenario" == "disabled" ]]; then extra=(-DBY_PLUGIN_FEATURES=0); fi
  if [[ "$scenario" == "incompatible" ]]; then extra=(-DBY_PLUGIN_ABI=2); fi
  xcrun clang -dynamiclib -Wall -Wextra -Werror -fvisibility=hidden \
    "${extra[@]}" Plugins/BYPlugin/Sources/BYPlugin.c -o "$test_dir/$scenario.dylib"
  DYLD_INSERT_LIBRARIES="$test_dir/$scenario.dylib" "$test_dir/bridge-tests" "$scenario"
done
xcrun swiftc -warnings-as-errors \
  submodules/TelegramUI/Sources/AppStorageContainer.swift \
  .github/scripts/AppStorageContainerTests.swift -o "$test_dir/storage-tests"
"$test_dir/storage-tests"
xcrun swiftc -warnings-as-errors \
  submodules/TelegramCore/Sources/Network/DownloadPartAlignment.swift \
  .github/scripts/DownloadPartAlignmentTests.swift -o "$test_dir/download-tests"
"$test_dir/download-tests"

xcrun swiftc -warnings-as-errors \
  submodules/PasscodeCore/Sources/PasscodeEnvironment.swift \
  submodules/PasscodeCore/Sources/PasscodeCrypto.swift \
  Plugins/BYPlugin/Tests/PasscodeEnvironmentTests.swift -o "$test_dir/passcode-tests"
"$test_dir/passcode-tests"
