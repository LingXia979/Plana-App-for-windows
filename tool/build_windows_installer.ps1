param(
    [Parameter(Mandatory = $true)][string]$BundleDirectory,
    [string]$OutputDirectory,
    [string]$IsccPath,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$bundle = (Resolve-Path -LiteralPath $BundleDirectory).Path.TrimEnd('\')
if (!(Test-Path -LiteralPath $bundle -PathType Container)) { throw 'Bundle must be a directory.' }
if (((Get-Item -LiteralPath $bundle).Attributes -band [IO.FileAttributes]::ReparsePoint) -or
    @(Get-ChildItem -LiteralPath $bundle -Force -Recurse -Attributes ReparsePoint).Count) {
    throw 'Installer input must not contain reparse points.'
}

# Compile only files accepted by the runtime allowlist and verified against the
# packager's manifest. Never feed a recursive wildcard from a live app to ISCC.
. (Join-Path $PSScriptRoot 'windows_runtime_files.ps1')
$allowed = @{}
foreach ($file in @(Get-PlanaRuntimeFiles $bundle)) {
    $allowed[$file.FullName.Substring($bundle.Length + 1).Replace('\', '/')] = $true
}
foreach ($name in @('LICENSE.txt', 'THIRD_PARTY_NOTICES.md', 'source-code.zip', '使用说明.txt',
    'licenses/7-Zip-LICENSE.txt', 'licenses/INNO-SETUP-LICENSE.txt',
    'licenses/ONNXRuntime-LICENSE.txt', 'licenses/ONNXRuntime-ThirdPartyNotices.txt',
    'licenses/WINDOWS-RUNTIME-NOTICES.txt')) {
    $allowed[$name] = $true
}
$manifestPath = Join-Path $bundle 'package-manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$versionMatch = [regex]::Match($manifest.Version, '^(\d+)\.(\d+)\.(\d+)-windows\.(\d+)\+(\d+)$')
if (!$versionMatch.Success -or $manifest.Architecture -ne 'x64') { throw 'Invalid Windows package version or architecture.' }
$fileVersion = '{0}.{1}.{2}.{3}' -f $versionMatch.Groups[1].Value, $versionMatch.Groups[2].Value, $versionMatch.Groups[3].Value, $versionMatch.Groups[5].Value
$packageName = 'Plana-Windows-' + $manifest.Version.Split('+')[0] + '-x64'
$files = @{}
foreach ($entry in $manifest.Files) {
    $relative = [string]$entry.Path
    if (!$relative -or $relative -match '[\\:"{}\r\n]' -or $relative.StartsWith('/') -or
        @($relative.Split('/') | Where-Object { !$_ -or $_ -in @('.', '..') -or $_ -match '[. ]$' }).Count -or
        $files.ContainsKey($relative) -or !$allowed.ContainsKey($relative)) {
        throw "Unapproved or duplicate installer path: $relative"
    }
    $path = [IO.Path]::GetFullPath((Join-Path $bundle $relative))
    if (!$path.StartsWith($bundle + '\', [StringComparison]::OrdinalIgnoreCase) -or
        !(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing package file: $relative" }
    $file = Get-Item -LiteralPath $path
    if ($file.Length -ne $entry.Bytes -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.SHA256) {
        throw "Package integrity check failed: $relative"
    }
    $files[$relative] = $file
}
foreach ($required in @('plana_app_for_windows.exe', 'data/app.so', 'data/icudtl.dat',
    'flutter_windows.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll',
    'flutter_secure_storage_windows_plugin.dll', 'flutter_onnxruntime_plugin.dll',
    'onnxruntime.dll', 'dartjni.dll', 'gal_plugin.dll', 'share_plus_plugin.dll',
    'url_launcher_windows_plugin.dll', 'data/flutter_assets/AssetManifest.bin',
    'LICENSE.txt', 'THIRD_PARTY_NOTICES.md', 'source-code.zip', '使用说明.txt', 'licenses/INNO-SETUP-LICENSE.txt')) {
    if (!$files.ContainsKey($required)) { throw "Missing required installer file: $required" }
}
foreach ($file in @(Get-ChildItem -LiteralPath $bundle -File -Recurse -Force)) {
    $relative = $file.FullName.Substring($bundle.Length + 1).Replace('\', '/')
    if ($relative -ne 'package-manifest.json' -and !$files.ContainsKey($relative)) {
        throw "Unlisted file in installer input: $relative"
    }
}
if ($files['plana_app_for_windows.exe'].VersionInfo.FileVersion -ne $manifest.Version) {
    throw 'Executable version does not match package manifest.'
}
$files['package-manifest.json'] = Get-Item -LiteralPath $manifestPath
if ($ValidateOnly) {
    [pscustomobject]@{Version=$manifest.Version; VerifiedFiles=$files.Count; AllowlistPassed=$true}
    return
}

if (!$IsccPath) {
    $compilerCommand = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    $candidates = @(
        $env:ISCC
        if ($compilerCommand) { $compilerCommand.Source }
        (Join-Path $env:LOCALAPPDATA 'Programs/Inno Setup 6/ISCC.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe')
        (Join-Path $env:ProgramFiles 'Inno Setup 6/ISCC.exe')
    )
    $IsccPath = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
}
if (!$IsccPath -or !(Test-Path -LiteralPath $IsccPath -PathType Leaf)) {
    throw 'Inno Setup 6.5 or later is required. Supply -IsccPath or set ISCC to ISCC.exe.'
}
if (!$OutputDirectory) { $OutputDirectory = Split-Path $bundle -Parent }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$outputBaseName = $packageName + '-setup'
$installer = Join-Path $OutputDirectory ($outputBaseName + '.exe')
if (Test-Path -LiteralPath $installer) { throw "Installer already exists: $installer" }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$work = Join-Path $projectRoot ('.installer-work-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $includePath = Join-Path $work 'package-files.iss'
    $lines = foreach ($relative in ($files.Keys | Sort-Object)) {
        $parent = [IO.Path]::GetDirectoryName($relative.Replace('/', '\'))
        $destination = '{app}'
        if ($parent) { $destination += '\' + $parent }
        'Source: "{0}"; DestDir: "{1}"; Flags: ignoreversion' -f $files[$relative].FullName, $destination
    }
    $lines | Set-Content -LiteralPath $includePath -Encoding UTF8
    & $IsccPath '/Qp' (('/DAppVersion=' + $manifest.Version)) (('/DFileVersion=' + $fileVersion)) `
        (('/DOutputDir=' + $OutputDirectory)) (('/DOutputBaseFilename=' + $outputBaseName)) `
        (('/DFilesInclude=' + $includePath)) (('/DIconFile=' + (Join-Path $projectRoot 'windows/runner/resources/app_icon.ico'))) `
        (Join-Path $projectRoot 'installer/Plana.iss') | Out-Host
    if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $installer -PathType Leaf)) {
        throw "Inno Setup compilation failed: $LASTEXITCODE"
    }
    [pscustomobject]@{Path=$installer;Bytes=(Get-Item -LiteralPath $installer).Length;SHA256=(Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash;VerifiedFiles=$files.Count}
} finally {
    $resolvedWork = (Resolve-Path -LiteralPath $work).Path
    if (!$resolvedWork.StartsWith($projectRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $resolvedWork -Leaf) -notlike '.installer-work-*' -or
        ((Get-Item -LiteralPath $resolvedWork).Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        @(Get-ChildItem -LiteralPath $resolvedWork -Recurse -Force -Attributes ReparsePoint).Count) {
        throw 'Refusing to remove an unexpected installer work directory.'
    }
    Remove-Item -LiteralPath $resolvedWork -Recurse -Force
}
