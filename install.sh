#!/bin/sh
# SPDX-FileCopyrightText: 2026 Jeff Morrison
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Installs MegaRAC Console for this user on macOS, Linux or FreeBSD. It compiles
# the launcher with a Java 8 JDK, builds media.c for this machine, and adds an
# app entry. Run it again after a git pull to update.
#   ./install.sh               install, or update an earlier install
#   ./install.sh --uninstall   remove what install.sh added
# JAVA_HOME picks the JDK; otherwise the usual places are searched. On macOS the
# app goes in /Applications, or wherever MEGARAC_APPS says.
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="MegaRAC Console"
ID=io.github.successful-accident.megarac-console
OS="$(uname -s)"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
if [ "$OS" = Darwin ]; then
  APPS="${MEGARAC_APPS:-/Applications}"
  BUNDLE="$APPS/$NAME.app"
else
  APP="$DATA/megarac-console"
  BIN="$HOME/.local/bin/megarac-console"
  DESKTOP="$DATA/applications/megarac-console.desktop"
fi

die() {
  echo "install.sh: $1" >&2
  exit 1
}

if [ "${1:-}" = --uninstall ]; then
  if [ "$OS" = Darwin ]; then rm -rf "$BUNDLE"; else rm -rf "$APP" "$BIN" "$DESKTOP"; fi
  echo "removed $NAME. The saved login, cache and log stay; the README's Uninstall section lists them."
  exit 0
fi
[ $# -eq 0 ] || die "usage: $0 [--uninstall]"

# A Java 8 JDK: a compiler, and the rt.jar that Java 9 and later no longer have.
jdk8() { [ -x "$1/bin/javac" ] && [ -f "$1/jre/lib/rt.jar" ]; }
JH=
if [ -n "${JAVA_HOME:-}" ]; then
  jdk8 "$JAVA_HOME" || die "JAVA_HOME ($JAVA_HOME) is not a Java 8 JDK."
  JH="$JAVA_HOME"
elif [ "$OS" = Darwin ]; then
  JH="$(/usr/libexec/java_home -v 1.8 2>/dev/null)" || JH=
else
  for d in /usr/lib/jvm/* /usr/local/openjdk8 /usr/local/zulu8 /opt/*; do
    if jdk8 "$d"; then JH="$d" && break; fi
  done
fi
if [ -z "$JH" ] || ! jdk8 "$JH"; then
  die "no Java 8 JDK found. The README's Install section says where to get one, or set JAVA_HOME."
fi
command -v cc >/dev/null 2>&1 || die "no C compiler (cc). On macOS: xcode-select --install. On Linux: install gcc."

# Build everything in a scratch directory first, so a failure leaves an earlier
# install as it was.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
A="$STAGE/app"
mkdir -p "$A/classes" "$A/lib"
"$JH/bin/javac" -nowarn -encoding UTF-8 -d "$A/classes" "$ROOT/src/MegaracConsole.java"
cp "$ROOT/src/Fit.java" "$ROOT/src/legacy-tls.security" "$A/"
md="$(dirname "$(find "$JH/include" -name jni_md.h | head -1)")"
src="$ROOT/src/media.c"
if [ "$OS" = Darwin ]; then
  ext=jnilib
  # Both architectures when the SDK allows, so an Intel Java 8 loads it too.
  cc -O2 -Wall -dynamiclib -arch arm64 -arch x86_64 -I"$JH/include" -I"$md" -o "$A/lib/libjavacdromwrapper.$ext" "$src" ||
    cc -O2 -Wall -dynamiclib -I"$JH/include" -I"$md" -o "$A/lib/libjavacdromwrapper.$ext" "$src"
else
  ext=so
  cc -O2 -Wall -shared -fPIC -I"$JH/include" -I"$md" -o "$A/lib/libjavacdromwrapper.$ext" "$src"
fi
# The viewer loads three libraries by name; media.c is all three.
cp "$A/lib/libjavacdromwrapper.$ext" "$A/lib/libjavafloppywrapper.$ext"
cp "$A/lib/libjavacdromwrapper.$ext" "$A/lib/libjavaharddiskwrapper.$ext"

if [ "$OS" = Darwin ]; then
  if [ -d "$BUNDLE" ] && ! grep -q "$ID" "$BUNDLE/Contents/Info.plist" 2>/dev/null; then
    die "$BUNDLE exists and was not made by this installer. Move it away, then run this again."
  fi
  C="$STAGE/bundle/Contents"
  mkdir -p "$C/MacOS"
  mv "$A" "$C/Resources"
  cp "$ROOT/assets/AppIcon.icns" "$C/Resources/"
  # The app finds Java 8 at every launch, so updating Java never breaks it.
  cat > "$C/MacOS/megarac-console" <<'EOF'
#!/bin/sh
JH="$(/usr/libexec/java_home -v 1.8 -a "$(uname -m)" 2>/dev/null || /usr/libexec/java_home -v 1.8 2>/dev/null)" || {
  osascript -e 'display alert "MegaRAC Console" message "Java 8 is not installed. Install it with: brew install --cask zulu@8" as critical' >/dev/null 2>&1
  exit 1
}
exec "$JH/bin/java" -Dapple.awt.UIElement=true -cp "$(dirname "$0")/../Resources/classes" MegaracConsole "$@"
EOF
  chmod 755 "$C/MacOS/megarac-console"
  # LSUIElement: the launcher gets no Dock icon; the viewer does.
  cat > "$C/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>megarac-console</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
  mkdir -p "$APPS"
  rm -rf "$BUNDLE"
  mv "$STAGE/bundle" "$BUNDLE"
  echo "installed $BUNDLE"
  file "$BUNDLE/Contents/Resources/lib/libjavacdromwrapper.$ext"
  exit 0
fi

cp "$ROOT/assets/megarac-console.png" "$A/"
mkdir -p "$(dirname "$APP")" "$(dirname "$BIN")" "$(dirname "$DESKTOP")"
rm -rf "$APP"
mv "$A" "$APP"
# The command finds a Java 8 JDK at every launch: MEGARAC_JAVA_HOME, then the one
# found now, then the usual places, so updating Java never breaks it.
cat > "$BIN" <<EOF
#!/bin/sh
for jh in "\${MEGARAC_JAVA_HOME:-}" "$JH" /usr/lib/jvm/* /usr/local/openjdk8 /usr/local/zulu8 /opt/*; do
  if [ -x "\$jh/bin/javac" ] && [ -f "\$jh/jre/lib/rt.jar" ]; then
    exec "\$jh/bin/java" -cp "$APP/classes" MegaracConsole "\$@"
  fi
done
echo "megarac-console: no Java 8 JDK found. The README's Install section says where to get one." >&2
exit 1
EOF
chmod 755 "$BIN"
cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=$NAME
Comment=Remote console of an AMI MegaRAC BMC
Exec="$BIN"
Icon=$APP/megarac-console.png
Terminal=false
Categories=Network;RemoteAccess;
EOF
echo "installed $APP, $BIN and $DESKTOP"
file "$APP/lib/libjavacdromwrapper.$ext"
command -v secret-tool >/dev/null 2>&1 ||
  echo "note: without secret-tool (Debian/Ubuntu: libsecret-tools), the login is asked for at every launch."
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "note: add ~/.local/bin to PATH to run megarac-console from a terminal." ;;
esac
