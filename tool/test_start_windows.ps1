# Run with Windows PowerShell 5.1, as used by start.bat. All app/build work is
# simulated in a fresh temporary workspace; the real app and user data are untouched.
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('plana-launcher-test-' + [Guid]::NewGuid().ToString('N'))
$fixture = Join-Path $testRoot '中文 & (with spaces)'
$project = Join-Path $fixture 'plana-app-windows'
$sdk = Join-Path $testRoot 'fake-sdk'
$trace = Join-Path $testRoot 'build-calls.txt'
$launches = Join-Path $testRoot 'app-starts.txt'
$launcher = Join-Path $project 'tool/start_windows.ps1'
$exe = Join-Path $project 'build/windows/x64/runner/Release/plana_app_for_windows.exe'
$psExe = Join-Path $PSHOME 'powershell.exe'
$previousFlutter = $env:FLUTTER_ROOT

function Assert-That([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}
function Invoke-Launcher([string[]]$Flags = @(), [int]$ExpectedExit = 0) {
    & $psExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $launcher @Flags | Out-Host
    Assert-That ($LASTEXITCODE -eq $ExpectedExit) "launcher exit code $ExpectedExit"
}
function Count-Builds {
    return @(Get-Content -LiteralPath $trace | Where-Object { $_ -eq 'build' }).Count
}
function Last-Session {
    $file = Get-ChildItem -LiteralPath (Join-Path $fixture 'logs') -Filter '*-launcher.log' |
        Sort-Object Name | Select-Object -Last 1
    return Get-Content -LiteralPath $file.FullName -Raw
}

try {
    foreach ($path in @("$project/tool", "$project/lib", "$sdk/bin")) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'start_windows.ps1') -Destination $launcher
    $realWorkspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    Copy-Item -LiteralPath (Join-Path $realWorkspace 'start.bat') -Destination (Join-Path $fixture 'start.bat')
    Set-Content -LiteralPath "$project/pubspec.yaml" -Value 'name: launcher_fixture'
    Set-Content -LiteralPath "$project/lib/main.dart" -Value 'fixture v1'
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Diagnostics;
using System.Threading;
public class LauncherFixture {
    [STAThread] public static int Main() {
        File.AppendAllText(Environment.GetEnvironmentVariable("PLANA_TEST_STARTS"), Process.GetCurrentProcess().Id + "\n");
        Console.WriteLine("fixture stdout");
        Console.Error.WriteLine("fixture stderr");
        int hold;
        if (Int32.TryParse(Environment.GetEnvironmentVariable("PLANA_TEST_HOLD"), out hold)) Thread.Sleep(hold);
        int code;
        return Int32.TryParse(Environment.GetEnvironmentVariable("PLANA_TEST_EXIT"), out code) ? code : 0;
    }
}
'@ -OutputAssembly (Join-Path $sdk 'fixture.exe') -OutputType WindowsApplication
    @'
@echo off
if "%1"=="pub" goto pub
if "%1"=="build" goto build
exit /b 9
:pub
echo pub>>"%PLANA_TEST_TRACE%"
if not exist ".dart_tool" mkdir ".dart_tool"
echo {"packages":[]} > ".dart_tool\package_config.json"
exit /b 0
:build
echo build>>"%PLANA_TEST_TRACE%"
if defined PLANA_TEST_BUILD_FAIL exit /b 8
if not exist "build\windows\x64\runner\Release\data" mkdir "build\windows\x64\runner\Release\data"
copy /y "%~dp0..\fixture.exe" "build\windows\x64\runner\Release\plana_app_for_windows.exe" >nul
echo runtime>"build\windows\x64\runner\Release\flutter_windows.dll"
echo snapshot>"build\windows\x64\runner\Release\data\app.so"
echo icu>"build\windows\x64\runner\Release\data\icudtl.dat"
exit /b 0
'@ | Set-Content -LiteralPath "$sdk/bin/flutter.bat" -Encoding ASCII
    $env:FLUTTER_ROOT = $sdk
    $env:PLANA_TEST_TRACE = $trace
    $env:PLANA_TEST_STARTS = $launches

    Invoke-Launcher -Flags @('-BuildOnly', '-Offline')
    Assert-That ((Count-Builds) -eq 1) 'first run builds in a path with Unicode, spaces and shell metacharacters'
    Invoke-Launcher -Flags @('-BuildOnly')
    Assert-That ((Count-Builds) -eq 1) 'unchanged source skips build'
    # Exercise the actual batch entry point from an unrelated working directory.
    Push-Location -LiteralPath $testRoot
    try {
        & $env:ComSpec /d /c ('call "{0}" -BuildOnly' -f (Join-Path $fixture 'start.bat')) | Out-Host
        Assert-That ($LASTEXITCODE -eq 0) 'start.bat resolves its own directory'
    } finally { Pop-Location }

    Set-Content -LiteralPath "$project/lib/main.dart" -Value 'fixture v2'
    Invoke-Launcher -Flags @('-BuildOnly')
    Assert-That ((Count-Builds) -eq 2) 'source edit rebuilds'
    Add-Content -LiteralPath "$project/pubspec.yaml" -Value '# dependency change'
    Invoke-Launcher -Flags @('-BuildOnly')
    Assert-That (@(Get-Content -LiteralPath $trace | Where-Object { $_ -eq 'pub' }).Count -eq 2) 'dependency edit resolves packages again'

    $stamp = Join-Path $project 'build/launcher/build.json'
    $stampHash = (Get-FileHash -LiteralPath $stamp).Hash
    Add-Content -LiteralPath "$project/lib/main.dart" -Value 'fixture v3'
    $env:PLANA_TEST_BUILD_FAIL = '1'
    Invoke-Launcher -Flags @('-BuildOnly') -ExpectedExit 1
    Assert-That ((Get-FileHash -LiteralPath $stamp).Hash -eq $stampHash) 'failed build does not mark stale output current'
    $env:PLANA_TEST_BUILD_FAIL = $null
    Invoke-Launcher -Flags @('-BuildOnly')
    $buildCount = Count-Builds
    Add-Content -LiteralPath $exe -Value 'changed executable'
    Invoke-Launcher -Flags @('-BuildOnly')
    Assert-That ((Count-Builds) -eq ($buildCount + 1)) 'modified executable is rebuilt'

    Invoke-Launcher
    Assert-That ((Last-Session) -match 'code=0, hex=0x00000000') 'normal process exit is recorded'
    $stderr = Get-ChildItem -LiteralPath (Join-Path $fixture 'logs') -Filter '*-stderr.log' |
        Sort-Object Name | Select-Object -Last 1
    Assert-That ((Get-Content -LiteralPath $stderr.FullName -Raw) -match 'fixture stderr') 'stderr is captured'
    $env:PLANA_TEST_EXIT = '7'
    Invoke-Launcher -ExpectedExit 1
    Assert-That ((Last-Session) -match 'code=7, hex=0x00000007') 'abnormal process exit is recorded'
    $env:PLANA_TEST_EXIT = $null

    $startCount = @(Get-Content -LiteralPath $launches).Count
    $env:PLANA_TEST_HOLD = '7000'
    $worker = Start-Process -FilePath $psExe -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $launcher)) -WindowStyle Hidden -PassThru
    try {
        $null = $worker.Handle
        $deadline = (Get-Date).AddSeconds(15)
        while (@(Get-Content -LiteralPath $launches).Count -eq $startCount -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 100
        }
        Assert-That (@(Get-Content -LiteralPath $launches).Count -eq ($startCount + 1)) 'background launch started'
        Invoke-Launcher
        Assert-That (@(Get-Content -LiteralPath $launches).Count -eq ($startCount + 1)) 'duplicate launch reuses running app'
        Assert-That ($worker.WaitForExit(20000)) 'launcher waits for application shutdown'
        Assert-That ($worker.ExitCode -eq 0) 'launcher exits cleanly after app closes'
    } finally { $worker.Dispose() }
    Write-Host "All launcher checks passed. Fixture: $fixture"
} finally {
    $env:FLUTTER_ROOT = $previousFlutter
    foreach ($key in @('PLANA_TEST_TRACE', 'PLANA_TEST_STARTS', 'PLANA_TEST_BUILD_FAIL', 'PLANA_TEST_EXIT', 'PLANA_TEST_HOLD')) {
        [Environment]::SetEnvironmentVariable($key, $null, 'Process')
    }
}
