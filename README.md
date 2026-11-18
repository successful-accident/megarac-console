# MegaRAC Console

Opens the Java remote console (KVM) of older AMI MegaRAC SP BMCs on today's
macOS, Linux, FreeBSD and Windows, with no browser and no Java Web Start.

These BMCs offer their console only as a Java Web Start launch file, which no
current browser or Java will run. MegaRAC Console does the launch itself:
1. It logs in to the BMC's web API.
2. It fetches the launch file and the viewer jars the BMC serves.
3. It runs the viewer on Java 8, with fixes:
   - the picture scales to the window, and the window reopens at its last size
   - Pause then Resume redraws the whole screen
   - an ISO image can be mounted as the server's virtual CD at launch
   - Caps Lock takes one press on macOS
4. Where the BMC's own media libraries can't load (Apple silicon, Linux on ARM,
   FreeBSD), its replacement library `src/media.c` mounts ISO images instead.

> **Status: work in progress.** The launcher and its tests are here. Installers
> for each OS and the rest of this manual come next.

## Try it: the diagnosis

`--diagnose` checks that this computer can talk to your BMC, then logs out. It
prints the TLS version, whether the login works, the launch file with every
secret removed, and the jars and libraries the BMC offers. It needs a Java 8 JDK
(on macOS: `brew install --cask zulu@8`).

```sh
git clone https://github.com/successful-accident/megarac-console
cd megarac-console
mkdir -p build/classes
javac -d build/classes src/MegaracConsole.java
cp src/Fit.java src/legacy-tls.security build/
BMC_HOST=<your BMC's address> java -cp build/classes MegaracConsole --diagnose 2>&1
```

On macOS, put `"$(/usr/libexec/java_home -v 1.8)/bin/"` in front of `javac` and
`java` if Java 8 is not your default.

The first run asks for the BMC user and password, and saves them in the
system's credential store once the BMC accepts them: the macOS Keychain, the
Secret Service (`secret-tool`) on Linux and FreeBSD, or the Windows account.
`MegaracConsole forget` deletes them.

## License

GPL-3.0-or-later; see [LICENSE](LICENSE). Copyright (C) 2026 Jeff Morrison.

This repository never contains AMI's viewer or libraries: each BMC serves its
own, and MegaRAC Console downloads them from your BMC to your computer at run
time. Not affiliated with AMI; MegaRAC is a trademark of American Megatrends.
