program deploy;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
  {$ENDIF}{$ENDIF}
  Classes, SysUtils, CustApp, Windows, Registry, WinInet, FileUtil,
  httpprotocol, HlpHashFactory, Zipper;

type
  IsWow64Process = function(hProcess: THandle; var Wow64Process: Bool): Bool; Stdcall;

  { TMyDeploy }

  TMyDeploy = class(TCustomApplication)
  protected
    procedure DoRun; override;
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
    procedure WriteVersion; virtual;
    procedure WriteLicense; virtual;
    procedure WriteHelp; virtual;
    procedure WriteArchitectureIncompatible; virtual;
    procedure WriteCommandExecuteProblem; virtual;
    procedure WriteFileDownload; virtual;
    procedure WriteFileNotFound; virtual;
    procedure WriteHashMismatch; virtual;
    procedure WriteNotRequired; virtual;
  end;

{ TMyDeploy }

function IsWindows64: Boolean;
var
  hdle64: IsWow64Process;
  Wow64Process: Bool;
begin
  IsWindows64 := False;
  hdle64 := IsWow64Process(Pointer(GetProcAddress(GetModuleHandle('kernel32.dll'), 'IsWow64Process')));
  if Assigned(hdle64) then
  begin
    if not hdle64(GetCurrentProcess, Wow64Process) then
      raise Exception.Create('invalid handle');
    IsWindows64 := Wow64Process;
  end;
end;

function GetApplicationVersion(const ApplicationUninstallKey: String): String;
var
  Registry: TRegistry;
begin
  GetApplicationVersion := '';
  if ApplicationUninstallKey <> '' then
  begin
    Registry := TRegistry.Create;
    try
      Registry.Access := KEY_WOW64_64KEY;
      Registry.RootKey := HKEY_LOCAL_MACHINE;
      if Registry.OpenKeyReadOnly('\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\' + ApplicationUninstallKey) then
        GetApplicationVersion := Registry.ReadString('DisplayVersion');
      Registry.CloseKey;

      if GetApplicationVersion = '' then
      begin
        Registry.Access := KEY_WOW64_32KEY;
        Registry.RootKey := HKEY_LOCAL_MACHINE;
        if Registry.OpenKeyReadOnly('\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\' + ApplicationUninstallKey) then
          GetApplicationVersion := Registry.ReadString('DisplayVersion');
        Registry.CloseKey;
      end;
    finally
      Registry.Free;
    end;
  end;
end;

function CompareInt(const i1, i2: Integer): Integer;
begin
  if i1 > i2 then
    CompareInt := 1
  else if i1 < i2 then
    CompareInt := -1
  else
    CompareInt := 0;
end;

function ExtractVersionNum(var Version: String): String;
var
  i: Integer;
begin
  i := Pos('.', Version);
  if i <> 0 then
  begin
    ExtractVersionNum := Copy(Version, 1, i - 1);
    Delete(Version, 1, i);
  end
  else
  begin
    ExtractVersionNum := Version;
    Version := '';
  end;
end;

function CompareVersion(Version1, Version2: String): Integer;
var
  N1, N2: String;
begin
  repeat
    N1 := ExtractVersionNum(Version1);
    N2 := ExtractVersionNum(Version2);

    if (N1 <> '') and (N2 <> '') then
      CompareVersion := CompareInt(StrToInt(N1), StrToInt(N2))
    else if (N1 = '') and (N2 = '') then
       CompareVersion := 0
    else if N1 = '' then
      CompareVersion := CompareInt(0, StrToInt(N2))
    else
      CompareVersion := CompareInt(StrToInt(N1), 0)

  until (CompareVersion <> 0) or (N1 = '') or (N2 = '');
end;

function GetOnlyVersion(const Version: String): String;
var i, p: Integer;
begin
  p := Pos('.', Version);
  i := Pos(' ', Version);
  if p <> 0 then
  begin
    if i <> 0 then
    begin
      if i > p then
        GetOnlyVersion := Copy(Version, 1, i - 1)
      else
        GetOnlyVersion := Copy(Version, i + 1, Length(Version))
    end
    else
      GetOnlyVersion := Version;
  end
  else
    GetOnlyVersion := '';
end;

function CommandExecute(const CommandLine, WorkDir: String): Boolean;
var
  SI: TStartupInfo;
  PI: TProcessInformation;
  OldCurrentDir: String;
begin
  CommandExecute := false;
  try
    if WorkDir <> '' then
    begin
      OldCurrentDir := GetCurrentDir;
      if DirectoryExists(WorkDir) then
        SetCurrentDir(WorkDir);
    end;
    FillChar(SI, SizeOf(SI), 0);
    SI.cb := SizeOf(SI);
    SI.dwFlags := STARTF_USESHOWWINDOW or STARTF_USESTDHANDLES;
    SI.wShowWindow := SW_HIDE;
    SI.hStdInput := GetStdHandle(STD_INPUT_HANDLE);
    CommandExecute := CreateProcess(nil, PChar(CommandLine), nil, nil, True, 0, nil, nil, SI, PI);
    WaitForSingleObject(PI.hProcess, INFINITE);
    CloseHandle(PI.hThread);
    CloseHandle(PI.hProcess);
  finally
    if WorkDir <> '' then
      SetCurrentDir(OldCurrentDir);
  end;
end;

function DownloadFile(const URL, DestFileName: String): Boolean;
const
  BufferSize = 1024 * 512;
var
  HInet, HURL: HInternet;
  Buffer: array[1..BufferSize] of Byte;
  BufferLen: DWord;
  f: File;
  UserAgent: String;
  Size: Integer;
  dwIndex: Cardinal;
  dwCode: array[1..20] of AnsiChar;
  dwCodeLen: DWord;
  ReturnCode: PAnsiChar;
begin
  DownloadFile := false;
  UserAgent := ExtractFileName(ParamStr(0));
  HInet := InternetOpen(PChar(UserAgent), INTERNET_OPEN_TYPE_PRECONFIG, nil, nil, 0);
  try
    HURL := InternetOpenUrl(HInet, PChar(URL), nil, 0, INTERNET_FLAG_DONT_CACHE + INTERNET_FLAG_KEEP_CONNECTION, 0);
    if Assigned(HURL) then
    try
      dwIndex := 0;
      dwCodeLen := SizeOf(dwCode);
      HttpQueryInfo(HURL, HTTP_QUERY_STATUS_CODE, @dwCode, dwCodeLen, dwIndex);
      ReturnCode := PAnsiChar(@dwCode);
      if (ReturnCode ='200') or (ReturnCode ='302') then
      begin
        Size := 0;
        try
          AssignFile(f, DestFileName) ;
          try
            Rewrite(f, 1) ;
            repeat
              BufferLen := 0;
              if InternetReadFile(HURL, @Buffer, SizeOf(Buffer), BufferLen) then
              begin
                Inc(Size, BufferLen);
                BlockWrite(f, Buffer, BufferLen);
              end;
            until BufferLen = 0;
          finally
            CloseFile(f);
          end;
        except
          if FileExists(DestFileName) then
            SysUtils.DeleteFile(DestFileName);
          raise;
        end;
        DownloadFile := (Size > 0);
      end;
    finally
      InternetCloseHandle(HURL);
    end;
  finally
    InternetCloseHandle(HInet);
  end;
end;

function sha256(const FileName: String): String;
begin
  sha256 := LowerCase(THashFactory.TCrypto.CreateSHA2_256().ComputeFile(FileName).ToString());
end;

function ReplaceSingleQuotes(StringSingleQuotes : String): String;
begin
   ReplaceSingleQuotes := StringReplace(StringSingleQuotes, '''' , '"', [rfReplaceAll]);
end;

procedure TMyDeploy.DoRun;
var
  ErrorMsg, Architecture, ApplicationUninstallKey, ApplicationVersion, CmdLine, FileName, MinVersion, Path, Hash, URL: String;
  UnZipper: TUnZipper;
begin
  // check parameters
  ErrorMsg := CheckOptions('a:c:k:m:u:s:hv', 'arch: cmdline: key: min: url: sha: help version');
  if ErrorMsg <> '' then
  begin
    WriteVersion;
    WriteHelp;
    Terminate;
    Exit;
  end;

  if (HasOption('h', 'help')) then
  begin
    WriteVersion;
    WriteHelp;
    Terminate;
    Exit;
  end;

  if (HasOption('v', 'version')) then
  begin
    WriteVersion;
    WriteLicense;
    Terminate;
    Exit;
  end;

  if (HasOption('c', 'cmdline')) = false then
  begin
    WriteVersion;
    WriteHelp;
    Terminate;
    ExitCode := 13;
    Exit;
  end;

  // get values in parameters
  Architecture := GetOptionValue('a', 'arch');
  CmdLine := GetOptionValue('c', 'cmdline');
  ApplicationUninstallKey := GetOptionValue('k', 'key');
  MinVersion := GetOptionValue('m', 'min');
  URL := GetOptionValue('u', 'url');
  Hash := GetOptionValue('s', 'sha');

  // check architecture
  if (Architecture <> 'x86') and (Architecture <> 'x64') then
    Architecture := 'all'
  else
  begin
    if IsWindows64 = true then
    begin
      if Architecture = 'x86' then
      begin
        WriteArchitectureIncompatible;
        Terminate;
        ExitCode := 10;
        Exit;
      end;
    end
    else
    begin
      if Architecture = 'x64' then
      begin
        WriteArchitectureIncompatible;
        Terminate;
        ExitCode := 10;
        Exit;
      end;
    end;
  end;

  // get application version installed
  if (ApplicationUninstallKey <> '') and (MinVersion <> '') then
    ApplicationVersion := GetApplicationVersion(ApplicationUninstallKey)
  else
    ApplicationVersion := '';

  // compare the application minimal version requiered with the installed version
  if (MinVersion = '') or (CompareVersion(GetOnlyVersion(MinVersion), GetOnlyVersion(ApplicationVersion)) = 1) then
  begin
    if URL <> '' then
    begin

      // download the file
      if Pos('http', URL) = 1 then
      begin
        Path := GetTempDir;
        FileName := Path + ExtractFileName(HTTPDecode(URL));
        if DownloadFile(URL, FileName) = false then
        begin
          WriteFileDownload;
          Terminate;
          ExitCode := 2;
          Exit;
        end;
      end
      else
      begin
        // copy the file
        if FileExists(URL) then
        begin
          Path := GetTempDir;
          FileName := Path + ExtractFileName(URL);
          CopyFile(URL, FileName);
        end
        else
        begin
          WriteFileNotFound;
          Terminate;
          ExitCode := 2;
          Exit;
        end;
      end;

      // check the hash
      if Hash <> '' then
      begin
         if sha256(FileName) <> Hash then
         begin
           // delete the file
           if FileExists(FileName) then
             SysUtils.DeleteFile(FileName);

           WriteHashMismatch;
           Terminate;
           ExitCode := 13;
           Exit;
         end;
      end;

      // zip file
      if ExtractFileExt(FileName) = '.zip' then
      begin
        Path := ExtractFileNameWithoutExt(FileName);
        if DirectoryExists(Path) then
          DeleteDirectory(Path, false);
        UnZipper := TUnZipper.Create;
        try
          UnZipper.FileName := FileName;
          UnZipper.OutputPath := Path;
          UnZipper.Examine;
          UnZipper.UnZipAllFiles;
        finally
          UnZipper.Free;
        end;
      end;
    end
    else
    begin
      Path := GetCurrentDir;
      FileName := '';
    end;

    // execute the command line
    if CommandExecute(ReplaceSingleQuotes(CmdLine), Path) = false then
      WriteCommandExecuteProblem;

    if FileName <> '' then
    begin
      // delete the directory
      if ExtractFileExt(FileName) = '.zip' then
          if DirectoryExists(Path) then
            DeleteDirectory(Path, false);

      // delete the file
      if FileExists(FileName) then
        SysUtils.DeleteFile(FileName);
    end;
  end
  else
    WriteNotRequired;

  Terminate;
end;

constructor TMyDeploy.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  StopOnException := True;
end;

destructor TMyDeploy.Destroy;
begin
  inherited Destroy;
end;

procedure TMyDeploy.WriteVersion;
begin
  writeln('deploy 1.1 : Copyright (c) 2021 Yoann LAMY');
  writeln();
end;

procedure TMyDeploy.WriteLicense;
begin
  writeln('You may redistribute copies of the program under the terms of the GNU General Public License v3 : https://github.com/ynlamy/deploy.');
  writeln('This program come with ABSOLUTELY NO WARRANTY.');
  writeln('This program use the HashLib4Pascal library : https://github.com/Xor-el/HashLib4Pascal.');
end;

procedure TMyDeploy.WriteHelp;
begin
  writeln('Usage: ', ExeName, ' -c <commandline> [-a <architecture>] [-k <key>] [-m <version>] [-u <url>] [-s <sha256>]');
  writeln();
  writeln('-a <architecture>, --arch=<architecture> : Execute command line only on the specified target architecture : all, x86, x64 (default : all)');
  writeln('-c <commandline>, --cmdline=<commandline> : Command line to execute');
  writeln('-k <key>, --key=<key> : Application uninstall key');
  writeln('-m <version>, --min=<version> : Minimum application version');
  writeln('-u <url>, --url=<url> : URL to use to download the file or to fecth the file (supports zip file)');
  writeln('-s <sha256>, --sha=<sha256> : Secure Hash Algorithm (SHA-256) of downloaded file or fetched file');
  writeln('-h, --help : Print this help screen');
  writeln('-v, --version : Print the version of the program and exit');
end;

procedure TMyDeploy.WriteArchitectureIncompatible;
begin
  writeln('incompatible architecture');
end;

procedure TMyDeploy.WriteCommandExecuteProblem;
begin
  writeln('command execution problem');
end;

procedure TMyDeploy.WriteFileDownload;
begin
  writeln('file not download');
end;

procedure TMyDeploy.WriteFileNotFound;
begin
  writeln('file not found');
end;

procedure TMyDeploy.WriteHashMismatch;
begin
  writeln('hash mismatch');
end;

procedure TMyDeploy.WriteNotRequired;
begin
  writeln('not required');
end;


var
  Application: TMyDeploy;

{$R *.res}

begin
  Application := TMyDeploy.Create(nil);
  Application.Run;
  Application.Free;
end.

