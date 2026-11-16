"""Run integration/truth validation only on an ephemeral GitHub Actions Mac."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from verify_by_truth_log import verify_truth_log

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
phases = [
    ("suite", None, {}),
    ("mutant-missing-deletion-capture", "BYPrivacyHistoryTests/testReplayKeepsVersionsAndDeletionWithoutKeepingDeletedChatMessages", {}),
    ("restored-deletion-capture", "BYPrivacyHistoryTests/testReplayKeepsVersionsAndDeletionWithoutKeepingDeletedChatMessages", {}),
    ("mutant-live-location-receipt", "BYPrivacyHistoryTests/testLiveLocationReceiptsAreSuppressedForUserAndChannelWithoutReplay", {}),
    ("restored-live-location-receipt", "BYPrivacyHistoryTests/testLiveLocationReceiptsAreSuppressedForUserAndChannelWithoutReplay", {}),
    ("mutant-missing-media-bytes", "BYPrivacyHistoryTests/testReplayArchivesPhotoVideoAndDocumentBytesAfterCacheRemoval", {}),
    ("restored-media-bytes", "BYPrivacyHistoryTests/testReplayArchivesPhotoVideoAndDocumentBytesAfterCacheRemoval", {}),
    ("mutant-missing-timed-capture", "BYPrivacyHistoryTests/testTimedAutoclearKeepsLocalPhotoWhileCanonicalMediaExpires", {}),
    ("restored-timed-capture", "BYPrivacyHistoryTests/testTimedAutoclearKeepsLocalPhotoWhileCanonicalMediaExpires", {}),
] if mode == "suite" else []
if mode in ("small", "large"):
    first = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    last = int(sys.argv[3]) if len(sys.argv) > 3 else (5000 if mode == "small" else 1000)
    if first < 1 or first > last:
        raise SystemExit("Invalid truth seed range.")
    for start in range(first, last + 1, 250):
        end = min(start + 249, last)
        phases.append((f"{mode}-{start}-{end}", "TruthSessionTests/testRandomSessionsLong", {
            "TRUTH_SEEDS": f"{start}-{end}", "TRUTH_SHAPE": mode,
            "TRUTH_TIMING": "jitter" if mode == "large" else "instant",
            "TRUTH_REPORT_DIR": str(out), "BY_HISTORY_VALIDATION": "1",
        }))
status = 0
summary = []
replay_path = Path("submodules/TelegramCore/Sources/State/Sync/StateReplay+Messages.swift")
replay_original = replay_path.read_text()
location_path = Path("submodules/TelegramCore/Sources/State/AccountViewTracker.swift")
location_original = location_path.read_text()
media_path = Path("submodules/TelegramCore/Sources/Utils/BYMessageHistory.swift")
media_original = media_path.read_text()
timer_path = Path("submodules/TelegramCore/Sources/State/ManagedAutoremoveMessageOperations.swift")
timer_original = timer_path.read_text()
for name, test_filter, environment in phases:
    mutant = name.startswith("mutant-")
    if name == "mutant-missing-deletion-capture":
        hook = "        byArchiveDeletedMessages(transaction: transaction, mediaBox: mediaBox, ids: transaction.messageIdsForGlobalIds(ids))"
        if replay_original.count(hook) != 1:
            raise SystemExit("Mutation target changed; review the regression check.")
        replay_path.write_text(replay_original.replace(hook, "        // Test mutant: deletion capture deliberately disabled."))
    if name == "mutant-live-location-receipt":
        hook = "    let messageIds = messageIds.filter { !bySuppressContentRead(transaction: transaction, id: $0) }"
        if location_original.count(hook) != 1:
            raise SystemExit("Live-location mutation target changed; review the regression check.")
        location_path.write_text(location_original.replace(hook, "    let messageIds = messageIds.filter { _ in true }"))
    if name == "mutant-missing-media-bytes":
        hook = "sourcePath: mediaBox.completedResourcePath(file.resource)"
        if media_original.count(hook) != 1:
            raise SystemExit("Media mutation target changed; review the regression check.")
        media_path.write_text(media_original.replace(hook, "sourcePath: nil"))
    if name == "mutant-missing-timed-capture":
        hook = "                        byCaptureTimedMessage(transaction: transaction, mediaBox: postbox.mediaBox, message: message, expired: true)"
        if timer_original.count(hook) != 1:
            raise SystemExit("Timer mutation target changed; review the regression check.")
        timer_path.write_text(timer_original.replace(hook, "                        // Test mutant: timed capture deliberately disabled."))
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
    replay_path.write_text(replay_original)
    location_path.write_text(location_original)
    media_path.write_text(media_original)
    timer_path.write_text(timer_original)
    testlog = Path("bazel-testlogs/submodules/TelegramCore/TelegramCoreTests/test.log")
    if testlog.exists():
        shutil.copy2(testlog, out / (name + ".test.log"))
        text = testlog.read_text(errors="replace")
        for line in text.splitlines():
            if "Executed " in line or ("BYPrivacyHistoryTests" in line and ("passed" in line or "failed" in line)) or "TRUTH summary" in line:
                print(line, flush=True)
        summaries = re.findall(r"TRUTH summary[^\r\n]*", text)
        if not re.search(r"Executed [1-9]\d* tests?", text):
            print("ERROR: no executed XCTest cases in test.log", flush=True)
            code = code or 1
        if mutant:
            marker = "XCTAssertFalse failed" if name == "mutant-live-location-receipt" else ("XCTUnwrap failed" if name == "mutant-missing-timed-capture" else "XCTAssertNotNil failed")
            expected_failure = code != 0 and marker in text
            print(name + " detected:", expected_failure, flush=True)
            code = 0 if expected_failure else 1
        if "TRUTH_SEEDS" in environment:
            first, last = map(int, environment["TRUTH_SEEDS"].split("-"))
            try:
                summaries = [verify_truth_log(text, first, last, code)]
                print(summaries[0], flush=True)
            except ValueError as error:
                print("ERROR: incomplete or failing truth coverage:", error, flush=True)
                code = code or 1
        summary.extend(summaries)
    elif code == 0:
        code = 1
    summary.append(f"{name}: exit={code}")
    (out / "summary.txt").write_text("\n".join(summary) + "\n")
    status = max(status, int(code != 0))
    if code:
        break
Path(".bazelrc").write_text(original_rc)
raise SystemExit(status)
