; City Invaders installer for Windows (Inno Setup 6.3 or newer).
;
; A small setup that downloads the game: it reads catalog.ini (made by
; tools/build/map_packs.py release) from the release it was built for, lets
; the player pick the maps and downloads the game and those maps, checking
; each file's SHA-256. The files can then be as big as the release allows
; each one, and the setup stays a few MB. See docs/BUILDING.md.
;
; Build:  iscc /DAppVersion=0.2.0 /DCatalogUrl=https://.../catalog.ini tools\build\installer.iss
; Options when running it:
;   /CATALOG=<url>       another catalog (testing against a local server)
;   /MAPS=id1,id2        only these maps (default: all); with /VERYSILENT too

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef CatalogUrl
  #define CatalogUrl "https://github.com/vgartner/city-invaders/releases/latest/download/catalog.ini"
#endif

[Setup]
AppId={{6E0B9F3A-2C71-4D8E-9B5A-0F4C3D2E1A7B}
AppName=City Invaders
AppVersion={#AppVersion}
AppPublisher=City Invaders contributors
AppPublisherURL=https://github.com/vgartner/city-invaders
DefaultDirName={autopf}\City Invaders
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\build\installer
OutputBaseFilename=CityInvaders-{#AppVersion}-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\CityInvaders.exe
UninstallDisplayName=City Invaders

[Tasks]
Name: desktopicon; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; downloaded into {tmp} before the install step (see [Code])
; (files already installed and unchanged are not downloaded again)
Source: "{tmp}\CityInvaders.exe"; DestDir: "{app}"; Flags: external ignoreversion skipifsourcedoesntexist
Source: "{tmp}\CityInvaders.pck"; DestDir: "{app}"; Flags: external ignoreversion skipifsourcedoesntexist
Source: "{tmp}\CityInvaders-map-*.pck"; DestDir: "{app}\maps"; Flags: external ignoreversion skipifsourcedoesntexist

[Icons]
Name: "{autoprograms}\City Invaders"; Filename: "{app}\CityInvaders.exe"
Name: "{autodesktop}\City Invaders"; Filename: "{app}\CityInvaders.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\CityInvaders.exe"; Description: "{cm:LaunchProgram,City Invaders}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: dirifempty; Name: "{app}\maps"

[Code]
var
  CatalogFile, BaseUrl: String;
  MapIds: TArrayOfString;
  MapPage: TInputOptionWizardPage;
  DownloadPage: TDownloadWizardPage;

function SplitList(S: String): TArrayOfString;
var
  P: Integer;
begin
  SetArrayLength(Result, 0);
  S := Trim(S);
  while S <> '' do
  begin
    P := Pos(',', S);
    if P = 0 then P := Length(S) + 1;
    SetArrayLength(Result, GetArrayLength(Result) + 1);
    Result[GetArrayLength(Result) - 1] := Trim(Copy(S, 1, P - 1));
    Delete(S, 1, P);
  end;
end;

function Catalog(Section, Key: String): String;
begin
  Result := GetIniString(Section, Key, '', CatalogFile);
end;

function Megabytes(Section: String): String;
begin
  Result := IntToStr(StrToInt64Def(Catalog(Section, 'size'), 0) div 1048576) + ' MB';
end;

{ /MAPS=a,b picks the maps; without it every map is checked. }
function MapWanted(Id: String): Boolean;
var
  Wanted: String;
begin
  Wanted := ExpandConstant('{param:MAPS}');
  Result := (Wanted = '') or (Pos(',' + Id + ',', ',' + Wanted + ',') > 0);
end;

{ Already installed and the same file: running the setup again to add a map
  doesn't download the game again. }
function Installed(Dest, Sha: String): Boolean;
begin
  Result := FileExists(Dest) and (Sha <> '') and (CompareText(GetSHA256OfFile(Dest), Sha) = 0);
end;

procedure Fetch(Url, Name, Dest, Sha: String);
begin
  if Installed(Dest, Sha) then
    Log('Up to date: ' + Dest)
  else
    DownloadPage.Add(Url, Name, Sha);
end;

function InitializeSetup(): Boolean;
var
  Url: String;
  I: Integer;
begin
  Url := ExpandConstant('{param:CATALOG}');
  if Url = '' then
    Url := '{#CatalogUrl}';
  { the files sit next to the catalog }
  I := Length(Url);
  while (I > 0) and (Url[I] <> '/') do
    I := I - 1;
  BaseUrl := Copy(Url, 1, I);
  CatalogFile := ExpandConstant('{tmp}\catalog.ini');
  try
    DownloadTemporaryFile(Url, 'catalog.ini', '', nil);
  except
    SuppressibleMsgBox('Could not download the list of game files from' + #13#10 + Url + #13#10#13#10 +
      GetExceptionMessage, mbCriticalError, MB_OK, IDOK);
    Result := False;
    exit;
  end;
  MapIds := SplitList(Catalog('catalog', 'maps'));
  Result := GetArrayLength(MapIds) > 0;
  if not Result then
    SuppressibleMsgBox('The list of game files has no maps.', mbCriticalError, MB_OK, IDOK);
end;

procedure InitializeWizard();
var
  I: Integer;
begin
  MapPage := CreateInputOptionPage(wpSelectDir, 'Maps', 'Which maps do you want to play?',
    'Each map is downloaded on its own. To add a map later, run this setup again.', False, False);
  for I := 0 to GetArrayLength(MapIds) - 1 do
  begin
    MapPage.Add(Catalog('map:' + MapIds[I], 'name') + '   (' + Megabytes('map:' + MapIds[I]) + ')');
    MapPage.Values[I] := MapWanted(MapIds[I]);
  end;
  DownloadPage := CreateDownloadPage(SetupMessage(msgWizardPreparing), 'Downloading City Invaders...', nil);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  I, Chosen: Integer;
  Files: TArrayOfString;
  F: String;
begin
  Result := True;
  if CurPageID = MapPage.ID then
  begin
    Chosen := 0;
    for I := 0 to GetArrayLength(MapIds) - 1 do
      if MapPage.Values[I] then Chosen := Chosen + 1;
    if Chosen = 0 then
    begin
      SuppressibleMsgBox('Choose at least one map.', mbError, MB_OK, IDOK);
      Result := False;
    end;
  end
  else if CurPageID = wpReady then
  begin
    DownloadPage.Clear;
    Files := SplitList(Catalog('catalog', 'game'));
    for I := 0 to GetArrayLength(Files) - 1 do
      Fetch(BaseUrl + Files[I], Files[I], ExpandConstant('{app}\') + Files[I], Catalog('file:' + Files[I], 'sha256'));
    for I := 0 to GetArrayLength(MapIds) - 1 do
      if MapPage.Values[I] then
      begin
        F := Catalog('map:' + MapIds[I], 'file');
        Fetch(BaseUrl + F, F, ExpandConstant('{app}\maps\') + F, Catalog('map:' + MapIds[I], 'sha256'));
      end;
    DownloadPage.Show;
    try
      try
        DownloadPage.Download;
      except
        if DownloadPage.AbortedByUser then
          Log('Download cancelled')
        else
          SuppressibleMsgBox(AddPeriod(GetExceptionMessage), mbCriticalError, MB_OK, IDOK);
        Result := False;
      end;
    finally
      DownloadPage.Hide;
    end;
  end;
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,
  MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
var
  I: Integer;
  Maps: String;
begin
  Maps := '';
  for I := 0 to GetArrayLength(MapIds) - 1 do
    if MapPage.Values[I] then
      Maps := Maps + Space + Catalog('map:' + MapIds[I], 'name') + NewLine;
  Result := MemoDirInfo + NewLine + NewLine + 'Maps:' + NewLine + Maps;
  if MemoTasksInfo <> '' then
    Result := Result + NewLine + MemoTasksInfo;
end;
