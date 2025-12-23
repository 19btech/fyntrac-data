#!/usr/bin/env bash
# run_tests.sh - run multiple gradle tests (sequential) and print summary table

# prefer ./gradlew if it exists
if [ -x "./gradlew" ]; then
  GRADLE_CMD="./gradlew"
else
  GRADLE_CMD="gradle"
fi

# your test case names
tests=("TestIFRS9" "TestRevenue" "TestSBO" "TestGFO" "IFRS9_Stage3" "TestEvent" "TestAsset" "TestSBO_Replay_M1" "TestSBO_Replay_M2")

# fully qualified test class to run
test_class="com.fyntrac.data.testdriver.ExcelTestDriver"

# gradle options
gradle_opts=(--no-daemon --info)

# temporary files
summary_file="$(mktemp)"
log_file="$(mktemp)"

# header
printf "%-20s\t%-8s\n" "TestCaseName" "Status" > "$summary_file"
printf "%-20s\t%-8s\n" "--------------------" "--------" >> "$summary_file"

# run each test sequentially
for tc in "${tests[@]}"; do
  echo
  echo "==============================="
  echo " Running test case: ${tc}"
  echo "==============================="

  # run gradle and capture output
  "$GRADLE_CMD" clean test \
    --tests "${test_class}" \
    -PtestData="${tc}" \
    "${gradle_opts[@]}" \
    2>&1 | tee "$log_file"

  exit_code=${PIPESTATUS[0]}

  # default status
  status="PASSED"

  # failure conditions
  if [ $exit_code -ne 0 ]; then
    status="FAILED"
  elif grep -q "IndexOutOfBoundsException" "$log_file"; then
    status="FAILED"
  fi

  printf "%-20s\t%-8s\n" "${tc}" "${status}" >> "$summary_file"
done

echo
echo "==================== TEST SUMMARY ===================="
if command -v column >/dev/null 2>&1; then
  column -t -s $'\t' "$summary_file"
else
  cat "$summary_file"
fi
echo "======================================================"

# cleanup
rm -f "$summary_file" "$log_file"
