# SPDX-FileCopyrightText: 2026 Jeff Morrison
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Installs MegaRAC Console for this user on Windows.
#   irm https://raw.githubusercontent.com/successful-accident/megarac-console/main/install.ps1 | iex
#       the latest release, with Java 8 included: a Start-menu shortcut and the
#       megarac-console command
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 [-JavaHome <JDK>] [-Uninstall]
#       in a git checkout: build from source with a Java 8 JDK found on this
#       machine; the shortcut runs launch.ps1, which finds Java 8 at every launch
# MEGARAC_PACKAGE=<setup.exe> installs that release package instead of downloading one.
# On Windows the viewer uses the BMC's own media libraries, so no C compiler is needed.
param([string]$JavaHome, [switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$app = Join-Path $env:LOCALAPPDATA 'megarac-console\app'
$link = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\MegaRAC Console.lnk'
$release = $env:MEGARAC_PACKAGE -or -not ($PSScriptRoot -and (Test-Path "$PSScriptRoot\src\MegaracConsole.java"))

# Runs a program and waits for it. Windows PowerShell 5.1 reports no exit code
# from Start-Process -PassThru unless the handle is read first.
function Run([string]$exe, [string[]]$arguments) {
  $p = Start-Process $exe -ArgumentList $arguments -PassThru
  $null = $p.Handle
  $p.WaitForExit()
  $p.ExitCode
}

if ($Uninstall) {
  if (Test-Path "$app\unins000.exe") {
    # It hands over to a copy of itself and returns at once; it deletes itself when done.
    $null = Run "$app\unins000.exe" '/VERYSILENT', '/SUPPRESSMSGBOXES'
    foreach ($i in 1..120) { if (-not (Test-Path "$app\unins000.exe")) { break }; Start-Sleep -Milliseconds 500 }
  }
  Remove-Item -Recurse -Force $app, $link -ErrorAction Ignore
  "removed MegaRAC Console. The saved login, cache and log stay; the README's Uninstall section lists them."
  exit 0
}

if ($release) {
  # No exit in this branch: run through iex, it would close the window.
  $setup = $env:MEGARAC_PACKAGE
  if (-not $setup) {
    $url = 'https://github.com/successful-accident/megarac-console/releases/latest/download/megarac-console-windows-x64-setup.exe'
    $setup = Join-Path ([IO.Path]::GetTempPath()) 'megarac-console-windows-x64-setup.exe'
    "downloading $url"
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue' # Windows PowerShell 5.1 downloads far slower with it
    Invoke-WebRequest -UseBasicParsing $url -OutFile $setup
  }
  $code = Run $setup '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER', "/DIR=`"$app`""
  if ($code -ne 0) { throw "the installer failed with exit code $code" }
  "installed $app. Open MegaRAC Console from the Start menu, or run megarac-console in a new terminal."
} else {
  # A Java 8 JDK: a compiler, and the rt.jar that Java 9 and later no longer have.
  $found = @($JavaHome, $env:JAVA_HOME) + @(Get-ChildItem -Directory -ErrorAction Ignore `
      "$env:ProgramFiles\Eclipse Adoptium\jdk-8*", "$env:ProgramFiles\Zulu\zulu-8*", "$env:ProgramFiles\Java\jdk1.8*" |
    Sort-Object Name -Descending | ForEach-Object FullName)
  $jdk = $found | Where-Object { $_ -and (Test-Path "$_\bin\javac.exe") -and (Test-Path "$_\jre\lib\rt.jar") } |
    Select-Object -First 1
  if (-not $jdk) { throw 'No Java 8 JDK found. Install one: winget install --id EclipseAdoptium.Temurin.8.JDK -e' }

  # Build in a scratch directory first, so a failure leaves an earlier install as it was.
  $stage = Join-Path ([IO.Path]::GetTempPath()) ('megarac-console-' + [guid]::NewGuid())
  New-Item -ItemType Directory -Force "$stage\classes" | Out-Null
  & "$jdk\bin\javac.exe" -nowarn -encoding UTF-8 -d "$stage\classes" "$PSScriptRoot\src\MegaracConsole.java"
  if ($LASTEXITCODE -ne 0) { throw 'javac failed' }
  Copy-Item "$PSScriptRoot\src\Fit.java", "$PSScriptRoot\src\legacy-tls.security", "$PSScriptRoot\launch.ps1",
    "$PSScriptRoot\assets\megarac-console.ico" $stage
  Remove-Item -Recurse -Force $app -ErrorAction Ignore
  New-Item -ItemType Directory -Force (Split-Path $app) | Out-Null
  Move-Item $stage $app
  # launch.ps1 tries this JDK too, so one chosen with -JavaHome keeps working.
  Set-Content -LiteralPath "$app\jdk.txt" $jdk

  # The shortcut runs launch.ps1, which finds Java 8 at every launch, so updating
  # Java never breaks it. Minimized and hidden: no console window shows.
  New-Item -ItemType Directory -Force (Split-Path $link) | Out-Null
  $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($link)
  $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$app\launch.ps1`""
  $shortcut.IconLocation = "$app\megarac-console.ico"
  $shortcut.WindowStyle = 7
  $shortcut.Description = 'Remote console of an AMI MegaRAC BMC'
  $shortcut.Save()
  "installed $app and $link (Java 8 from $jdk)"
}
