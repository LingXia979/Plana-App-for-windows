param([Parameter(Mandatory = $true)][string]$BundleDirectory)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$builder = Join-Path $PSScriptRoot 'build_windows_installer.ps1'
$source = (Resolve-Path -LiteralPath $BundleDirectory).Path
$baseline = & $builder -BundleDirectory $source -ValidateOnly
$fixture = Join-Path $projectRoot ('.installer-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$passed = New-Object 'Collections.Generic.List[string]'

function Expect-Rejection([string]$Name, [string]$ExpectedMessage) {
    try {
        & $builder -BundleDirectory $fixture -ValidateOnly | Out-Null
    } catch {
        if ($_.Exception.Message -notlike $ExpectedMessage) { throw }
        $passed.Add($Name)
        return
    }
    throw "Installer accepted invalid fixture: $Name"
}

try {
    Get-ChildItem -LiteralPath $source -Force | Copy-Item -Destination $fixture -Recurse
    $manifestPath = Join-Path $fixture 'package-manifest.json'
    $originalManifest = [IO.File]::ReadAllBytes($manifestPath)

    $privateFile = Join-Path $fixture 'prefs.json'
    '{}' | Set-Content -LiteralPath $privateFile -Encoding UTF8
    Expect-Rejection 'Unlisted personal settings rejected' '*Unlisted file*'
    Remove-Item -LiteralPath $privateFile

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifest.Files += [pscustomobject]@{Path='output/private.png';Bytes=0;SHA256=('0' * 64)}
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Expect-Rejection 'Personal artwork rejected even when listed' '*Unapproved or duplicate*'
    [IO.File]::WriteAllBytes($manifestPath, $originalManifest)

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifest.Files[0].Path = '../outside.txt'
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Expect-Rejection 'Parent traversal rejected' '*Unapproved or duplicate*'
    [IO.File]::WriteAllBytes($manifestPath, $originalManifest)

    $notice = Join-Path $fixture '使用说明.txt'
    'modified after staging' | Add-Content -LiteralPath $notice -Encoding UTF8
    Expect-Rejection 'Changed payload rejected' '*integrity check failed*'
    Copy-Item -LiteralPath (Join-Path $source '使用说明.txt') -Destination $notice -Force

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifest.Files = @($manifest.Files | Where-Object { $_.Path -ne 'flutter_windows.dll' })
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Remove-Item -LiteralPath (Join-Path $fixture 'flutter_windows.dll')
    Expect-Rejection 'Missing Flutter runtime rejected despite matching manifest' '*Missing required installer file: flutter_windows.dll*'

    [pscustomobject]@{Status='passed';ValidBundleFileCount=$baseline.VerifiedFiles;NegativeCases=@($passed)} | ConvertTo-Json -Depth 4
} finally {
    $resolved = (Resolve-Path -LiteralPath $fixture).Path
    if (!$resolved.StartsWith($projectRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $resolved -Leaf) -notlike '.installer-test-*' -or
        ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        @(Get-ChildItem -LiteralPath $resolved -Recurse -Force -Attributes ReparsePoint).Count) {
        throw 'Refusing to remove an unexpected test directory.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
