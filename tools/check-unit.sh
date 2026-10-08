#!/usr/bin/env bash
#
# check-unit.sh -- compile+link+run host unit tests against the make-check
# objects. Each tools/unittest/*.c provides its own main(); hostmain.o is
# excluded so there is exactly one main per link. See tools/check-core.sh for
# the object build these link against; the CFLAGS mirror it.
#
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CC="${CC:-cc}"
OUT="${OUT:-${TMPDIR:-/tmp}/quakecore-hostbuild}"

CFLAGS=(
  -std=gnu99 -O0 -g0
  -DQAVP_PLATFORM -DQAVP_HOSTCHECK
  -I"$ROOT/Sources/QuakeCore/engine"
  -I"$ROOT/Sources/QuakeCore/platform"
  -I"$ROOT/Sources/QuakeCore/include"
  -I"$ROOT/Sources/QuakeRenderer/bridge"
  -Wall
  -Wno-unused-variable -Wno-unused-but-set-variable -Wno-unused-function
  -Wno-sign-compare -Wno-missing-braces -Wno-strict-aliasing
  -Wno-format-truncation -Wno-implicit-fallthrough -Wno-array-bounds
  -Wno-stringop-truncation -Wno-stringop-overflow -Wno-maybe-uninitialized
  -Wno-char-subscripts -Wno-misleading-indentation
)

# Build/refresh the object set (compiles every TU, links the host-check exe).
"$ROOT/tools/check-core.sh" >/dev/null 2>&1 || { echo "check-core failed -- run tools/check-core.sh to see why"; exit 1; }

objs=()
for o in "$OUT"/*.o; do
  [[ "$(basename "$o")" == hostmain.o ]] && continue
  objs+=("$o")
done

# Shared test-support TUs (app-side stubs hostmain.o would otherwise provide).
# Compiled fresh and linked into every test; not themselves tests.
support=()
shopt -s nullglob
for s in "$ROOT"/tools/unittest/support/*.c; do
  so="$OUT/unit_$(basename "$s" .c).o"
  "$CC" "${CFLAGS[@]}" -c -o "$so" "$s" || { echo "support compile fail: $s"; exit 1; }
  support+=("$so")
done

fail=0
for t in "$ROOT"/tools/unittest/*.c; do
  bin="$OUT/$(basename "$t" .c)"
  if ! "$CC" "${CFLAGS[@]}" -o "$bin" "$t" "${support[@]}" "${objs[@]}" -lm 2>"$OUT/unit.err"; then
    echo "LINK FAIL: $(basename "$t")"
    head -25 "$OUT/unit.err"
    fail=1
    continue
  fi
  echo "=== $(basename "$t") ==="
  "$bin" || fail=1
done
exit $fail
