#!/usr/bin/env bash
# run_tests.sh - run multiple gradle tests (sequential) and print summary table with mismatch details

if [ -x "./gradlew" ]; then
  GRADLE_CMD="./gradlew"
else
  GRADLE_CMD="gradle"
fi

tests=("TestIFRS9" "TestRevenue" "TestSBO" "TestGFO")
test_class="com.fyntrac.data.testdriver.ExcelTestDriver"
gradle_opts=(--no-daemon --info)
summary_file="$(mktemp)"

# header with new columns
printf "%-20s\t%-8s\t%-25s\t%-15s\t%-5s\t%-15s\t%-15s\n" "TestCaseName" "Status" "Sheet" "Column" "Row" "Expected" "Actual" > "$summary_file"
printf "%-20s\t%-8s\t%-25s\t%-15s\t%-5s\t%-15s\t%-15s\n" "--------------------" "--------" "-------------------------" "---------------" "---" "--------" "------" >> "$summary_file"

for tc in "${tests[@]}"; do
  echo
  echo "==============================="
  echo " Running test case: ${tc}"
  echo "==============================="

  # Capture gradle output in a temp file
  output_file=$(mktemp)
  "$GRADLE_CMD" clean test --tests "${test_class}" -PtestData="${tc}" "${gradle_opts[@]}" &> "$output_file"
  exit_code=$?

  if [ $exit_code -eq 0 ]; then
    status="PASSED"
    sheet=""
    column=""
    row=""
    expected=""
    actual=""
  else
    status="FAILED"

    # Extract sheet name (first occurrence)
    sheet=$(grep -m1 "Sheet '" "$output_file" | sed -n "s/.*Sheet '\([^']*\)'.*/\1/p")

    # Extract first mismatch info line (row, column, expected, actual)
    mismatch_line=$(grep -m1 "Mismatch at row" "$output_file")

    if [ -n "$mismatch_line" ]; then
      row=$(echo "$mismatch_line" | sed -n "s/.*row \([0-9]*\), column '\([^']*\)' - expected: \[\([^]]*\)\], actual: \[\([^]]*\)\].*/\1/p")
      column=$(echo "$mismatch_line" | sed -n "s/.*row \([0-9]*\), column '\([^']*\)' - expected: \[\([^]]*\)\], actual: \[\([^]]*\)\].*/\2/p")
      expected=$(echo "$mismatch_line" | sed -n "s/.*row \([0-9]*\), column '\([^']*\)' - expected: \[\([^]]*\)\], actual: \[\([^]]*\)\].*/\3/p")
      actual=$(echo "$mismatch_line" | sed -n "s/.*row \([0-9]*\), column '\([^']*\)' - expected: \[\([^]]*\)\], actual: \[\([^]]*\)\].*/\4/p")
    else
      row=""
      column=""
      expected=""
      actual=""
    fi
  fi

  printf "%-20s\t%-8s\t%-25s\t%-15s\t%-5s\t%-15s\t%-15s\n" "${tc}" "${status}" "${sheet}" "${column}" "${row}" "${expected}" "${actual}" >> "$summary_file"

  rm -f "$output_file"
done

echo
echo "==================== TEST SUMMARY ===================="
if command -v column >/dev/null 2>&1; then
  column -t -s $'\t' "$summary_file"
else
  cat "$summary_file"
fi
echo "======================================================"

rm -f "$summary_file"
