$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows_runtime_files.ps1')
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$fixture = Join-Path $project ('build/runtime-file-test-' + [guid]::NewGuid().ToString('N'))
$expected = @('plana_app_for_windows.exe', 'flutter_windows.dll', 'native_assets.json', 'data/app.so', 'data/icudtl.dat', 'data/flutter_assets/assets/icon.png')
$private = @('output/2026-10-03/personal.png', 'output/2026-10-03/personal.json', '作品/2026-10-03/personal.png', '作品/2026-10-03/personal.json', 'settings.json', 'bot_session.json', 'flutter_secure_storage.dat', 'logs/last.log', 'source-backup.zip')
try {
    foreach ($name in ($expected + $private)) {
        $path = Join-Path $fixture $name
        New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
        Set-Content -LiteralPath $path -Value 'packaging fixture only'
    }
    $actual = @(Get-PlanaRuntimeFiles $fixture | ForEach-Object { $_.FullName.Substring($fixture.Length + 1).Replace('\', '/') })
    if (@(Compare-Object ($expected | Sort-Object) ($actual | Sort-Object)).Count -ne 0) {
        throw 'Runtime whitelist included private files or omitted runtime files'
    }
    Write-Output "PASS: $($expected.Count) runtime files included; $($private.Count) adjacent private files excluded."
} finally {
    $checked = [IO.Path]::GetFullPath($fixture)
    $boundary = [IO.Path]::GetFullPath((Join-Path $project 'build')) + [IO.Path]::DirectorySeparatorChar
    if (!$checked.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture path' }
    if (Test-Path -LiteralPath $checked) { Remove-Item -LiteralPath $checked -Recurse -Force }
}
