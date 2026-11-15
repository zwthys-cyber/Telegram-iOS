#!/bin/bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == "true" ]] || { echo "Use GitHub Actions."; exit 1; }
test_dir="$RUNNER_TEMP/by-plugin-ios-tests"
mkdir -p "$test_dir"
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun swiftc -warnings-as-errors -sdk "$sdk" -target arm64-apple-ios15.0-simulator \
  Swiftgram/SGSimpleSettings/Sources/BYPlugin.swift \
  Plugins/BYPlugin/Tests/BridgeTests.swift -o "$test_dir/bridge-tests"
for scenario in enabled disabled incompatible; do
  extra=(-DBY_PLUGIN_FEATURES=63)
  if [[ "$scenario" == "disabled" ]]; then extra=(-DBY_PLUGIN_FEATURES=0); fi
  if [[ "$scenario" == "incompatible" ]]; then extra=(-DBY_PLUGIN_ABI=2); fi
  xcrun clang -isysroot "$sdk" -target arm64-apple-ios15.0-simulator \
    -dynamiclib -Wall -Wextra -Werror -fvisibility=hidden \
    "${extra[@]}" Plugins/BYPlugin/Sources/BYPlugin.c -o "$test_dir/$scenario.dylib"
done
device=$(xcrun simctl create "BYPlugin ABI" com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-27-0)
trap 'xcrun simctl shutdown "$device" >/dev/null 2>&1 || true; xcrun simctl delete "$device" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
xcrun simctl spawn "$device" "$test_dir/bridge-tests" absent
for scenario in enabled disabled incompatible; do
  SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$test_dir/$scenario.dylib" \
    xcrun simctl spawn "$device" "$test_dir/bridge-tests" "$scenario"
done
