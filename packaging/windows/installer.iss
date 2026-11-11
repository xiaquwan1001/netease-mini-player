; 轻音 MiniNCM - Windows x64 安装包(Inno Setup)
; 用 ISCC 编译: iscc /DAppVersion=0.3.0 /O<输出目录> packaging\windows\installer.iss
; 输入 = flutter build windows --release 的产物(ui\build\windows\x64\runner\Release)
; Flutter 已经把 msvcp140/vcruntime140*.dll 一起放进 Release 目录, 所以这里整目录打包即可,
; 不需要额外打 VC++ 运行库。

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define AppName "轻音 MiniNCM"
#define AppExe "minincm.exe"
#define AppPublisher "MiniNCM"
#define AppUrl "https://github.com/xiaquwan1001/netease-mini-player"
#define SrcDir "..\..\ui\build\windows\x64\runner\Release"

[Setup]
AppId={{6E1B2F0A-6C4E-4C1E-9C3B-0A9E4C2D51A7}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
AppUpdatesURL={#AppUrl}/releases
DefaultDirName={autopf}\MiniNCM
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputBaseFilename=MiniNCM-{#AppVersion}-windows-x64-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
SetupIconFile=..\..\ui\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
LicenseFile=..\..\LICENSE

[Languages]
; 英文 = 编译器内置; 简中 = 随包的 packaging/windows/ChineseSimplified.isl
; (来源 issrc tag is-7_1_1 的官方语言文件, 文件头标注 6.5.0+ 兼容;
;  choco 的 innosetup 仍是 6.7.1 不自带, issrc 7.x 起才内置该文件)。
; 编译前 release.yml 会把它拷进编译器 Languages\ 目录(已存在则跳过), 本地编译见 README.md。
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "zh_cn"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SrcDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}\data"
