# SPDX-FileCopyrightText: 2026 Jeff Morrison
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The Windows checks, for CI: both PowerShell scripts parse; install.ps1 installs
# into a throwaway profile; and the installed launcher runs against fake_bmc.py.
# That is a --diagnose report, then a launch that unpacks the BMC's Windows
# libraries and saves the login with DPAPI, a second launch that reads it back,
# and forget.
#   test/test-windows.ps1     (JAVA_HOME: a Java 8 JDK; needs python and openssl)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$jdk = $env:JAVA_HOME
$t = Join-Path ([IO.Path]::GetTempPath()) ('megarac-test-' + [guid]::NewGuid())
New-Item -ItemType Directory "$t\local", "$t\roaming", "$t\home", "$t\stubs", "$t\served" | Out-Null
$password = "pa ss&=+%'*~" + [char]0x00E9
$secrets = 'CookieA1b2C3d4E5f6G7h8', 'CsrfZ9y8X7w6V5', 'TokenQ1w2E3r4T5y6U7i8', $password
$script:failed = 0
function Check([string]$name, [bool]$ok) {
  if ($ok) { "ok   $name" } else { "FAIL $name"; $script:failed = 1 }
}
function Launch([string]$stdin, [string[]]$more) { # returns the exit code; output in $t\out and $t\err
  [IO.File]::WriteAllText("$t\stdin", $stdin, (New-Object Text.UTF8Encoding $false))
  $p = Start-Process "$jdk\bin\java.exe" -ArgumentList (@('-cp', "`"$app\classes`"", 'MegaracConsole') + $more) `
    -RedirectStandardInput "$t\stdin" -RedirectStandardOutput "$t\out" -RedirectStandardError "$t\err" `
    -NoNewWindow -PassThru
  $null = $p.Handle # Windows PowerShell 5.1 reports no exit code without this
  $p.WaitForExit()
  $p.ExitCode
}
function Requests([string]$path) {
  @(Get-Content "$t\requests" | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.path -like "$path*" }).Count
}
function NoSecrets([string[]]$files) {
  $text = ($files | ForEach-Object { Get-Content -Raw $_ }) -join "`n"
  -not ($secrets | Where-Object { $text.Contains($_) })
}

foreach ($f in 'install.ps1', 'launch.ps1') {
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile("$root\$f", [ref]$null, [ref]$errors)
  Check "$f parses" ($errors.Count -eq 0)
}

# Installed the way a person would, into the throwaway profile.
$env:LOCALAPPDATA = "$t\local"
$env:APPDATA = "$t\roaming"
& "$root\install.ps1" -JavaHome $jdk | Out-Null
$app = "$t\local\megarac-console\app"
Check 'install: launcher compiled' (Test-Path "$app\classes\MegaracConsole.class")
Check 'install: Start-menu shortcut' (Test-Path "$t\roaming\Microsoft\Windows\Start Menu\Programs\MegaRAC Console.lnk")

# What the fake BMC serves: the stub viewer, and a Win64.jar holding a "library".
& "$jdk\bin\javac.exe" -nowarn -d "$t\stubs" (Get-ChildItem -Recurse "$PSScriptRoot\stubs" -Filter *.java).FullName
Push-Location "$t\stubs"
& "$jdk\bin\jar.exe" cf "$t\served\JViewer.jar" com
Pop-Location
Set-Content "$t\javacdromwrapper.dll" 'dll'
& "$jdk\bin\jar.exe" cf "$t\served\Win64.jar" -C $t javacdromwrapper.dll
Copy-Item "$t\served\Win64.jar" "$t\served\JViewer-SOC.jar"
Copy-Item "$t\served\Win64.jar" "$t\served\Mac64.jar"
# Windows PowerShell 5.1 turns a native command's redirected stderr (openssl's
# progress dots) into a terminating error under 'Stop'; check the result instead.
$ErrorActionPreference = 'Continue'
& openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=fake-bmc -keyout "$t\key.pem" -out "$t\cert.pem" 2>$null
$ErrorActionPreference = 'Stop'
if (-not (Test-Path "$t\cert.pem")) { throw 'openssl could not make the test certificate' }
$bmc = Start-Process python -NoNewWindow -PassThru -ArgumentList "`"$PSScriptRoot\fake_bmc.py`"",
  "`"$t\port`"", "`"$t\cert.pem`"", "`"$t\key.pem`"", "`"$t\served`"", "`"$t\requests`""
foreach ($i in 1..300) { if ((Test-Path "$t\port") -and (Get-Content "$t\port")) { break }; Start-Sleep -Milliseconds 100 }
if (-not ((Test-Path "$t\port") -and (Get-Content "$t\port"))) { throw 'fake_bmc.py did not start' }
$port = Get-Content "$t\port"
$env:BMC_HOST = "127.0.0.1:$port"
# Its own preferences node: Windows keeps prefs in the registry, so user.home can't isolate them.
$env:JAVA_TOOL_OPTIONS = "-Djava.awt.headless=true -Duser.home=$t\home -Dmegarac.prefs=megarac-console-test"
$env:STUB_NO_LIBS = '1'
$env:STUB_ARGS_FILE = "$t\args"
Remove-Item -Recurse HKCU:\Software\JavaSoft\Prefs\megarac-console-test -ErrorAction Ignore
$login = "admin`n$password`n"

$code = Launch $login '--diagnose'
Check 'diagnose: exit 0' ($code -eq 0)
Check 'diagnose: reports TLS' ((Get-Content -Raw "$t\out") -match 'tls: TLSv1')
Check 'diagnose: no secret printed' (NoSecrets "$t\out", "$t\err")
Check 'diagnose: logged out' ((Requests '/rpc/WEBSES/logout.asp') -eq 1)

$code = Launch $login @()
Check 'launch: exit 0' ($code -eq 0)
$expected = '-apptype', 'JViewer', '-hostname', '127.0.0.1', '-title', 'Server & Console - fake', '-kvmtoken',
  'TokenQ1w2E3r4T5y6U7i8', '-kvmport', '7578', '-webcookie', 'CookieA1b2C3d4E5f6G7h8'
Check 'launch: viewer got exactly the launch file''s arguments' (((Get-Content "$t\args") -join '|') -eq ($expected -join '|'))
Check "launch: the BMC's Windows library unpacked" (Test-Path "$t\local\megarac-console\cache\127.0.0.1_$port\lib\javacdromwrapper.dll")
Check 'launch: logged out' ((Requests '/rpc/WEBSES/logout.asp') -eq 2)
$saved = "$t\local\megarac-console\login-127.0.0.1_$port.txt"
Check 'launch: login saved with DPAPI, not in clear' ((Test-Path $saved) -and (NoSecrets $saved))
Check 'launch: no secret in output or log' (NoSecrets "$t\out", "$t\err", "$t\local\megarac-console\megarac-console.log")

$code = Launch '' @()
Check 'saved login: second launch asks nothing' ($code -eq 0)
$code = Launch '' 'forget'
Check 'forget: login deleted' (($code -eq 0) -and -not (Test-Path $saved))

Stop-Process $bmc -ErrorAction Ignore
Remove-Item -Recurse HKCU:\Software\JavaSoft\Prefs\megarac-console-test -ErrorAction Ignore
if ($script:failed) { Get-Content "$t\err" | Select-Object -Last 20; exit 1 }
'all Windows tests passed'
