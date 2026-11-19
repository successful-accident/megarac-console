#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Jeff Morrison
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Installs MegaRAC Console with install.sh into a throwaway home, runs it against
# fake_bmc.py, and checks what it sends, keeps and prints: the login body, the
# session headers, the jars, the viewer's command line, logout exactly once, the
# error paths, legacy TLS and --diagnose. On macOS this uses the real Keychain;
# the entries it makes are deleted at the end.
#   test/test-launcher.sh [JAVA_HOME]     a Java 8 JDK; default $JAVA_HOME
# Needs python3, openssl, curl and a C compiler.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
JH="${1:-${JAVA_HOME:?usage: $0 [JAVA_HOME of a Java 8 JDK]}}"
T="$(mktemp -d)"
BMC_PID=
HOSTS=()
# shellcheck disable=SC2317 # called by the EXIT trap
cleanup() {
  [ -z "$BMC_PID" ] || kill "$BMC_PID" 2>/dev/null
  if [ "$(uname)" = Darwin ]; then
    for h in ${HOSTS[@]+"${HOSTS[@]}"}; do
      security delete-generic-password -s "megarac-console:$h" >/dev/null 2>&1 || true
    done
    defaults delete com.apple.java.util.prefs /megarac-console-test/ >/dev/null 2>&1 || true
  fi
  rm -rf "$T"
}
trap cleanup EXIT

# Both JVMs, the launcher and the viewer, get these: no display, and a home and
# preferences that are thrown away. Nothing the host machine has set leaks in.
unset JAVA_TOOL_OPTIONS _JAVA_OPTIONS XDG_CACHE_HOME XDG_STATE_HOME
mkdir -p "$T/home" "$T/stubs" "$T/served"

# Installed the way a person would, into the throwaway home.
if [ "$(uname)" = Darwin ]; then
  HOME="$T/home" JAVA_HOME="$JH" MEGARAC_APPS="$T/Applications" sh "$ROOT/install.sh" > "$T/install.out"
  APP="$T/Applications/MegaRAC Console.app/Contents/Resources"
  CACHE="$T/home/Library/Caches/megarac-console" LOG="$T/home/Library/Logs/megarac-console.log"
else
  HOME="$T/home" JAVA_HOME="$JH" sh "$ROOT/install.sh" > "$T/install.out"
  APP="$T/home/.local/share/megarac-console"
  CACHE="$T/home/.cache/megarac-console" LOG="$T/home/.local/state/megarac-console/megarac-console.log"
fi

# What the fake BMC serves: the stub viewer, a second jar, and native jars to list.
mkdir -p "$T/served/full" "$T/served/nofit"
find "$HERE/stubs" -name '*.java' -exec "$JH/bin/javac" -nowarn -d "$T/stubs" {} +
(cd "$T/stubs" && "$JH/bin/jar" cf "$T/served/full/JViewer.jar" com)
(cd "$T/stubs" && "$JH/bin/jar" cf "$T/served/nofit/JViewer.jar" com/ami/kvm/jviewer/JViewer.class)
echo soc > "$T/soc.txt" && "$JH/bin/jar" cf "$T/served/full/JViewer-SOC.jar" -C "$T" soc.txt
cp "$T/served/full/JViewer-SOC.jar" "$T/served/nofit/"
echo dll > "$T/javacdromwrapper.dll" && "$JH/bin/jar" cf "$T/served/full/Win64.jar" -C "$T" javacdromwrapper.dll
cp "$T/served/full/Win64.jar" "$T/served/full/Mac64.jar"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=fake-bmc \
  -keyout "$T/key.pem" -out "$T/cert.pem" 2>/dev/null

export HOME="$T/home" STUB_ARGS_FILE="$T/viewer-args"
# Its own preferences node too: on macOS and Windows, prefs ignore user.home.
export JAVA_TOOL_OPTIONS="-Djava.awt.headless=true -Duser.home=$T/home -Djava.util.prefs.userRoot=$T/prefs -Dmegarac.prefs=megarac-console-test"

PASSWORD="$(python3 -c 'print("pa ss&=+%'"'"'*~é")')"
SECRETS=(CookieA1b2C3d4E5f6G7h8 CsrfZ9y8X7w6V5 TokenQ1w2E3r4T5y6U7i8 "$PASSWORD")
FAILED=0

start_bmc() { # <served set> [fake_bmc options...]
  stop_bmc
  rm -f "$T/port" "$T/requests"
  python3 "$HERE/fake_bmc.py" "$T/port" "$T/cert.pem" "$T/key.pem" "$T/served/$1" "$T/requests" "${@:2}" &
  BMC_PID=$!
  for _ in $(seq 600); do [ -s "$T/port" ] && break; sleep 0.05; done
  [ -s "$T/port" ] || { echo "fake_bmc.py did not start" >&2; exit 1; }
  HOST="127.0.0.1:$(cat "$T/port")"
  HOSTS+=("$HOST")
}
stop_bmc() { [ -z "$BMC_PID" ] || { kill "$BMC_PID" 2>/dev/null; wait "$BMC_PID" 2>/dev/null || true; BMC_PID=; }; }

launch() { # <stdin> [launcher arguments...]: sets RC; output in $T/out and $T/err
  rm -f "$STUB_ARGS_FILE"
  set +e
  printf '%s' "$1" | BMC_HOST="${BMC_HOST-$HOST}" "$JH/bin/java" -cp "$APP/classes" MegaracConsole "${@:2}" \
    >"$T/out" 2>"$T/err"
  RC=$?
  set -e
}

requests() { # <path prefix>: how many requests went to it
  python3 -c 'import json, sys
print(sum(1 for l in open(sys.argv[1]) if json.loads(l)["path"].startswith(sys.argv[2])))' "$T/requests" "$1"
}
request() { # <path prefix> <field>: that field of the first such request
  python3 -c 'import json, sys
print(next(json.loads(l)[sys.argv[3]] for l in open(sys.argv[1]) if json.loads(l)["path"].startswith(sys.argv[2])))' \
    "$T/requests" "$1" "$2"
}
# shellcheck disable=SC2317 # called through check
no_secrets() { # files...: none of them holds a password, cookie, CSRF token or console token
  local s
  for s in "${SECRETS[@]}"; do ! grep -qF -- "$s" "$@" || return 1; done
}
check() { # <name> <command...>
  if "${@:2}"; then echo "ok   $1"; else echo "FAIL $1"; FAILED=1; fi
}
expected_args() {
  printf '%s\n' -apptype JViewer -hostname 127.0.0.1 -title "Server & Console - fake" \
    -kvmtoken TokenQ1w2E3r4T5y6U7i8 -kvmport 7578 -webcookie CookieA1b2C3d4E5f6G7h8
}
login="admin
$PASSWORD
"

# ---- The install.
check "install: says so" grep -q '^installed ' "$T/install.out"
check "install: media library under all three names" \
  bash -c "ls '$APP'/lib/libjava{cdrom,floppy,harddisk}wrapper.* >/dev/null"

# ---- A normal launch.
start_bmc full
launch "$login"
check "normal: exit 0" [ "$RC" = 0 ]
curl_body="$(printf %s "$PASSWORD" | curl -sk --noproxy '*' --max-time 20 --data-urlencode "WEBVAR_USERNAME=admin" \
  --data-urlencode "WEBVAR_PASSWORD@-" "https://$HOST/rpc/WEBSES/create.asp" >/dev/null &&
  python3 -c 'import json, sys
print([json.loads(l)["body"] for l in open(sys.argv[1]) if json.loads(l)["method"] == "POST"][-1])' "$T/requests")"
check "normal: login body byte-identical to curl's" [ "$(request /rpc/WEBSES/create.asp body)" = "$curl_body" ]
check "normal: launch file request carries the session cookie" \
  [ "$(request /Java/jviewer.jnlp cookie)" = "SessionCookie=CookieA1b2C3d4E5f6G7h8" ]
check "normal: launch file request carries the CSRF token" [ "$(request /Java/jviewer.jnlp csrf)" = CsrfZ9y8X7w6V5 ]
check "normal: both jars cached" test -f "$CACHE/127.0.0.1_$(cat "$T/port")/JViewer-SOC.jar"
check "normal: Fit compiled" test -f "$CACHE/127.0.0.1_$(cat "$T/port")/classes/Fit.class"
check "normal: viewer got exactly the launch file's arguments" diff <(expected_args) "$STUB_ARGS_FILE"
check "normal: viewer loaded all three media libraries" [ "$(grep -c '^LOADED:' "$T/out")" = 3 ]
check "normal: logged out once" [ "$(requests /rpc/WEBSES/logout.asp)" = 1 ]
check "normal: no secret in output or log" no_secrets "$T/out" "$T/err" "$LOG"

# ---- The viewer's exit code comes back, and the session is still given back.
start_bmc full
STUB_EXIT=3 launch "$login"
check "exit code: viewer's 3 returned" [ "$RC" = 3 ]
check "exit code: logged out once" [ "$(requests /rpc/WEBSES/logout.asp)" = 1 ]

# ---- Killing the launcher stops the viewer and logs out.
start_bmc full
rm -f "$STUB_ARGS_FILE"
printf '%s' "$login" | BMC_HOST="$HOST" STUB_SLEEP=60 "$JH/bin/java" -cp "$APP/classes" MegaracConsole \
  >"$T/out" 2>"$T/err" &
pid=$!
for _ in $(seq 200); do grep -q '^PID:' "$T/out" 2>/dev/null && break; sleep 0.05; done
viewer="$(sed -n 's/^PID://p' "$T/out")"
viewer_args="$(ps -o args= -p "$viewer" || true)"
check "argv: the viewer runs Fit" grep -q ' Fit$' <<<"$viewer_args"
check "argv: the console token is not on the viewer's command line" bash -c "! grep -q TokenQ1w2 <<<'$viewer_args'"
kill -TERM "$pid"
wait "$pid" 2>/dev/null || true
for _ in $(seq 100); do kill -0 "$viewer" 2>/dev/null || break; sleep 0.05; done
check "kill: logged out once" [ "$(requests /rpc/WEBSES/logout.asp)" = 1 ]
check "kill: viewer stopped" bash -c "! kill -0 '$viewer' 2>/dev/null"

# ---- Older firmware: no CSRF token.
start_bmc full --no-csrf
launch "$login"
check "no CSRF token: exit 0" [ "$RC" = 0 ]
check "no CSRF token: none sent" [ "$(request /Java/jviewer.jnlp csrf)" = None ]

# ---- A refused login stops before anything else is asked of the BMC.
start_bmc full --refuse
launch "$login"
check "refused login: exit 1" [ "$RC" = 1 ]
check "refused login: no further requests" [ "$(wc -l < "$T/requests")" -eq 1 ]
check "refused login: says so" grep -q "refused the login" "$T/err"

# ---- A launch file without arguments, as for a user without administrator rights.
start_bmc full --empty-jnlp
launch "$login"
check "empty launch file: exit 1" [ "$RC" = 1 ]
check "empty launch file: says so" grep -q "did not return a console launch file" "$T/err"
check "empty launch file: logged out once" [ "$(requests /rpc/WEBSES/logout.asp)" = 1 ]

# ---- A viewer whose API Fit was not written for runs without Fit.
start_bmc nofit
launch "$login"
check "no Fit: exit 0" [ "$RC" = 0 ]
check "no Fit: says why" grep -q "does not compile against this viewer" "$T/err"
check "no Fit: viewer still got its arguments" diff <(expected_args) "$STUB_ARGS_FILE"

# ---- A BMC that only speaks TLS 1.1: one retry with the legacy settings, remembered.
start_bmc full --tls-max 1.1
launch "$login"
check "legacy TLS: exit 0" [ "$RC" = 0 ]
check "legacy TLS: retried with the legacy settings" grep -q "trying again with the legacy TLS settings" "$T/err"
check "legacy TLS: viewer started with them" grep -q "legacy TLS" "$LOG"
launch "$login"
check "legacy TLS: next launch starts with them" bash -c "[ $RC = 0 ] && ! grep -q 'trying again' '$T/err'"

# ---- --diagnose reports and logs out, and prints no secret.
start_bmc full
launch "$login" --diagnose
check "diagnose: exit 0" [ "$RC" = 0 ]
check "diagnose: reports TLS" grep -q '^tls: TLSv1' "$T/out"
check "diagnose: lists the native jars" grep -q 'Win64.jar, HTTP 200' "$T/out"
check "diagnose: redacts the console token" grep -q '(redacted, 21 characters)' "$T/out"
check "diagnose: logged out once" [ "$(requests /rpc/WEBSES/logout.asp)" = 1 ]
check "diagnose: no secret printed" no_secrets "$T/out" "$T/err"

# ---- BMC_HOST never replaces the remembered address; every launch above used it.
BMC_HOST='' launch "" forget
check "BMC_HOST: nothing remembered from it" grep -q "^nothing saved" "$T/out"

# ---- The first run asks for the BMC's address too, and remembers it.
start_bmc full
BMC_HOST='' launch "https://$HOST/
$login"
check "first run: a pasted web address works, exit 0" [ "$RC" = 0 ]
BMC_HOST='' launch "$login"
check "first run: the address is remembered" [ "$RC" = 0 ]
BMC_HOST='' launch "" forget
check "forget: forgets the address" grep -q "^forgot megarac-console:$HOST" "$T/out"

# ---- Installing again updates in place; --uninstall removes it.
if [ "$(uname)" = Darwin ]; then
  again() { HOME="$T/home" JAVA_HOME="$JH" MEGARAC_APPS="$T/Applications" sh "$ROOT/install.sh" "$@" >/dev/null; }
else
  again() { HOME="$T/home" JAVA_HOME="$JH" sh "$ROOT/install.sh" "$@" >/dev/null; }
fi
check "install: again updates in place" again
again --uninstall
check "install: --uninstall removes it" test ! -e "$APP"

stop_bmc
[ "$FAILED" = 0 ] && echo "all launcher tests passed"
exit "$FAILED"
