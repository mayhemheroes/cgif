#!/usr/bin/env bash
#
# cgif/mayhem/test.sh — RUN cgif's own meson test suite (built by mayhem/build.sh with normal flags)
# and emit a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: cgif's tests are real known-answer / golden-output tests — each tests/<name>.c
# encodes a GIF and the suite verifies the output GIF's SHA256 against tests/tests.sha256 (and the
# generated fuzz seed corpus against fuzz/seeds.sha256). They assert BYTE-EXACT OUTPUT, so a no-op /
# "exit(0)" patch (or any change that alters the encoded bytes) cannot pass. This script only RUNS the
# pre-built suite via `meson test`; it never compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

BUILDDIR="$SRC/mayhem-tests"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -d "$BUILDDIR" ]; then
  echo "missing $BUILDDIR — run mayhem/build.sh first" >&2
  emit_ctrf "meson-test" 0 1 0; exit 2
fi
if ! command -v meson >/dev/null 2>&1; then
  echo "meson not available — cannot run the test suite" >&2
  emit_ctrf "meson-test" 0 1 0; exit 2
fi

echo "=== running meson test in $BUILDDIR ==="
out="$(env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS meson test -C "$BUILDDIR" --print-errorlogs 2>&1)"; rc=$?
echo "$out"

# meson prints a summary block:  Ok: N / Expected Fail: N / Fail: N / Unexpected Pass: N / Skipped: N / Timeout: N
PASSED=$(printf '%s\n' "$out" | sed -n 's/^Ok:[[:space:]]*\([0-9][0-9]*\).*/\1/p'              | tail -1)
EXPFAIL=$(printf '%s\n' "$out" | sed -n 's/^Expected Fail:[[:space:]]*\([0-9][0-9]*\).*/\1/p'  | tail -1)
FAIL=$(printf '%s\n' "$out" | sed -n 's/^Fail:[[:space:]]*\([0-9][0-9]*\).*/\1/p'              | tail -1)
UNEXP=$(printf '%s\n' "$out" | sed -n 's/^Unexpected Pass:[[:space:]]*\([0-9][0-9]*\).*/\1/p'  | tail -1)
SKIP=$(printf '%s\n' "$out" | sed -n 's/^Skipped:[[:space:]]*\([0-9][0-9]*\).*/\1/p'           | tail -1)
TIMEOUT=$(printf '%s\n' "$out" | sed -n 's/^Timeout:[[:space:]]*\([0-9][0-9]*\).*/\1/p'        | tail -1)
: "${PASSED:=0}" "${EXPFAIL:=0}" "${FAIL:=0}" "${UNEXP:=0}" "${SKIP:=0}" "${TIMEOUT:=0}"

# Expected-fail tests are designed to fail (the e* / seed_should_fail cases) — they count as passing
# the suite's expectation. Real failures = Fail + Unexpected Pass + Timeout.
PASS_TOTAL=$(( PASSED + EXPFAIL ))
FAIL_TOTAL=$(( FAIL + UNEXP + TIMEOUT ))

# If meson produced no parseable summary, treat its exit code as the verdict.
if [ "$(( PASS_TOTAL + FAIL_TOTAL + SKIP ))" -eq 0 ]; then
  echo "could not parse meson test summary; using meson exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "meson-test" 1 0 0; exit 0; }
  emit_ctrf "meson-test" 0 1 0; exit 1
fi

emit_ctrf "meson-test" "$PASS_TOTAL" "$FAIL_TOTAL" "$SKIP"
