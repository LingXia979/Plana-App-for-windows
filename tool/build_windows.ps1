param([switch]$Offline, [switch]$SkipTests)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
Push-Location -LiteralPath $projectRoot
try {
  $pubArgs = @('pub', 'get')
  if ($Offline) { $pubArgs += '--offline' }
  & flutter @pubArgs
  $pubExit = $LASTEXITCODE
  # NTFS junctions let Flutter resolve local Windows plugins without changing
  # the user's system Developer Mode setting. Only create missing links here.
  $metadata = Join-Path $projectRoot '.flutter-plugins-dependencies'
  if (Test-Path -LiteralPath $metadata) {
    $plugins = Get-Content -LiteralPath $metadata -Raw | ConvertFrom-Json
    $linkRoot = Join-Path $projectRoot 'windows/flutter/ephemeral/.plugin_symlinks'
    New-Item -ItemType Directory -Path $linkRoot -Force | Out-Null
    foreach ($plugin in $plugins.plugins.windows) {
      $link = Join-Path $linkRoot $plugin.name
      if (!(Test-Path -LiteralPath $link)) {
        New-Item -ItemType Junction -Path $link -Target $plugin.path | Out-Null
      }
    }
    if ($pubExit -ne 0) {
      & flutter @pubArgs
      $pubExit = $LASTEXITCODE
    }
  }
  if ($pubExit -ne 0) { throw 'Flutter dependency resolution failed.' }
  & flutter analyze --no-pub
  if ($LASTEXITCODE -ne 0) { throw 'Static analysis failed.' }
  if (!$SkipTests) {
    & flutter test --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed.' }
  }
  & flutter build windows --release --no-pub
  if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }
  Write-Output 'Ready: build/windows/x64/runner/Release/plana_app_for_windows.exe'
}
finally { Pop-Location }
