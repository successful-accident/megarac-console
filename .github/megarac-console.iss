; SPDX-FileCopyrightText: 2026 Jeff Morrison
; SPDX-License-Identifier: GPL-3.0-or-later
;
; The Windows release package: MegaRAC Console with a Java 8 JDK inside, installed
; for this user, with a Start-menu shortcut and the megarac-console command on PATH.
; The test workflow builds it, after javac has compiled the launcher into build\classes:
;   iscc /DJdk=<JDK> /DVersion=<version> /O<output dir> .github\megarac-console.iss
#ifndef Version
  #define Version "0-dev"
#endif

[Setup]
AppId=io.github.successful-accident.megarac-console
AppName=MegaRAC Console
AppVersion={#Version}
AppPublisherURL=https://github.com/successful-accident/megarac-console
SourceDir=..
DefaultDirName={localappdata}\megarac-console\app
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
ChangesEnvironment=yes
OutputBaseFilename=megarac-console-windows-x64-setup
SetupIconFile=assets\megarac-console.ico
UninstallDisplayIcon={app}\megarac-console.ico
WizardStyle=modern
Compression=lzma2
SolidCompression=yes

[Files]
Source: "build\classes\*"; DestDir: "{app}\classes"; Flags: recursesubdirs
Source: "src\Fit.java"; DestDir: "{app}"
Source: "src\legacy-tls.security"; DestDir: "{app}"
Source: "assets\megarac-console.ico"; DestDir: "{app}"
Source: "LICENSE"; DestDir: "{app}"
Source: ".github\megarac-console.cmd"; DestDir: "{app}\bin"
Source: "{#Jdk}\*"; DestDir: "{app}\jdk"; Excludes: "src.zip,javafx-src.zip,\man,\sample,\demo"; Flags: recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\MegaRAC Console"; Filename: "{app}\jdk\bin\javaw.exe"; Parameters: "-cp ""{app}\classes"" MegaracConsole"; WorkingDir: "{app}"; IconFilename: "{app}\megarac-console.ico"; Comment: "Remote console of an AMI MegaRAC BMC"

[Registry]
Root: HKCU; Subkey: "Environment"; ValueType: expandsz; ValueName: "Path"; ValueData: "{olddata};{app}\bin"; Check: NotOnPath(ExpandConstant('{app}\bin'))

[Code]
function NotOnPath(Dir: string): Boolean;
var
  Path: string;
begin
  if not RegQueryStringValue(HKCU, 'Environment', 'Path', Path) then Path := '';
  Result := Pos(';' + Uppercase(Dir) + ';', ';' + Uppercase(Path) + ';') = 0;
end;

procedure CurUninstallStepChanged(Step: TUninstallStep);
var
  Path, Dir: string;
  P: Integer;
begin
  if (Step = usPostUninstall) and RegQueryStringValue(HKCU, 'Environment', 'Path', Path) then
  begin
    Dir := ';' + ExpandConstant('{app}\bin');
    P := Pos(Uppercase(Dir), Uppercase(Path));
    if P > 0 then
    begin
      Delete(Path, P, Length(Dir));
      RegWriteExpandStringValue(HKCU, 'Environment', 'Path', Path);
    end;
  end;
end;
