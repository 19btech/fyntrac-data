#!/usr/bin/env python3
"""Regenerate the test_case dropdown in run_remote_tests.yml from the
folders under src/test/resources/TestDriver/, so the workflow_dispatch
choice list never has to be hand-maintained.

Run from the repository root:
    python3 .github/scripts/sync_test_case_dropdown.py
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TESTDRIVER_DIR = REPO_ROOT / "src" / "test" / "resources" / "TestDriver"
WORKFLOW_FILE = REPO_ROOT / ".github" / "workflows" / "run_remote_tests.yml"

BEGIN_MARKER = "          # BEGIN AUTO-GENERATED TEST CASES - do not edit by hand, see"
END_MARKER = "          # END AUTO-GENERATED TEST CASES"


def discover_test_cases() -> list[str]:
    return sorted(p.name for p in TESTDRIVER_DIR.iterdir() if p.is_dir())


def build_options_block(test_cases: list[str]) -> str:
    lines = [
        BEGIN_MARKER,
        "          # .github/scripts/sync_test_case_dropdown.py and the",
        '          # "Sync Test Case Dropdown" workflow that regenerates this block.',
        "          - ALL",
    ]
    lines += [f"          - {case}" for case in test_cases]
    lines.append(END_MARKER)
    return "\n".join(lines)


def main() -> int:
    content = WORKFLOW_FILE.read_text()

    pattern = re.compile(
        re.escape(BEGIN_MARKER) + r".*?" + re.escape(END_MARKER), re.DOTALL
    )
    if not pattern.search(content):
        print(f"ERROR: markers not found in {WORKFLOW_FILE}", file=sys.stderr)
        return 1

    test_cases = discover_test_cases()
    if not test_cases:
        print(f"ERROR: no test case folders found in {TESTDRIVER_DIR}", file=sys.stderr)
        return 1

    updated = pattern.sub(build_options_block(test_cases), content)

    if updated == content:
        print("Dropdown already up to date; no changes written.")
    else:
        WORKFLOW_FILE.write_text(updated)
        print(f"Updated {WORKFLOW_FILE} with {len(test_cases)} test case(s).")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
