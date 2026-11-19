#!/bin/sh
# SPDX-FileCopyrightText: 2026 Jeff Morrison
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Installs MegaRAC Console for this user on macOS, Linux or FreeBSD.
#   curl -fsSL https://raw.githubusercontent.com/successful-accident/megarac-console/main/install.sh | sh
#                              the latest release, with Java 8 included
#   ./install.sh               in a git checkout: build from source with a Java 8 JDK
#                              and a C compiler found on this machine
#   ./install.sh --uninstall   remove what install.sh added
# FreeBSD has no release package: there, the piped form builds main from source.
# Source builds: JAVA_HOME picks the JDK; otherwise the usual places are searched.
# MEGARAC_PACKAGE=<file> installs that release package instead of downloading one.
# On macOS the app goes in /Applications, or wherever MEGARAC_APPS says.
set -eu

REPO=successful-accident/megarac-console
ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="MegaRAC Console"
ID=io.github.successful-accident.megarac-console
OS="$(uname -s)"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
BIN="$HOME/.local/bin/megarac-console"
if [ "$OS" = Darwin ]; then
  APPS="${MEGARAC_APPS:-/Applications}"
  BUNDLE="$APPS/$NAME.app"
else
  APP="$DATA/megarac-console"
  DESKTOP="$DATA/applications/megarac-console.desktop"
fi

die() {
  echo "install.sh: $1" >&2
  exit 1
}

# Ours: an app bundle with our identifier, or a command that runs our launcher.
ours() {
  if [ "$OS" = Darwin ] && [ -e "$BUNDLE" ] && ! grep -q "$ID" "$BUNDLE/Contents/Info.plist" 2>/dev/null; then
    return 1
  fi
  [ ! -e "$BIN" ] || grep -qE 'MegaracConsole|MegaRAC Console' "$BIN" 2>/dev/null
}

if [ "${1:-}" = --uninstall ]; then
  ours || die "the installed copy was not made by this installer; nothing removed."
  if [ "$OS" = Darwin ]; then rm -rf "$BUNDLE" "$BIN"; else rm -rf "$APP" "$BIN" "$DESKTOP"; fi
  echo "removed $NAME. The saved login, cache and log stay; the README's Uninstall section lists them."
  exit 0
fi
[ $# -eq 0 ] || die "usage: $0 [--uninstall]"
if [ "$OS" = Darwin ]; then where="$BUNDLE"; else where="$BIN"; fi
ours || die "$where exists and was not made by this installer. Move it away, then run this again."

get() { # <url> <file>
  echo "downloading $1"
  if command -v curl >/dev/null 2>&1; then curl -fL --progress-bar -o "$2" "$1"; else fetch -o "$2" "$1"; fi ||
    die "could not download $1"
}

# Everything is built or unpacked in a scratch directory first, so a failure
# leaves an earlier install as it was.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
A="$STAGE/app"

if [ -z "${MEGARAC_PACKAGE:-}" ] && [ -f "$ROOT/src/MegaracConsole.java" ]; then
  # ---- From source.
  # A Java 8 JDK: a compiler, and the rt.jar that Java 9 and later no longer have.
  jdk8() { [ -x "$1/bin/javac" ] && [ -f "$1/jre/lib/rt.jar" ]; }
  JH=
  if [ -n "${JAVA_HOME:-}" ]; then
    jdk8 "$JAVA_HOME" || die "JAVA_HOME ($JAVA_HOME) is not a Java 8 JDK."
    JH="$JAVA_HOME"
  elif [ "$OS" = Darwin ]; then
    # java_home -v 1.8 can answer with a newer Java, so check every installed one.
    for d in "$(/usr/libexec/java_home -v 1.8 2>/dev/null)" /Library/Java/JavaVirtualMachines/*/Contents/Home; do
      if jdk8 "$d"; then JH="$d" && break; fi
    done
  else
    for d in /usr/lib/jvm/* /usr/local/openjdk8 /usr/local/zulu8 /opt/*; do
      if jdk8 "$d"; then JH="$d" && break; fi
    done
  fi
  if [ -z "$JH" ] || ! jdk8 "$JH"; then
    die "no Java 8 JDK found. The README's Install section says where to get one, or set JAVA_HOME."
  fi
  command -v cc >/dev/null 2>&1 || die "no C compiler (cc). On macOS: xcode-select --install. On Linux: install gcc."

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
    C="$STAGE/bundle/Contents"
    mkdir -p "$C/MacOS"
    mv "$A" "$C/Resources"
    cp "$ROOT/assets/AppIcon.icns" "$C/Resources/"
    # Java 8 is found at every launch: MEGARAC_JAVA_HOME, then the one inside the
    # app (release packages have one), then the system's Java 8, then the one used
    # now, so updating Java never breaks it.
    sed "s|@JH@|$JH|" > "$C/MacOS/megarac-console" <<'EOF'
#!/bin/sh
R="$(cd "$(dirname "$0")/../Resources" && pwd)"
if [ -n "${MEGARAC_JAVA_HOME:-}" ]; then JH="$MEGARAC_JAVA_HOME"
elif [ -x "$R/jdk/bin/java" ]; then JH="$R/jdk"
else
  # java_home -v 1.8 can answer with a newer Java; only Java 8 has rt.jar.
  for JH in "$(/usr/libexec/java_home -v 1.8 -a "$(uname -m)" 2>/dev/null)" /Library/Java/JavaVirtualMachines/*/Contents/Home '@JH@'; do
    [ ! -f "$JH/jre/lib/rt.jar" ] || break
  done
fi
[ -x "$JH/bin/java" ] || {
  osascript -e 'display alert "MegaRAC Console" message "Java 8 is not installed. Install it with: brew install --cask zulu@8" as critical' >/dev/null 2>&1
  exit 1
}
exec "$JH/bin/java" -Dapple.awt.UIElement=true -cp "$R/classes" MegaracConsole "$@"
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
  else
    cp "$ROOT/assets/megarac-console.png" "$A/"
    # The command finds a Java 8 JDK at every launch: MEGARAC_JAVA_HOME, then the
    # one found now, then the usual places, so updating Java never breaks it.
    cat > "$STAGE/command" <<EOF
#!/bin/sh
for jh in "\${MEGARAC_JAVA_HOME:-}" "$JH" /usr/lib/jvm/* /usr/local/openjdk8 /usr/local/zulu8 /opt/*; do
  if [ -x "\$jh/bin/javac" ] && [ -f "\$jh/jre/lib/rt.jar" ]; then
    exec "\$jh/bin/java" -cp "$APP/classes" MegaracConsole "\$@"
  fi
done
echo "megarac-console: no Java 8 JDK found. The README's Install section says where to get one." >&2
exit 1
EOF
  fi
else
  # ---- A release package, which carries its own Java 8.
  pkg="${MEGARAC_PACKAGE:-}"
  case "$OS-$(uname -m)" in
    Darwin-arm64) asset=megarac-console-macos-arm64.dmg ;;
    Darwin-x86_64) asset=megarac-console-macos-x64.dmg ;;
    Linux-x86_64) asset=megarac-console-linux-x86_64.tar.gz ;;
    Linux-aarch64 | Linux-arm64) asset=megarac-console-linux-aarch64.tar.gz ;;
    FreeBSD-*)
      [ -z "$pkg" ] || die "there are no release packages for FreeBSD."
      get "https://github.com/$REPO/archive/refs/heads/main.tar.gz" "$STAGE/src.tar.gz"
      tar -xzf "$STAGE/src.tar.gz" -C "$STAGE"
      sh "$STAGE"/megarac-console-main/install.sh
      exit
      ;;
    *) die "there is no release package for $OS on $(uname -m). Build from source: the README's Development section says how." ;;
  esac
  if [ -z "$pkg" ]; then
    pkg="$STAGE/$asset"
    get "https://github.com/$REPO/releases/latest/download/$asset" "$pkg"
  fi
  if [ "$OS" = Darwin ]; then
    hdiutil attach -quiet -nobrowse -readonly -mountpoint "$STAGE/dmg" "$pkg"
    ditto "$STAGE/dmg/$NAME.app" "$STAGE/bundle" || { hdiutil detach -quiet "$STAGE/dmg"; die "the package holds no $NAME.app"; }
    hdiutil detach -quiet "$STAGE/dmg"
  else
    tar -xzf "$pkg" -C "$STAGE" || die "could not unpack $pkg"
    mv "$STAGE/megarac-console" "$A"
    printf '#!/bin/sh\n# MegaRAC Console\nexec "%s/megarac-console" "$@"\n' "$APP" > "$STAGE/command"
  fi
fi

mkdir -p "$(dirname "$BIN")"
if [ "$OS" = Darwin ]; then
  mkdir -p "$APPS"
  rm -rf "$BUNDLE"
  mv "$STAGE/bundle" "$BUNDLE"
  printf '#!/bin/sh\n# MegaRAC Console\nexec "%s/Contents/MacOS/megarac-console" "$@"\n' "$BUNDLE" > "$BIN"
  chmod 755 "$BIN"
  echo "installed $BUNDLE and $BIN"
  file "$BUNDLE/Contents/Resources/lib/libjavacdromwrapper.jnilib" 2>/dev/null || true
else
  mkdir -p "$(dirname "$APP")" "$(dirname "$DESKTOP")"
  rm -rf "$APP"
  mv "$A" "$APP"
  mv "$STAGE/command" "$BIN"
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
  file "$APP/lib/libjavacdromwrapper.so" 2>/dev/null || true
  command -v secret-tool >/dev/null 2>&1 ||
    echo "note: without secret-tool (Debian/Ubuntu: libsecret-tools), the login is asked for at every launch."
fi
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "note: add ~/.local/bin to PATH to run megarac-console from a terminal." ;;
esac
