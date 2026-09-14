#!/usr/bin/env bash
# run_single_test.sh - run one gradle test case and print summary table
#
# Usage: ./run_single_test.sh <TestCaseName>

set -u

tc="${1:-}"
if [ -z "$tc" ]; then
  echo "Usage: $0 <TestCaseName>" >&2
  exit 2
fi

# prefer ./gradlew if it exists
if [ -x "./gradlew" ]; then
  GRADLE_CMD="./gradlew"
else
  GRADLE_CMD="gradle"
fi

# fully qualified test class to run
test_class="com.fyntrac.data.testdriver.ExcelTestDriver"

# gradle options (same as run_tests.sh)
gradle_opts=(--no-daemon --info)

# temporary file for summary
summary_file="$(mktemp)"

# header
printf "%-20s\t%-8s\n" "TestCaseName" "Status" > "$summary_file"
printf "%-20s\t%-8s\n" "--------------------" "--------" >> "$summary_file"

echo
echo "==============================="
echo " Running test case: ${tc}"
echo "==============================="

"$GRADLE_CMD" clean test --tests "${test_class}" -PtestData="${tc}" "${gradle_opts[@]}"
exit_code=$?

if [ $exit_code -eq 0 ]; then
  status="PASSED"
else
  status="FAILED"
fi

printf "%-20s\t%-8s\n" "${tc}" "${status}" >> "$summary_file"

echo
echo "==================== TEST SUMMARY ===================="
if command -v column >/dev/null 2>&1; then
  column -t -s $'\t' "$summary_file"
else
  cat "$summary_file"
fi
echo "======================================================"

# cleanup
rm -f "$summary_file"

exit $exit_code
