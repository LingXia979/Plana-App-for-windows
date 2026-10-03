; Built by tool/build_windows_installer.ps1 from a verified, sanitized bundle.
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef FileVersion
  #error FileVersion is required
#endif
#ifndef FilesInclude
  #error FilesInclude is required; use tool/build_windows_installer.ps1
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
#ifndef OutputBaseFilename
  #error OutputBaseFilename is required
#endif
#ifndef IconFile
  #error IconFile is required
#endif

#define AppName "Plana Windows"
#define AppExeName "plana_app_for_windows.exe"
#define AppUserModelID "LingXia979.PlanaWindows"

[Setup]
; Stable identity for all future Plana Windows installer upgrades.
AppId={{50D5C180-410F-4A2D-831A-2145B7336351}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=LingXia979
AppPublisherURL=https://github.com/LingXia979/Plana-App-for-windows
DefaultDirName={localappdata}\Programs\Plana
AppendDefaultDirName=no
; Accept newly created folders and existing installation directories directly.
DirExistsWarning=no
DisableDirPage=no
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
AllowNoIcons=no
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\{#AppExeName}
VersionInfoVersion={#FileVersion}
VersionInfoCompany=LingXia979
VersionInfoDescription=Plana Windows 中文安装程序
VersionInfoProductName={#AppName}
VersionInfoProductVersion={#FileVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableWelcomePage=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no
ShowLanguageDialog=no
LanguageDetectionMethod=none
Uninstallable=yes
CreateUninstallRegKey=not IsValidationRun
UsePreviousAppDir=not IsValidationRun
UsePreviousGroup=not IsValidationRun
UsePreviousTasks=not IsValidationRun
UsePreviousLanguage=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "languages\ChineseSimplified.isl"

[Messages]
chinesesimplified.SelectDirBrowseLabel=请选择一个可以写入的专用文件夹，程序会把作品保存到其中的 output 文件夹。更改位置请点击“浏览”，可选择或新建文件夹。
chinesesimplified.BrowseDialogTitle=选择安装文件夹
chinesesimplified.BrowseDialogLabel=请选择安装文件夹；也可以点击“新建文件夹”创建一个，然后点击“确定”。
chinesesimplified.ConfirmUninstall=确定要卸载 %1 及其程序组件吗？%n%n作品文件夹 output、图库、历史和账号设置会保留。

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式："; Flags: unchecked

[Files]
#include FilesInclude

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; AppUserModelID: "{#AppUserModelID}"; Check: not IsValidationRun
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon; AppUserModelID: "{#AppUserModelID}"; Check: not IsValidationRun

[Run]
Filename: "{app}\{#AppExeName}"; Description: "启动 Plana Windows"; Flags: nowait postinstall skipifsilent; Check: not IsValidationRun

; No blanket deletion: output and user-created files survive upgrades and
; uninstall. Windows user-profile settings/history are never installer inputs.
[Code]
function IsValidationRun: Boolean;
begin
  Result := ExpandConstant('{param:VALIDATION|0}') = '1';
end;

function InitializeSetup: Boolean;
begin
  Result := True;
  if IsValidationRun and (Trim(ExpandConstant('{param:DIR|}')) = '') then
  begin
    MsgBox('验证模式需要用 /DIR 指定独立的测试安装目录。', mbError, MB_OK);
    Result := False;
  end;
end;

const
  CLSID_FileOpenDialog =
    '{DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7}';
  IID_IShellItem =
    '{43826D1E-E718-42EE-BC55-A1E261C37BFE}';

  FOS_NOCHANGEDIR = $00000008;
  FOS_PICKFOLDERS = $00000020;
  FOS_FORCEFILESYSTEM = $00000040;
  FOS_PATHMUSTEXIST = $00000800;
  FOS_DONTADDTORECENT = $02000000;
  HRESULT_CANCELLED = -2147023673;

type
  IShellItem = interface(IUnknown)
    '{43826D1E-E718-42EE-BC55-A1E261C37BFE}'
    procedure DummyBindToHandler;
    procedure DummyGetParent;
    procedure DummyGetDisplayName;
    procedure DummyGetAttributes;
    procedure DummyCompare;
  end;

  IFileDialog = interface(IUnknown)
    '{42F85136-DB7E-439C-85F1-E4075D135FC8}'
    function Show(hwndOwner: HWND): HResult;
    procedure DummySetFileTypes;
    procedure DummySetFileTypeIndex;
    procedure DummyGetFileTypeIndex;
    procedure DummyAdvise;
    procedure DummyUnadvise;
    function SetOptions(fos: DWORD): HResult;
    function GetOptions(out fos: DWORD): HResult;
    procedure DummySetDefaultFolder;
    function SetFolder(psi: IShellItem): HResult;
    procedure DummyGetFolder;
    procedure DummyGetCurrentSelection;
    procedure DummySetFileName;
    procedure DummyGetFileName;
    function SetTitle(pszTitle: String): HResult;
    function SetOkButtonLabel(pszText: String): HResult;
    procedure DummySetFileNameLabel;
    function GetResult(out ppsi: IShellItem): HResult;
    procedure DummyAddPlace;
    procedure DummySetDefaultExtension;
    procedure DummyClose;
    procedure DummySetClientGuid;
    procedure DummyClearClientData;
    procedure DummySetFilter;
  end;

function SHCreateItemFromParsingName(
  pszPath: String;
  pbc: IUnknown;
  var riid: TGUID;
  out ppv: IUnknown): HResult;
  external 'SHCreateItemFromParsingName@shell32.dll stdcall delayload';

function SHGetIDListFromObject(
  punk: IUnknown;
  out ppidl: LongWord): HResult;
  external 'SHGetIDListFromObject@shell32.dll stdcall delayload';

function SHGetPathFromIDList(
  pidl: LongWord;
  pszPath: String): BOOL;
  external 'SHGetPathFromIDListW@shell32.dll stdcall delayload';

procedure CoTaskMemFree(pv: LongWord);
  external 'CoTaskMemFree@ole32.dll stdcall';

function lstrlenW(lpString: String): Integer;
  external 'lstrlenW@kernel32.dll stdcall';

function NearestExistingDirectory(Directory: String): String;
var
  ParentDirectory: String;
begin
  Directory := RemoveBackslashUnlessRoot(Directory);
  while (Directory <> '') and (not DirExists(Directory)) do
  begin
    ParentDirectory := ExtractFileDir(Directory);
    if (ParentDirectory = '') or
       (CompareText(ParentDirectory, Directory) = 0) then
      Break;
    Directory := RemoveBackslashUnlessRoot(ParentDirectory);
  end;

  if not DirExists(Directory) then
    Directory := ExpandConstant('{userdocs}');
  Result := Directory;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  ParentDirectory: String;
  ProbeDirectory: String;
  ProbeSuffix: Integer;
begin
  Result := True;
  if CurPageID <> wpSelectDir then
    Exit;

  { The app writes output beside its executable. Check the chosen directory
    (or the closest existing parent) without touching any existing file. }
  ParentDirectory := NearestExistingDirectory(WizardDirValue);
  ProbeDirectory := AddBackslash(ParentDirectory) +
    'plana-write-test-' + ExtractFileName(ExpandConstant('{tmp}'));
  ProbeSuffix := 0;
  while DirExists(ProbeDirectory) or FileExists(ProbeDirectory) do
  begin
    ProbeSuffix := ProbeSuffix + 1;
    ProbeDirectory := AddBackslash(ParentDirectory) +
      'plana-write-test-' + ExtractFileName(ExpandConstant('{tmp}')) +
      '-' + IntToStr(ProbeSuffix);
  end;
  if CreateDir(ProbeDirectory) then
    RemoveDir(ProbeDirectory)
  else
  begin
    MsgBox('无法写入所选文件夹。请选择当前用户的应用目录，或 D 盘等有写入权限的专用文件夹。', mbError, MB_OK);
    Result := False;
  end;
end;

function ShellItemFileSystemPath(Item: IShellItem): String;
var
  ItemIdList: LongWord;
  PathBuffer: String;
  PathLength: Integer;
begin
  Result := '';
  ItemIdList := 0;
  OleCheck(SHGetIDListFromObject(IUnknown(Item), ItemIdList));
  try
    PathBuffer := StringOfChar(#0, 32768);
    if not SHGetPathFromIDList(ItemIdList, PathBuffer) then
      RaiseException('所选项目不是文件系统文件夹。');

    PathLength := lstrlenW(PathBuffer);
    if PathLength <= 0 then
      RaiseException('无法读取所选文件夹路径。');
    SetLength(PathBuffer, PathLength);
    Result := PathBuffer;
  finally
    if ItemIdList <> 0 then
      CoTaskMemFree(ItemIdList);
  end;
end;

function SelectModernFolder(var Directory: String): Boolean;
var
  DialogObject: IUnknown;
  Dialog: IFileDialog;
  FolderObject: IUnknown;
  InitialFolder: IShellItem;
  SelectedItem: IShellItem;
  ShellItemId: TGUID;
  Options: DWORD;
  ShowResult: HResult;
  SelectedPath: String;
  InitialDirectory: String;
begin
  Result := False;

  DialogObject :=
    CreateComObject(StringToGUID(CLSID_FileOpenDialog));
  Dialog := IFileDialog(DialogObject);

  OleCheck(Dialog.GetOptions(Options));
  Options := Options or
    FOS_NOCHANGEDIR or
    FOS_PICKFOLDERS or
    FOS_FORCEFILESYSTEM or
    FOS_PATHMUSTEXIST or
    FOS_DONTADDTORECENT;
  OleCheck(Dialog.SetOptions(Options));
  OleCheck(Dialog.SetTitle('选择安装文件夹'));
  OleCheck(Dialog.SetOkButtonLabel('选择此文件夹'));

  InitialDirectory := NearestExistingDirectory(Directory);
  ShellItemId := StringToGUID(IID_IShellItem);
  if SHCreateItemFromParsingName(
    InitialDirectory,
    nil,
    ShellItemId,
    FolderObject) >= 0 then
  begin
    InitialFolder := IShellItem(FolderObject);
    OleCheck(Dialog.SetFolder(InitialFolder));
  end;

  ShowResult := Dialog.Show(WizardForm.Handle);
  if ShowResult = HRESULT_CANCELLED then
    Exit;

  OleCheck(ShowResult);
  OleCheck(Dialog.GetResult(SelectedItem));
  SelectedPath := ShellItemFileSystemPath(SelectedItem);

  SelectedPath := Trim(SelectedPath);
  Log('Modern folder picker returned: ' + SelectedPath);
  if SelectedPath <> '' then
  begin
    Directory := SelectedPath;
    Result := True;
  end;
end;

procedure ModernDirBrowseButtonClick(Sender: TObject);
var
  Directory: String;
begin
  Directory := WizardForm.DirEdit.Text;
  try
    if SelectModernFolder(Directory) then
    begin
      WizardForm.DirEdit.Text := Directory;
      Log('Installer directory updated to: ' + WizardForm.DirEdit.Text);
    end;
  except
    Log('Modern folder picker failed: ' + GetExceptionMessage);
    if BrowseForFolder(
      '选择安装文件夹',
      Directory,
      True) then
      WizardForm.DirEdit.Text := Directory;
  end;
end;

procedure InitializeWizard;
begin
  WizardForm.DirBrowseButton.OnClick :=
    @ModernDirBrowseButtonClick;
end;
