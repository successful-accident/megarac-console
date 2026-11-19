#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Jeff Morrison
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Checks media.c, the stand-in for the viewer's CD library: the scripted
# sessions from corpus.py go through this machine's build, and every reply must
# match the recorded ones in expected.sha256.
#   test/test-media.sh [JAVA_HOME]            check this machine's build
#   test/test-media.sh --update [JAVA_HOME]   record this build's replies
#   test/test-media.sh --intel <Mac64.jar> <dir with JViewer.jar and JViewer-SOC.jar>
#       macOS with Rosetta and an Intel Java 8 (brew install --cask temurin@8):
#       run the Intel library media.c replaces, check that media.c built for
#       x86_64 and arm64 gives the same replies, and record those. Mac64.jar is
#       served by the BMC at /Java/release/Mac64.jar; --diagnose downloads it.
# Needs a Java 8 JDK, a C compiler and python3.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
EXPECTED="$HERE/expected.sha256"
mode=check
case "${1:-}" in
  --update) mode=update; shift ;;
  --intel) mode=intel; MAC64="${2:?usage: $0 --intel <Mac64.jar> <jar dir>}" JARS="${3:?usage: $0 --intel <Mac64.jar> <jar dir>}" ;;
esac
unset JAVA_TOOL_OPTIONS _JAVA_OPTIONS
if [ "$mode" != intel ]; then
  JH="${1:-${JAVA_HOME:-}}"
  [ -n "$JH" ] || [ "$(uname)" != Darwin ] || JH="$(/usr/libexec/java_home -v 1.8)"
  [ -n "$JH" ] || { echo "usage: $0 [--update] [JAVA_HOME of a Java 8 JDK]" >&2; exit 1; }
fi
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/classes"
python3 "$HERE/corpus.py" "$W"

build() { # <java home> <architecture or ""> <output library>
  local md
  md="$(dirname "$(find "$1/include" -name jni_md.h | head -1)")"
  mkdir -p "$(dirname "$3")"
  if [ "$(uname)" = Darwin ]; then
    cc ${2:+-arch "$2"} -O2 -Wall -dynamiclib -I"$1/include" -I"$md" -o "$3" "$ROOT/src/media.c"
  else
    cc -O2 -Wall -shared -fPIC -I"$1/include" -I"$md" -o "$3" "$ROOT/src/media.c"
  fi
}

run() { # <java home> <library> <tag> <classpath>: every script's replies into replies-<tag>
  local s
  mkdir -p "$W/replies-$3"
  for s in "$W"/scripts/*.script; do
    # The Intel library logs every refusal on stdout; only the reply files count.
    (cd "$W/images" && "$1/bin/java" -Djava.awt.headless=true -cp "$4" Harness "$2" "$s" \
      "$W/replies-$3/$(basename "${s%.script}")" >/dev/null 2>&1)
  done
}

listing() { # <tag>: a SHA-256 line for each image, script and reply
  python3 - "$W" "$1" <<'EOF'
import hashlib, os, sys
w, tag = sys.argv[1], sys.argv[2]
for kind, d in (("image", "images"), ("script", "scripts"), ("reply", "replies-" + tag)):
    for name in sorted(os.listdir(os.path.join(w, d))):
        with open(os.path.join(w, d, name), "rb") as f:
            print(hashlib.sha256(f.read()).hexdigest(), kind + "/" + name)
EOF
}

record() { # <tag> <source description>
  { # REUSE-IgnoreStart: the header written below is not this file's own
    echo "# SPDX-FileCopyrightText: 2026 Jeff Morrison"
    echo "# SPDX-License-Identifier: GPL-3.0-or-later"
    # REUSE-IgnoreEnd
    echo "#"
    echo "# What test-media.sh checks against: SHA-256 of each corpus image and script,"
    echo "# and of the CD library's replies to each script."
    echo "# Recorded from $2 on $(date -u +%Y-%m-%d)."
    listing "$1"
  } > "$EXPECTED"
  echo "recorded $(grep -c ' reply/' "$EXPECTED") reply logs in $EXPECTED"
}

if [ "$mode" = intel ]; then
  INTEL="$(/usr/libexec/java_home -v 1.8 -a x86_64)"
  ARM="$(/usr/libexec/java_home -v 1.8 -a arm64)"
  CP="$JARS/JViewer.jar:$JARS/JViewer-SOC.jar:$W/classes"
  unzip -oq "$MAC64" libjavacdromwrapper.jnilib -d "$W/intel"
  build "$ARM" x86_64 "$W/x86_64/libjavacdromwrapper.jnilib"
  build "$ARM" arm64 "$W/arm64/libjavacdromwrapper.jnilib"
  "$ARM/bin/javac" -nowarn -cp "$CP" -d "$W/classes" "$HERE/Harness.java"
  run "$INTEL" "$W/intel/libjavacdromwrapper.jnilib" intel "$CP"
  run "$INTEL" "$W/x86_64/libjavacdromwrapper.jnilib" x86_64 "$CP"
  run "$ARM" "$W/arm64/libjavacdromwrapper.jnilib" arm64 "$CP"
  fail=0
  for tag in x86_64 arm64; do
    if diff <(listing intel) <(listing "$tag") >/dev/null; then
      echo "same   media.c $tag and the Intel library"
    else
      echo "DIFFER media.c $tag and the Intel library:"
      diff <(listing intel) <(listing "$tag") | grep '^[<>]' | head -10 || true
      fail=1
    fi
  done
  [ "$fail" = 0 ] && record intel "the Intel library (Mac64.jar), matched by media.c on x86_64 and arm64"
  exit "$fail"
fi

lib="$W/lib/libjavacdromwrapper.$([ "$(uname)" = Darwin ] && echo jnilib || echo so)"
build "$JH" "" "$lib"
"$JH/bin/javac" -nowarn -d "$W/classes" "$HERE/stubs/com/ami/iusb/CDROMRedir.java" "$HERE/Harness.java"
run "$JH" "$lib" here "$W/classes"
if [ "$mode" = update ]; then
  record here "media.c, $(uname -s) $(uname -m)"
  exit 0
fi
if diff <(grep -v '^#' "$EXPECTED") <(listing here) > "$W/diff"; then
  echo "media.c on $(uname -s) $(uname -m): all $(grep -c ' reply/' "$EXPECTED") reply logs match"
else
  echo "media.c on $(uname -s) $(uname -m) DIFFERS from expected.sha256 (< expected, > this build):"
  grep '^[<>]' "$W/diff" | head -20
  exit 1
fi
