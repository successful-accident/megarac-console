#!/bin/sh
# SPDX-FileCopyrightText: 2026 Jeff Morrison
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds a release package for this machine, with that Java 8 JDK inside: a .dmg
# on macOS, a .tar.gz on Linux. It installs from source into a scratch directory
# with install.sh, then adds the JDK, so the package holds what install.sh builds.
# Windows is packaged by megarac-console.iss.
#   .github/package.sh <JDK> <output file>
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JH="$1"
OUT="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# The JDK, less what nothing here uses; its legal notices stay.
add_jdk() {
  if [ "$(uname -s)" = Darwin ]; then ditto "$JH" "$1/jdk"; else cp -RL "$JH" "$1/jdk"; fi
  rm -rf "$1/jdk/src.zip" "$1/jdk/javafx-src.zip" "$1/jdk/man" "$1/jdk/sample" "$1/jdk/demo"
  cp "$ROOT/LICENSE" "$1/"
}

if [ "$(uname -s)" = Darwin ]; then
  HOME="$T/home" JAVA_HOME="$JH" MEGARAC_APPS="$T/dmg" sh "$ROOT/install.sh" >/dev/null
  add_jdk "$T/dmg/MegaRAC Console.app/Contents/Resources"
  ln -s /Applications "$T/dmg/Applications"
  hdiutil create -quiet -volname "MegaRAC Console" -srcfolder "$T/dmg" -format UDZO -ov "$OUT"
else
  HOME="$T/home" XDG_DATA_HOME='' JAVA_HOME="$JH" sh "$ROOT/install.sh" >/dev/null
  D="$T/home/.local/share/megarac-console"
  add_jdk "$D"
  cat > "$D/megarac-console" <<'EOF'
#!/bin/sh
# MegaRAC Console's entry point: the launcher on the Java 8 inside, or MEGARAC_JAVA_HOME.
here="$(dirname "$(readlink -f "$0")")"
exec "${MEGARAC_JAVA_HOME:-$here/jdk}/bin/java" -cp "$here/classes" MegaracConsole "$@"
EOF
  chmod 755 "$D/megarac-console"
  tar -czf "$OUT" -C "$(dirname "$D")" megarac-console
fi
echo "built $OUT ($(du -h "$OUT" | cut -f1))"
