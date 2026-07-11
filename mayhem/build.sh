#!/usr/bin/env bash
#
# cgif/mayhem/build.sh — build dloebl/cgif's three OSS-Fuzz harnesses as sanitized libFuzzer
# targets (+ standalone reproducers), AND cgif's own meson test suite for mayhem/test.sh.
#
# The fuzzed surface is cgif's GIF ENCODER on attacker-controlled config/frame bytes:
#   cgif_fuzzer      — indexed API: parses CGIF_Config + CGIF_FrameConfig structs from the input
#                      and drives cgif_newgif/cgif_addframe/cgif_close (output discarded via callback).
#   cgif_file_fuzzer — same indexed surface, but cgif writes the encoded GIF to a temp file
#                      (gconfig.path = /tmp/out.gif) instead of a write callback.
#   cgif_rgb_fuzzer  — RGB API: parses CGIFrgb_Config + CGIFrgb_FrameConfig and drives
#                      cgif_rgb_newgif/cgif_rgb_addframe/cgif_rgb_close (quantization + encode).
# Inputs are NOT raw .gif files — they are the binary struct encoding the harness's readdata() parses.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). We compile the cgif library ITSELF with $SANITIZER_FLAGS so the encoder code
# (not just the harness) is instrumented.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"
INC="-I$SRC/inc"
SRCS="src/cgif.c src/cgif_raw.c src/cgif_rgb.c"

# ── 1) Build the cgif static library WITH sanitizers (the fuzzed encoder is instrumented) ──────────
BUILD="$SRC/mayhem-build"
mkdir -p "$BUILD"
OBJS=()
for s in $SRCS; do
  obj="$BUILD/$(basename "${s%.c}").o"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $INC -c "$s" -o "$obj"
  OBJS+=("$obj")
done
LIBCGIF="$BUILD/libcgif.a"
rm -f "$LIBCGIF"; ar rcs "$LIBCGIF" "${OBJS[@]}"

# Standalone driver (cgif ships its own single-file run-once driver: fuzz/cgif_fuzzer_standalone.c).
# Compile it as an object once; it has no libFuzzer runtime and reads one input file.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$HARNESS_DIR/cgif_fuzzer_standalone.c" -o "$BUILD/standalone_main.o"

# ── 2) Build each OSS-Fuzz harness twice: libFuzzer (-> /mayhem/<name>) + standalone reproducer ────
for harness in cgif_fuzzer cgif_file_fuzzer cgif_rgb_fuzzer; do
  # libFuzzer target -> /mayhem/<name>
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $INC \
      "$HARNESS_DIR/$harness.c" $LIB_FUZZING_ENGINE "$LIBCGIF" -lm \
      -o "/mayhem/$harness"

  # standalone reproducer (no libFuzzer runtime) -> /mayhem/<name>-standalone
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $INC \
      "$HARNESS_DIR/$harness.c" "$BUILD/standalone_main.o" "$LIBCGIF" -lm \
      -o "/mayhem/$harness-standalone"

  echo "built $harness (+ standalone)"
done

# ── 3) Build cgif's OWN meson test suite with NORMAL flags (clean, separate tree) so test.sh
#       only RUNS it. -Dfuzzer=true also builds the standalone fuzzers + the seed-corpus genseed
#       programs and wires the sha256 known-answer checks (tests/tests.sha256, fuzz/seeds.sha256). ──
if command -v meson >/dev/null 2>&1; then
  # Normal flags here (env -u CFLAGS/CXXFLAGS): keeps test.sh an honest PATCH oracle and avoids
  # sanitizer/benign-UB noise. Static lib so the test binaries are self-contained.
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
    meson setup --reconfigure "$SRC/mayhem-tests" "$SRC" \
      -Dtests=true -Dfuzzer=true -Dexamples=true --default-library=static \
    || env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
       meson setup "$SRC/mayhem-tests" "$SRC" \
         -Dtests=true -Dfuzzer=true -Dexamples=true --default-library=static
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
    meson compile -C "$SRC/mayhem-tests" -j"$MAYHEM_JOBS"
  echo "built cgif meson test suite in mayhem-tests/"
else
  echo "WARNING: meson not found — test suite not built (mayhem/test.sh will fail loudly)" >&2
fi

echo "build.sh complete:"
ls -la /mayhem/cgif_fuzzer /mayhem/cgif_file_fuzzer /mayhem/cgif_rgb_fuzzer \
       /mayhem/cgif_fuzzer-standalone /mayhem/cgif_file_fuzzer-standalone /mayhem/cgif_rgb_fuzzer-standalone 2>&1 || true
