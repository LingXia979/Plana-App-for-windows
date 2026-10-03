param(
    [string]$OutputDirectory,
    [string]$SevenZipDirectory,
    [string]$RuntimeCab,
    [string]$IsccPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workspaceRoot = Split-Path $projectRoot -Parent
if (!$OutputDirectory) { $OutputDirectory = Join-Path $workspaceRoot 'dist' }
if (!$SevenZipDirectory) {
    $SevenZipDirectory = Join-Path $env:USERPROFILE 'scoop/apps/7zip/current'
}
$sevenZip = Join-Path $SevenZipDirectory '7z.exe'
foreach ($required in @($sevenZip)) {
    if (!(Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing packaging tool: $required" }
}
if (!$RuntimeCab) {
    $RuntimeCab = Get-ChildItem -LiteralPath 'C:/ProgramData/Package Cache' -Filter cab1.cab -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'v14\.[^\\]+\\packages\\vcRuntimeMinimum_amd64\\cab1\.cab$' } |
        Sort-Object { [version]([regex]::Match($_.FullName, 'v(14\.[0-9.]+)\\packages').Groups[1].Value) } -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (!$RuntimeCab -or !(Test-Path -LiteralPath $RuntimeCab -PathType Leaf)) {
    throw 'Supply -RuntimeCab with the x64 vcRuntimeMinimum cab from Microsoft Visual C++ Redistributable.'
}

$version = [regex]::Match((Get-Content -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') -Raw), '(?m)^version:\s*(\S+)').Groups[1].Value
if (!$version) { throw 'Application version is missing' }
$packageName = 'Plana-Windows-' + $version.Split('+')[0] + '-x64'
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$bundle = Join-Path $OutputDirectory $packageName
$zipPath = Join-Path $OutputDirectory ($packageName + '.zip')
$setupPath = Join-Path $OutputDirectory ($packageName + '-setup.exe')
$checksumPath = Join-Path $OutputDirectory ($packageName + '-SHA256.txt')
foreach ($target in @($bundle, $zipPath, $setupPath, $checksumPath)) {
    if (Test-Path -LiteralPath $target) { throw "Output already exists; choose a new output directory: $target" }
}

& "$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'start_windows.ps1') -BuildOnly -Offline
if ($LASTEXITCODE -ne 0) { throw 'Release build validation failed' }
$release = Join-Path $projectRoot 'build/windows/x64/runner/Release'
if ((Get-Item -LiteralPath (Join-Path $release 'plana_app_for_windows.exe')).VersionInfo.FileVersion -ne $version) {
    throw 'Release executable version does not match source'
}
New-Item -ItemType Directory -Path $bundle -Force | Out-Null
. (Join-Path $PSScriptRoot 'windows_runtime_files.ps1')
Get-PlanaRuntimeFiles $release | ForEach-Object {
    $relative = $_.FullName.Substring($release.Length + 1)
    $destination = Join-Path $bundle $relative
    New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $destination
}

$work = Join-Path $workspaceRoot ('.packaging-work-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
function Invoke-Archive([string[]]$ArchiveArguments) {
    & $sevenZip @ArchiveArguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "7-Zip failed with code $LASTEXITCODE" }
}

try {
    $runtimeWork = Join-Path $work 'runtime'
    Invoke-Archive -ArchiveArguments @('x', $RuntimeCab, ('-o' + $runtimeWork), '-y', '-bso0', '-bsp0')
    $runtimeNames = @('concrt140', 'msvcp140', 'msvcp140_1', 'msvcp140_2', 'msvcp140_atomic_wait', 'msvcp140_codecvt_ids', 'vccorlib140', 'vcruntime140', 'vcruntime140_1', 'vcruntime140_threads')
    foreach ($name in $runtimeNames) {
        $inputDll = Join-Path $runtimeWork ($name + '.dll_amd64')
        $signature = Get-AuthenticodeSignature -LiteralPath $inputDll
        if (!$signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
            throw "Unexpected runtime DLL signer: $name"
        }
        Copy-Item -LiteralPath $inputDll -Destination (Join-Path $bundle ($name + '.dll'))
    }
    $runtimeVersion = (Get-Item -LiteralPath (Join-Path $bundle 'vcruntime140.dll')).VersionInfo.FileVersion

    $licenses = Join-Path $bundle 'licenses'
    New-Item -ItemType Directory -Path $licenses | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot 'LICENSE') -Destination (Join-Path $bundle 'LICENSE.txt')
    Copy-Item -LiteralPath (Join-Path $projectRoot 'THIRD_PARTY_NOTICES.md') -Destination $bundle
    Get-ChildItem -LiteralPath (Join-Path $projectRoot 'docs/runtime-licenses') -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $licenses
    }
    Copy-Item -LiteralPath (Join-Path $SevenZipDirectory 'License.txt') -Destination (Join-Path $licenses '7-Zip-LICENSE.txt')
    Copy-Item -LiteralPath (Join-Path $projectRoot 'installer/languages/INNO-SETUP-LICENSE.txt') -Destination $licenses
    @"
Windows runtime components

Microsoft Visual C++ Runtime $runtimeVersion (x64).
Copyright (c) Microsoft Corporation. All rights reserved.
Unmodified DLLs extracted from the Microsoft Visual C++ Redistributable package.
Redistribution information: https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files

ONNX Runtime 1.22.0 for Windows x64: see ONNXRuntime-LICENSE.txt and ONNXRuntime-ThirdPartyNotices.txt.
Flutter and Dart dependency notices: ../data/flutter_assets/NOTICES.Z and the application's license page.

The Chinese installer is built with Inno Setup: https://jrsoftware.org/isinfo.php
See INNO-SETUP-LICENSE.txt. Its Simplified Chinese translation and provenance
are included in source-code.zip under installer/languages.
Archives are built with 7-Zip: https://www.7-zip.org/ (7-Zip-LICENSE.txt).
The installer and portable ZIP contain the same application files.

Plana source for this version is included as ../source-code.zip.
"@ | Set-Content -LiteralPath (Join-Path $licenses 'WINDOWS-RUNTIME-NOTICES.txt') -Encoding UTF8

    @"
Plana Windows 测试版 $version
适用：Windows 10 / Windows 11，64 位（x64）。

使用方法
1. 推荐安装版：双击 -setup.exe，按中文向导选择安装位置，可勾选创建桌面快捷方式。
   默认安装到当前用户的应用目录，无需管理员权限；也可选择 D 盘等可写入的专用文件夹。
2. 便携 ZIP：解压整个压缩包，打开 $packageName 文件夹，双击 plana_app_for_windows.exe。
3. 首次使用，在「我的 → 账号与接入」配置自己的绘图服务；AI 助手按页面提示配置。

程序所需 DLL、资源和 Visual C++ 运行库已随包提供，无需安装 Flutter 或 Visual Studio。
请保留整个程序文件夹，发送给朋友时发送 ZIP 或 -setup.exe 安装包。
安装版可从开始菜单或所选的桌面快捷方式启动。

升级与卸载
升级前先正常关闭 Plana，再运行新版安装包；安装向导会沿用上次安装位置。
请使用同一位置升级，程序更新不会清空 output、图库、历史和账号设置。
卸载可在 Windows「设置 → 应用」中进行；卸载只移除安装的程序文件，保留个人数据与作品。
便携版改用安装版时，也请先关闭旧版，并在首次打开新版后确认旧作品迁移完成再清理旧目录。

数据位置
设置、历史和图库由程序保存到当前 Windows 用户的应用数据目录。
自动保存的作品位于程序根目录的 output 文件夹（与 plana_app_for_windows.exe 同级）。
请安装或解压到自己可以写入的位置，例如 D 盘的应用文件夹；移动便携版时连同 output 一起移动。
旧版「作品」和文档目录中的受管作品会迁入新位置；迁移失败时保留原文件，应用内历史仍可使用。
关闭旧版后再打开新版。同一个 Windows 用户下，新旧版本会使用同一份应用数据。

分发包不附带个人 API、Bot/Web 授权、提示词草稿或个人 tag 库。
已使用过本程序的 Windows 用户重装后，仍会读取自己的本地存档；这些存档不会随安装包分享给别人。

反馈问题时，请提供版本 $version、操作步骤和出错截图。
这是测试版，程序和安装包尚未进行代码签名。

开源文件
LICENSE.txt 和 THIRD_PARTY_NOTICES.md 为许可与第三方声明。
source-code.zip 包含本版本 Windows 构建源码，测试使用时无需解压。
"@ | Set-Content -LiteralPath (Join-Path $bundle '使用说明.txt') -Encoding UTF8

    # Include matching source without local build caches, logs, personal data or SDK paths.
    $sourceStage = Join-Path $work 'source/plana-app-windows'
    New-Item -ItemType Directory -Path $sourceStage -Force | Out-Null
    foreach ($directory in @('lib', 'assets', 'examples', 'icons', 'installer', 'test', 'tool', 'tools', 'windows')) {
        $sourceDirectory = Join-Path $projectRoot $directory
        Get-ChildItem -LiteralPath $sourceDirectory -File -Recurse -Force |
            Where-Object { $_.FullName -notmatch '[\\/](ephemeral|__pycache__)[\\/]' -and $_.Extension -notin @('.log', '.pyc') } |
            ForEach-Object {
                $relative = $_.FullName.Substring($projectRoot.Length + 1)
                $destination = Join-Path $sourceStage $relative
                New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
                Copy-Item -LiteralPath $_.FullName -Destination $destination
            }
    }
    foreach ($file in @('pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml', '.gitignore', '.metadata', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'README.md', 'WINDOWS-README.md')) {
        Copy-Item -LiteralPath (Join-Path $projectRoot $file) -Destination $sourceStage
    }
    $sourceLicenses = Join-Path $sourceStage 'docs/runtime-licenses'
    New-Item -ItemType Directory -Path $sourceLicenses -Force | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $projectRoot 'docs/runtime-licenses') -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $sourceLicenses }
    @"
Windows source for Plana $version
Install Flutter and Visual Studio with Desktop development with C++.
From plana-app-windows, run: flutter pub get
Then run: flutter build windows --release
The verified build used Flutter 3.44.9 / Dart 3.12.2.
To package the Chinese installer and portable ZIP, install Inno Setup 6.5+
and 7-Zip, then run tool/package_windows.ps1 (see WINDOWS-README.md).
Project license: GPL-3.0. See LICENSE and THIRD_PARTY_NOTICES.md.
"@ | Set-Content -LiteralPath (Join-Path $sourceStage 'SOURCE-BUILD.txt') -Encoding UTF8
    Push-Location -LiteralPath (Join-Path $work 'source')
    try { Invoke-Archive -ArchiveArguments @('a', '-tzip', (Join-Path $bundle 'source-code.zip'), 'plana-app-windows', '-mx=7', '-bso0', '-bsp0') } finally { Pop-Location }

    $fileManifest = @(Get-ChildItem -LiteralPath $bundle -File -Recurse | Sort-Object FullName | ForEach-Object {
        [ordered]@{Path=$_.FullName.Substring($bundle.Length + 1).Replace('\', '/'); Bytes=$_.Length; SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
    })
    [ordered]@{Version=$version;Architecture='x64';RuntimeVersion=$runtimeVersion;Files=$fileManifest} | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $bundle 'package-manifest.json') -Encoding UTF8
    Push-Location -LiteralPath $OutputDirectory
    try {
        Invoke-Archive -ArchiveArguments @('a', '-tzip', $zipPath, $packageName, '-mx=7', '-bso0', '-bsp0')
        Invoke-Archive -ArchiveArguments @('t', $zipPath, '-bso0', '-bsp0')
    } finally { Pop-Location }
    & (Join-Path $PSScriptRoot 'build_windows_installer.ps1') -BundleDirectory $bundle -OutputDirectory $OutputDirectory -IsccPath $IsccPath | Out-Host
    $artifacts = @($zipPath, $setupPath) | ForEach-Object { Get-Item -LiteralPath $_ }
    $artifacts | ForEach-Object { '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash, $_.Name } |
        Set-Content -LiteralPath $checksumPath -Encoding ASCII
    $artifacts | ForEach-Object { [pscustomobject]@{Path=$_.FullName;Bytes=$_.Length;SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash} } | ConvertTo-Json
} finally {
    $resolvedWork = (Resolve-Path -LiteralPath $work).Path
    if (!$resolvedWork.StartsWith($workspaceRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolvedWork -Leaf) -notlike '.packaging-work-*') {
        throw 'Refusing to remove a packaging directory outside the workspace'
    }
    if (@(Get-ChildItem -LiteralPath $resolvedWork -Recurse -Force -Attributes ReparsePoint).Count) {
        throw 'Refusing to remove packaging work containing reparse points'
    }
    Remove-Item -LiteralPath $resolvedWork -Recurse -Force
}
