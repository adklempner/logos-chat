#!/usr/bin/env bash
# Fix duplicate symbols between librln_mix and rust-bundle on macOS.
set -uo pipefail

LIB="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
RUST_BUNDLE="${2:-}"
[ -n "$RUST_BUNDLE" ] && RUST_BUNDLE="$(cd "$(dirname "$RUST_BUNDLE")" && pwd)/$(basename "$RUST_BUNDLE")"

case "$(uname -s)" in
  Darwin)
    [ -z "$RUST_BUNDLE" ] && echo "Usage: $0 <mix-lib> <rust-bundle-lib>" && exit 0

    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT

    # Match all global symbols (T=text, D=data, S=common, B=BSS, etc — uppercase = global)
    (nm "$RUST_BUNDLE" 2>/dev/null || true) | grep " [TDSBCR] " | awk '{print $3}' | sort -u > "$WORK/b.txt"
    (nm "$LIB" 2>/dev/null || true) | grep " [TDSBCR] " | awk '{print $3}' | sort -u > "$WORK/m.txt"
    comm -12 "$WORK/b.txt" "$WORK/m.txt" > "$WORK/d.txt"
    DCOUNT=$(wc -l < "$WORK/d.txt" | tr -d ' ')
    [ "$DCOUNT" -eq 0 ] && echo "No duplicates." && exit 0
    echo "Localizing $DCOUNT duplicate symbols in $(basename "$LIB")..."

    mkdir "$WORK/o" && cd "$WORK/o"
    ar x "$LIB"
    FIXED=0
    for f in *.o; do
      # Get this object's global text symbols, intersect with dupes
      (nm "$f" 2>/dev/null || true) | grep " [TDSBCR] " | awk '{print $3}' | sort -u > "$WORK/obj.txt"
      comm -12 "$WORK/d.txt" "$WORK/obj.txt" > "$WORK/obj_dupes.txt"
      if [ -s "$WORK/obj_dupes.txt" ]; then
        nmedit -R "$WORK/obj_dupes.txt" "$f"
        FIXED=$((FIXED + 1))
      fi
    done
    rm "$LIB"
    ar rcs "$LIB" *.o
    echo "Fixed $FIXED objects."

    # Localize the non-mangled cross-archive Rust runtime symbols that the
    # nm-based dedup above misses. The std-*.rcgu.o objects are LLVM-IR
    # bitcode emitted by a newer rustc than the system nm understands, so the
    # earlier `nm | grep [TDSBCR]` filter sees them as undefined. nmedit
    # operates on the symbol name directly and works even when nm can't fully
    # parse the section table. Localizing makes the duplicate copy private to
    # librln_mix while rust-bundle's copy is still globally visible.
    echo "_rust_eh_personality" > "$WORK/runtime_syms.txt"
    STD_OBJS=$(ls std-*.std.*.rcgu.o 2>/dev/null || true)
    if [ -n "$STD_OBJS" ]; then
      for so in $STD_OBJS; do
        nmedit -R "$WORK/runtime_syms.txt" "$so" 2>/dev/null || true
      done
      rm "$LIB"
      ar rcs "$LIB" *.o
      echo "Localized _rust_eh_personality in $(echo "$STD_OBJS" | wc -w | tr -d ' ') std rcgu objects."
    fi
    ;;
  *) echo "No fix needed on $(uname -s)" ;;
esac
