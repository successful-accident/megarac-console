<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/readme/banner-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="assets/readme/banner-light.svg">
  <img alt="MegaRAC Console: opens the Java remote console of older AMI MegaRAC SP BMCs, with no browser and no Java Web Start" src="assets/readme/banner-light.svg" width="100%">
</picture>

<br>

<a href="https://github.com/successful-accident/megarac-console/actions/workflows/test.yml"><img alt="Tests" src="https://img.shields.io/github/actions/workflow/status/successful-accident/megarac-console/test.yml?branch=main&style=flat-square&label=tests&labelColor=162033"></a>
<a href="LICENSE"><img alt="License: GPL-3.0-or-later" src="https://img.shields.io/badge/license-GPL--3.0--or--later-5aa7f0?style=flat-square&labelColor=162033"></a>
<a href="#install"><img alt="Needs a Java 8 JDK" src="https://img.shields.io/badge/needs-Java%208%20JDK-ffb547?style=flat-square&labelColor=162033"></a>

<a href="#install">Install</a> &nbsp;·&nbsp;
<a href="#use">Use</a> &nbsp;·&nbsp;
<a href="#troubleshooting">Troubleshooting</a> &nbsp;·&nbsp;
<a href="#platform-status">Platforms</a> &nbsp;·&nbsp;
<a href="#how-it-works">How it works</a> &nbsp;·&nbsp;
<a href="#development">Development</a>

</div>

<br>

Opens the Java remote console (KVM) of older AMI MegaRAC SP BMCs on today's
macOS, Linux, FreeBSD and Windows, with no browser and no Java Web Start.

These BMCs offer their console only as a Java Web Start launch file, which no
current browser or Java will run. MegaRAC Console does the launch itself:

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/readme/flow-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="assets/readme/flow-light.svg">
  <img alt="1. Log in to the BMC's web API. 2. Fetch the launch file and the viewer jars the BMC serves. 3. Launch the viewer on Java 8, wrapped by Fit, with media.c. 4. Log out, always, even after a crash or a stop." src="assets/readme/flow-light.svg" width="100%">
</picture>

The viewer runs with fixes:

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/readme/features-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="assets/readme/features-light.svg">
  <img alt="The picture scales to the window, and the window reopens at its last size. Pause then Resume redraws the whole screen. An ISO image can be mounted as the server's virtual CD at launch. Caps Lock takes one press on macOS. media.c, built at install, runs on Apple silicon, Linux on ARM and FreeBSD. The log never holds the password, the session cookie or the tokens." src="assets/readme/features-light.svg" width="100%">
</picture>

Except on Windows, which uses the BMC's own media libraries, the viewer's media
libraries are replaced by `src/media.c`, built for your machine at install. The
BMC's own libraries don't load on Apple silicon, Linux on ARM or FreeBSD.
`media.c` mounts ISO images.

> [!NOTE]
> It suits BMCs whose web interface has a "Launch KVM" or "Java console" button
> that downloads a `jviewer.jnlp` file. Newer MegaRAC SP-X firmware has an HTML5
> console in the browser and doesn't need this.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/readme/divider-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="assets/readme/divider-light.svg">
  <img alt="" src="assets/readme/divider-light.svg" width="100%">
</picture>

## Install

> [!IMPORTANT]
> Every platform needs a **Java 8 JDK**: not a newer Java, which the viewer
> predates, and not a JRE, since the launcher compiles a small wrapper against
> your BMC's viewer.

<details open>
<summary><b>macOS</b> &nbsp;·&nbsp; Apple silicon or Intel</summary>

```sh
brew install --cask zulu@8
xcode-select --install          # only if there is no C compiler yet
git clone https://github.com/successful-accident/megarac-console
cd megarac-console && ./install.sh
```
This installs `/Applications/MegaRAC Console.app`.

</details>

<details>
<summary><b>Linux</b> &nbsp;·&nbsp; x86_64 or aarch64</summary>

Install a Java 8 JDK with its desktop libraries (not the "headless" package), a C
compiler, and optionally `secret-tool` to keep the login:

| Distribution | Packages |
|---|---|
| Ubuntu | `openjdk-8-jdk gcc libsecret-tools` |
| Debian 12 and later | Temurin 8 from [Adoptium's apt repository](https://adoptium.net/installation/linux/) (`temurin-8-jdk`), plus `gcc libsecret-tools` |
| Fedora | Temurin 8 from Adoptium's rpm repository, plus `gcc libsecret` |
| Arch | `jdk8-openjdk gcc libsecret` |

Then:
```sh
git clone https://github.com/successful-accident/megarac-console
cd megarac-console && ./install.sh
```
This installs `~/.local/bin/megarac-console` and an application-menu entry.

</details>

<details>
<summary><b>FreeBSD</b> &nbsp;·&nbsp; amd64</summary>

```sh
pkg install openjdk8 git libsecret
git clone https://github.com/successful-accident/megarac-console
cd megarac-console && ./install.sh
```
The C compiler is in the base system. As the openjdk8 package says, Java needs
`fdesc /dev/fd fdescfs rw 0 0` and `proc /proc procfs rw 0 0` in `/etc/fstab`,
then `mount -a`.

</details>

<details>
<summary><b>Windows</b> &nbsp;·&nbsp; x64, or ARM64 under emulation</summary>

```powershell
winget install --id EclipseAdoptium.Temurin.8.JDK -e
git clone https://github.com/successful-accident/megarac-console
cd megarac-console
powershell -ExecutionPolicy Bypass -File .\install.ps1
```
This adds **MegaRAC Console** to the Start menu. On ARM64 Windows the same x64
JDK runs under emulation. Windows uses the BMC's own media libraries, so it needs
no C compiler.

</details>

To update on any platform, `git pull`, then run the installer again. To install
with a particular JDK, set `JAVA_HOME` (Windows: `-JavaHome <dir>`). The installed
app looks for Java 8 at every launch: `MEGARAC_JAVA_HOME` if set, then the JDK it
was installed with and the system's usual places.

## Use

Open MegaRAC Console. The first run asks for the BMC's address, user and
password. The login is saved after the BMC accepts it:
- macOS: the Keychain.
- Linux and FreeBSD: the Secret Service, via `secret-tool`. Without it, the
  login is asked for every time.
- Windows: a file encrypted for your Windows account (DPAPI).

From a terminal:

| Command | What it does |
|---|---|
| `megarac-console` | open the console |
| `BMC_HOST=<address> megarac-console` | open a different BMC than the saved one |
| `BMC_ISO=<image.iso> megarac-console` | mount that image as the server's virtual CD once video starts; the log shows how much the server has read |
| `megarac-console --diagnose` | check TLS, the login and the launch file, then print a report with every secret removed; attach it to a bug report |
| `megarac-console forget` | delete the saved login and address |

On macOS, the command is `"/Applications/MegaRAC Console.app/Contents/MacOS/megarac-console"`.
On Windows, run `powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\megarac-console\app\launch.ps1"`
with `-Iso <image.iso>`, `-Diagnose` or `-Forget`. The viewer's own Media menu can also
mount an image at any time.

`MEGARAC_JAVA_OPTS` passes extra options to the viewer's Java, for example
`-Dsun.java2d.uiScale=2` on a HiDPI Linux screen.

## Where things are kept, and uninstalling

| | macOS | Linux and FreeBSD | Windows |
|---|---|---|---|
| App | `/Applications/MegaRAC Console.app` | `~/.local/share/megarac-console`, `~/.local/bin/megarac-console`, `~/.local/share/applications/megarac-console.desktop` | `%LOCALAPPDATA%\megarac-console\app`, the Start-menu shortcut |
| Viewer jars from the BMC | `~/Library/Caches/megarac-console` | `~/.cache/megarac-console` | `%LOCALAPPDATA%\megarac-console\cache` |
| Log of the last run | `~/Library/Logs/megarac-console.log` | `~/.local/state/megarac-console/megarac-console.log` | `%LOCALAPPDATA%\megarac-console\megarac-console.log` |
| Saved login | Keychain, `megarac-console:<address>` | Secret Service, `megarac-console:<address>` | `%LOCALAPPDATA%\megarac-console\login-<address>.txt` |
| Address and window size | Java preferences, node `megarac-console` | `~/.java/.userPrefs/megarac-console` | registry, `HKCU\Software\JavaSoft\Prefs\megarac-console` |

To uninstall:
1. Delete each saved login: `BMC_HOST=<address> megarac-console forget` for every
   BMC you used.
2. Run `./install.sh --uninstall` (Windows: `.\install.ps1 -Uninstall`).
3. Delete the cache, the log, and the address and window size from the table.
   On Windows that means the whole `%LOCALAPPDATA%\megarac-console` folder, plus
   `Remove-Item -Recurse HKCU:\Software\JavaSoft\Prefs\megarac-console`.

The log never contains the password, the session cookie, the CSRF token or the
console token. The viewer gets the cookie and token on its input, not on its
command line, so other users of the computer can't see them in a process list.
(If Fit can't be used with your BMC's viewer, the viewer has to take them as
arguments.)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/readme/divider-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="assets/readme/divider-light.svg">
  <img alt="" src="assets/readme/divider-light.svg" width="100%">
</picture>

## Troubleshooting

<details>
<summary><b>Older BMCs speak only TLS 1.0 or 1.1, with old keys,</b> which Java 8 now refuses.</summary>

When the first connection fails, MegaRAC Console starts again with
`src/legacy-tls.security`, which allows them, and remembers that for the BMC.
The BMC's self-signed certificate is never checked.

</details>

<details>
<summary><b>"does not compile against this viewer"</b></summary>

Another firmware's viewer differs from the one `src/Fit.java` was written for.
The viewer then runs without Fit's fixes. A `--diagnose` report in an issue
helps make Fit work with it.

</details>

<details>
<summary><b>FreeBSD:</b> the viewer misbehaves</summary>

The viewer was written for Windows, Linux and macOS. If it misbehaves, try
`MEGARAC_JAVA_OPTS=-Dos.name=Linux`.

</details>

<details>
<summary><b>Linux on Wayland</b></summary>

It needs XWayland. Java 8 ignores desktop scaling; use
`MEGARAC_JAVA_OPTS=-Dsun.java2d.uiScale=2`.

</details>

<details>
<summary><b>The BMC allows only four or five web sessions.</b></summary>

MegaRAC Console always logs out, including when the viewer crashes or the
launcher is stopped. A session leaked by something else times out on the BMC.

</details>

## Platform status

"CI" means built and tested against a fake BMC on GitHub's runners on every push.
"BMC" means checked by hand against a real BMC.

| Platform | Media library | Status |
|---|---|---|
| macOS, Apple silicon | `media.c` | CI, and BMC: the console, typing, and booting the server from a mounted ISO |
| macOS, Intel | `media.c` | CI |
| Linux x86_64 and aarch64 | `media.c` | CI |
| FreeBSD amd64 | `media.c` | builds; untested |
| Windows x64 (ARM64 under emulation) | the BMC's own | CI |

Not yet confirmed on any machine: the viewer's Full Screen mode.

## Tested hardware

| Server | BMC firmware |
|---|---|
| Quanta D51B-2U | 3.83.00 (the last release) |

Please open an issue with a `--diagnose` report for any other board, whether it
works or not.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/readme/divider-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="assets/readme/divider-light.svg">
  <img alt="" src="assets/readme/divider-light.svg" width="100%">
</picture>

## How it works

The BMC's web API, as used here:
1. `POST /rpc/WEBSES/create.asp` with the form fields `WEBVAR_USERNAME` and
   `WEBVAR_PASSWORD`. The reply is JavaScript, not JSON, holding
   `'SESSION_COOKIE' : '…'` and, on newer firmware, `'CSRFTOKEN' : '…'`. A cookie
   starting with `Failure` means the login was refused.
2. Every later request sends `Cookie: SessionCookie=<cookie>` and the header
   `CSRFTOKEN: <token>`.
3. `GET /Java/jviewer.jnlp?EXTRNIP=<address>&JNLPSTR=JViewer`. Its `<argument>`
   elements are the viewer's command line, including a one-time console token.
   Its `<jar>` elements name the viewer jars, under `/Java/release/`. Its
   per-platform `<nativelib>` elements name the media libraries (`Win64.jar` for
   Windows x64).
4. `GET /rpc/WEBSES/logout.asp` when done.

The console itself uses TCP port 7578; virtual media uses 5120, 5122 and 5123.

The launcher (`src/MegaracConsole.java`) runs the viewer in a second Java process
with `java.library.path` pointing at the media libraries, wrapped by
`src/Fit.java`. `src/media.c` implements the three JNI libraries the viewer loads
(`javacdromwrapper`, `javafloppywrapper`, `javaharddiskwrapper`). It is a
line-for-line port of the Intel library's ISO-image code, written to reply to the
server byte for byte as that library does. With `media.c` (every OS but Windows),
physical drives and floppy and hard-disk redirection are not supported.

## Development

```sh
test/test-media.sh "$JAVA_HOME"      # media.c against the recorded replies
test/test-launcher.sh "$JAVA_HOME"   # installs into a temporary home, runs against test/fake_bmc.py
```
`test/test-windows.ps1` is the Windows counterpart; CI runs all three
(`.github/workflows/test.yml`).

`test/expected.sha256` holds the replies `media.c` must give. They were recorded
from `media.c` itself and are not yet re-checked against AMI's Intel library;
CI proves every platform's build agrees with them. On a Mac that still has Rosetta
and an Intel Java 8, `test/test-media.sh --intel <Mac64.jar> <jar dir>` re-records
them from the Intel library, after checking that `media.c` matches it on both
architectures. `--diagnose` saves `Mac64.jar` and the viewer jars in the
cache's `diagnose` folder.

The pictures in this README are in `assets/readme/`, a dark and a light version
of each.

## License

GPL-3.0-or-later; see [LICENSE](LICENSE). Copyright (C) 2026 Jeff Morrison.

This repository never contains AMI's viewer or libraries: each BMC serves its
own, and MegaRAC Console downloads them from your BMC to your computer at run
time. Not affiliated with AMI; MegaRAC is a trademark of American Megatrends.

<br>

<p align="center"><img src="assets/megarac-console.png" width="56" alt=""></p>
