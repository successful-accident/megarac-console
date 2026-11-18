# SPDX-FileCopyrightText: 2026 Jeff Morrison
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Installs MegaRAC Console for this user on Windows: compiles the launcher with a
# Java 8 JDK and adds a Start-menu shortcut. Run it again after a git pull to
# update. On Windows the viewer uses the BMC's own media libraries, so no C
# compiler is needed.
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 [-JavaHome <JDK>] [-Uninstall]
param([string]$JavaHome, [switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$app = Join-Path $env:LOCALAPPDATA 'megarac-console\app'
$link = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\MegaRAC Console.lnk'

if ($Uninstall) {
  Remove-Item -Recurse -Force $app, $link -ErrorAction Ignore
  "removed MegaRAC Console. The saved login, cache and log stay; the README's Uninstall section lists them."
  exit 0
}

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

# The shortcut runs launch.ps1, which finds Java 8 at every launch, so updating
# Java never breaks it. Minimized and hidden: no console window shows.
$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($link)
$shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$app\launch.ps1`""
$shortcut.IconLocation = "$app\megarac-console.ico"
$shortcut.WindowStyle = 7
$shortcut.Description = 'Remote console of an AMI MegaRAC BMC'
$shortcut.Save()
"installed $app and $link (Java 8 from $jdk)"
