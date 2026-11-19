# CLAUDE.md

Guidance for Claude Code in this repo. Rules here are the ones whose violation fails silently; the README is the manual and says why.

## Never in the repo
- AMI's viewer jars or media libraries, or any secret. Each BMC serves its own files at run time (README, License).
- Personal details beyond the copyright line and the Tested hardware table: the repo is public.
- A file without licensing. Each file carries the two SPDX lines, or `REUSE.toml` covers it; `reuse lint` checks.

## Secrets at run time
The password, session cookie, CSRF token and console token never reach the log, `--diagnose`'s report, a process list or the viewer's command line. Fit reads the cookie and token on stdin. The tests grep every output for the fake values in `test/fake_bmc.py`, so add any new output to those checks.

## Tests
Run these before a push. CI runs them on Linux x64 and arm64, macOS arm64 and Intel, and Windows under both PowerShells.
- `test/test-media.sh "$JAVA_HOME"`: media.c against `test/expected.sha256`. Re-record those only with `--intel` (README, Development).
- `test/test-launcher.sh "$JAVA_HOME"`: install.sh into a temporary home, then the launcher against the fake BMC.
- `shellcheck -s sh install.sh && shellcheck test/test-launcher.sh test/test-media.sh`
- `test/test-windows.ps1` runs only on Windows.
- With `MEGARAC_PACKAGE=<package>`, the launcher tests install a release package and run on its Java 8. CI does both for every push; build a package with `.github/package.sh <JDK> <output>`.

## Releases
- `install.sh` and `install.ps1` build from source in a checkout and install the latest published release otherwise (`curl | sh`, `irm | iex`). The asset names in them, `test.yml`, `package.sh`, `megarac-console.iss` and the README's download table must match.
- `install.ps1`'s release branch must never `exit`: under `iex` it closes the user's window.

## Working from a Linux container
- macOS and Windows are tested only by CI, so push, then follow the run. A running job's steps show in `get_workflow_job`, but its log can't be fetched until the job finishes (404).
- A failure email can be for a superseded run. Match its run number to the latest before acting on it.
- The container's proxy settings reach Java through `JAVA_TOOL_OPTIONS` and `_JAVA_OPTIONS`, and curl through `HTTPS_PROXY`. The tests unset the first two and give curl `--noproxy '*'`. Java 8 may need `apt-get install openjdk-8-jdk-headless`; it lands in `/usr/lib/jvm/java-8-openjdk-amd64`. Ubuntu's JDK has dangling symlinks (`src.zip`), so `package.sh` can't copy it as is; CI's Zulu is self-contained.
- The auto-mode classifier blocks running a script that downloads and runs an unpinned tool (it blocked appimagetool's `continuous` build), and the GitHub REST API is unreachable from here (403).

## Platform traps
- **macOS `security`:**
  - It finds the keychain through `HOME`. Under a substitute `HOME`, `add-generic-password` waits out the launcher's 20-second limit and saves nothing, so the tests move only Java's home (`-Duser.home`).
  - `find-generic-password -w` prints a non-ASCII password as bare hex. The launcher reads `-g`'s stderr line instead (`keychainValue`).
  - `security -i` stalls; use the argv form.
- **Windows PowerShell 5.1:**
  - Under `$ErrorActionPreference = 'Stop'`, a native command's redirected stderr is a terminating error.
  - `Start-Process -PassThru` reports no exit code unless `$p.Handle` is read before `WaitForExit()`.
- **powershell.exe started from PowerShell 7:**
  - It inherits 7's `PSModulePath` and then can't load its own modules, so `run()` removes it.
  - Its console uses the OEM code page unless set to UTF-8 (`UTF8_CONSOLE`).
- **Shell:**
  - `install.sh` is POSIX sh, for FreeBSD's `/bin/sh`.
  - The test scripts are bash, and must also run on macOS's bash 3.2: an empty array under `set -u` is `${a[@]+"${a[@]}"}`.
  - BSD `wc` pads its numbers.
- **Python's `HTTPServer`** looks its own address up in DNS when it binds (`socket.getfqdn`), which takes about 30 seconds on GitHub's Intel Macs. `fake_bmc.py` overrides `server_bind` to skip it.
- **The login form** is encoded byte for byte like `curl --data-urlencode`, which sends a space as `+`. The launcher test compares the two.
- **A negative check needs a positive one before it.** "No token on the viewer's command line" once passed with no viewer running; "kill: viewer started" now guards it.
