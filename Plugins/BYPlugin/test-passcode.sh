#!/bin/bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == "true" ]] || { echo "Use GitHub Actions."; exit 1; }
test_dir="$RUNNER_TEMP/by-plugin-passcode-tests"
mkdir -p "$test_dir"
sources=(
  submodules/PasscodeCore/Sources/PasscodeEnvironment.swift
  submodules/PasscodeCore/Sources/PasscodeCrypto.swift
  Plugins/BYPlugin/Tests/PasscodeEnvironmentTests.swift
)
xcrun swiftc -warnings-as-errors "${sources[@]}" -o "$test_dir/passcode-tests"
"$test_dir/passcode-tests"
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun swiftc -warnings-as-errors -sdk "$sdk" -target arm64-apple-ios15.0-simulator \
  "${sources[@]}" -o "$test_dir/passcode-ios-tests"
device=$(xcrun simctl create "BYPlugin Keychain Scope" com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-27-0)
trap 'xcrun simctl shutdown "$device" >/dev/null 2>&1 || true; xcrun simctl delete "$device" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
xcrun simctl spawn "$device" "$test_dir/passcode-ios-tests"
