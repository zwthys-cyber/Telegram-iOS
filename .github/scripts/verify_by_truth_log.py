"""Strict truth-log validation, tolerant only of interleaved XCTest success banners."""
import argparse
from pathlib import Path
import re


_SUCCESS_BANNERS = re.compile(
    r"Test Case '[^\r\n]+' passed \(\d+(?:\.\d+)? seconds\)\.\r?\n"
    r"|Test Suite '[^\r\n]+' passed at [^\r\n]+\.\r?\n"
    r"|[ \t]*Executed [1-9]\d* tests?, with 0 failures \(0 unexpected\) in [^\r\n]+ seconds\r?\n"
)


def verify_truth_log(text, first, last, exit_code):
    if exit_code != 0:
        raise ValueError("test process did not succeed")
    if first < 1 or last < first:
        raise ValueError("invalid expected seed range")
    counts = re.findall(r"Executed (\d+) tests?, with (\d+) failures", text)
    if not counts or not any(int(n) > 0 for n, _ in counts) or any(int(f) for _, f in counts):
        raise ValueError("missing executed XCTest cases or XCTest failures")
    if re.search(r"Test (?:Case|Suite) '[^\r\n]+' failed", text):
        raise ValueError("XCTest reported a failure")
    if not re.search(r"Test Case '[^\r\n]*TruthSessionTests testRandomSessionsLong\]' passed", text):
        raise ValueError("long truth test did not pass")
    # XCTest writes its status to stderr while Swift print() uses buffered stdout.
    # Remove only complete, recognized success banners. Never join arbitrary log lines.
    normalized = _SUCCESS_BANNERS.sub("", text)
    markers = re.findall(r"TRUTH seed=(\d+)", normalized)
    records = re.findall(r"^TRUTH seed=(\d+) steps=(\d+) result=ok\r?$", normalized, re.MULTILINE)
    expected = list(range(first, last + 1))
    if sorted(int(n) for n in markers) != expected or sorted(int(n) for n, _ in records) != expected:
        raise ValueError("missing, duplicate, unexpected or non-ok truth seed")
    summaries = re.findall(r"TRUTH summary[^\r\n]*", normalized)
    expected_summary = f"TRUTH summary seeds={first}-{last} failing=0 kinds=[]"
    if summaries != [expected_summary]:
        raise ValueError("missing, malformed or nonzero truth summary")
    return expected_summary


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("test_log", type=Path)
    parser.add_argument("first", type=int)
    parser.add_argument("last", type=int)
    parser.add_argument("--build-log", type=Path, required=True)
    args = parser.parse_args()
    build_log = args.build_log.read_text(errors="replace")
    if not re.search(r"//submodules/TelegramCore:TelegramCoreTests[ \t]+PASSED", build_log):
        raise SystemExit("Recorded Bazel target did not pass.")
    if "Executed 1 out of 1 test: 1 test passes." not in build_log:
        raise SystemExit("Recorded Bazel execution count is missing.")
    result = verify_truth_log(args.test_log.read_text(errors="replace"), args.first, args.last, 0)
    print(result)
    print(f"Verified {args.last - args.first + 1} exact, unique, successful seeds from the original artifact.")
