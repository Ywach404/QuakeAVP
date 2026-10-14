#!/usr/bin/env bash
#
# check-core.sh -- host-compile QuakeCore outside Xcode.
#
# Why this exists: the visionOS toolchain only runs on a Mac with Xcode, which
# makes the edit/compile loop slow and makes CI on Linux impossible. But
# QuakeCore is plain C with no Apple frameworks in it -- so it compiles on any
# host. Building and *linking* it here proves two things that matter far more
# than codegen:
#
#   1. every translation unit parses and type-checks
#   2. the platform stub layer is complete -- no undefined symbols
#
# A clean run here does NOT prove it builds for arm64-visionOS (SDK headers,
# availability macros, and -fmodules can still bite). Run `make gen build` on
# the Mac for that.
#
# Usage:  tools/check-core.sh            # compile + link
#         CC=clang tools/check-core.sh   # match Xcode's compiler more closely
#         tools/check-core.sh --symbols  # on failure, list undefined symbols

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CC="${CC:-cc}"
# Objects go outside the repo on purpose: the tree may live on a mount where
# the build user can create files but not unlink them, which breaks rebuilds.
OUT="${OUT:-${TMPDIR:-/tmp}/quakecore-hostbuild}"
SYMBOLS=0
[[ "${1:-}" == "--symbols" ]] && SYMBOLS=1

CFLAGS=(
  -std=gnu99 -O0 -g0
  -DQAVP_PLATFORM
  -DQAVP_HOSTCHECK
  # Background music. snd_codec.c registers a codec only when its USE_CODEC_*
  # macro is defined: wave is the vendored snd_wave.c, vorbis is
  # platform/snd_vorbis_avp.c on stb_vorbis. Keep in sync with project.yml's
  # GCC_PREPROCESSOR_DEFINITIONS and tools/check-unit.sh.
  -DUSE_CODEC_WAVE=1
  -DUSE_CODEC_VORBIS=1
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

# lodepng.c is #included directly by image.c (upstream does the same -- it is
# not in QuakeSpasm's object list). Compiling it separately duplicates every
# lodepng symbol. Keep this in sync with the `excludes:` block in project.yml.
NOBUILD=(lodepng.c)

skip() {
  local base; base="$(basename "$1")"
  for n in "${NOBUILD[@]}"; do [[ "$base" == "$n" ]] && return 0; done
  return 1
}

# Per-file warning escapes. Scoped to one file on purpose: everything in
# platform/ is new code and is meant to compile clean at the default level.
# stb_vorbis.c is vendored verbatim (UPSTREAM.md), so its one tautological
# pointer-overflow guard cannot be fixed without diverging from upstream.
# Mirrored by the compilerFlags on the same file in project.yml.
extra_cflags() {
  case "$(basename "$1")" in
    stb_vorbis.c) echo "-Wno-tautological-compare" ;;
  esac
}

mkdir -p "$OUT"
rm -f "$OUT"/*.o

fail=0
for src in "$ROOT"/Sources/QuakeCore/engine/*.c "$ROOT"/Sources/QuakeCore/platform/*.c \
           "$ROOT"/Sources/QuakeRenderer/bridge/*.c; do
  skip "$src" && continue
  obj="$OUT/$(basename "$src" .c).o"
  # ${xtra[@]+...} so an empty array doesn't trip `set -u` on bash 3.2.
  read -r -a xtra <<< "$(extra_cflags "$src")"
  if ! "$CC" "${CFLAGS[@]}" ${xtra[@]+"${xtra[@]}"} -c -o "$obj" "$src" 2> "$OUT/last.err"; then
    echo "COMPILE FAIL: ${src#$ROOT/}"
    sed 's/^/    /' "$OUT/last.err" | head -25
    fail=1
  elif [[ -s "$OUT/last.err" ]]; then
    echo "warnings: ${src#$ROOT/}"
    sed 's/^/    /' "$OUT/last.err" | head -10
  fi
done

if [[ $fail -ne 0 ]]; then
  echo "=== compile stage failed ==="
  exit 1
fi

echo "compiled $(ls "$OUT"/*.o | wc -l) translation units"

# Link an executable, not a shared object. Shared objects tolerate undefined
# symbols; executables do not -- and "no undefined symbols" is the whole point
# of this check. Every .o is named explicitly so nothing gets dropped.
"$CC" "${CFLAGS[@]}" -c -o "$OUT/hostmain.o" "$ROOT/tools/hostmain.c" || exit 1

if ! "$CC" -o "$OUT/quakecore-check" "$OUT"/*.o -lm 2> "$OUT/link.err"; then
  echo "=== LINK FAILED -- platform stub layer is incomplete ==="
  if [[ $SYMBOLS -eq 1 ]]; then
    grep -oE "undefined reference to .[A-Za-z0-9_]+" "$OUT/link.err" \
      | sed "s/.*to .//" | sort -u
  else
    head -40 "$OUT/link.err"
    echo "(re-run with --symbols for a deduped list)"
  fi
  exit 1
fi

echo "linked $OUT/quakecore-check -- no undefined symbols"
"$OUT/quakecore-check" "${QUAKE_BASEDIR:-}"
