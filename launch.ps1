# SPDX-FileCopyrightText: 2026 Jeff Morrison
# SPDX-License-Identifier: GPL-3.0-or-later
#
# MegaRAC Console's entry point on Windows; the Start-menu shortcut runs it. It
# finds a Java 8 JDK at every launch, so updating Java never breaks the shortcut.
#   launch.ps1                    open the console
#   launch.ps1 -Iso <image.iso>   and mount that image as the server's virtual CD
#   launch.ps1 -Diagnose          check the BMC and print a report, in this window
#   launch.ps1 -Forget            delete the saved login and host
param([string]$Iso, [switch]$Diagnose, [switch]$Forget)

$found = @($env:MEGARAC_JAVA_HOME) + @(Get-ChildItem -Directory -ErrorAction Ignore `
    "$env:ProgramFiles\Eclipse Adoptium\jdk-8*", "$env:ProgramFiles\Zulu\zulu-8*", "$env:ProgramFiles\Java\jdk1.8*" |
  Sort-Object Name -Descending | ForEach-Object FullName)
$jdk = $found | Where-Object { $_ -and (Test-Path "$_\bin\javac.exe") -and (Test-Path "$_\jre\lib\rt.jar") } |
  Select-Object -First 1
if (-not $jdk) {
  Add-Type -AssemblyName System.Windows.Forms
  [void][System.Windows.Forms.MessageBox]::Show(
    "Java 8 is not installed. Install it with:`nwinget install --id EclipseAdoptium.Temurin.8.JDK -e", 'MegaRAC Console', 'OK', 'Error')
  exit 1
}
if ($Iso) { $env:BMC_ISO = (Resolve-Path $Iso).Path }
$classes = "$PSScriptRoot\classes"
if ($Diagnose -or $Forget) {
  & "$jdk\bin\java.exe" -cp $classes MegaracConsole $(if ($Diagnose) { '--diagnose' } else { 'forget' })
  exit $LASTEXITCODE
}
& "$jdk\bin\javaw.exe" -cp $classes MegaracConsole
