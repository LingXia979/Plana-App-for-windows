param(
    [switch]$BuildOnly,
    [switch]$Rebuild,
    [switch]$Offline
)

$ErrorActionPreference = 'Stop'
# A batch file started from PowerShell 7 can inherit its module search path.
# Load the modules belonging to this process, including Windows PowerShell 5.1.
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1') -Force
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Management/Microsoft.PowerShell.Management.psd1') -Force
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'windows_runtime_files.ps1')
$workspaceRoot = [IO.Path]::GetDirectoryName($projectRoot)
$releaseRoot = Join-Path $projectRoot 'build/windows/x64/runner/Release'
$appPath = Join-Path $releaseRoot 'plana_app_for_windows.exe'
$stateRoot = Join-Path $projectRoot 'build/launcher'
$stampPath = Join-Path $stateRoot 'build.json'
$logRoot = Join-Path $workspaceRoot 'logs'
$runId = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), $PID
$sessionLog = Join-Path $logRoot "$runId-launcher.log"
$buildLog = Join-Path $logRoot "$runId-build.log"

function Write-LaunchLog([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format o), $Message
    Add-Content -LiteralPath $sessionLog -Value $line -Encoding UTF8
    Write-Host $Message
}

function Get-TextHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '')
    } finally { $sha.Dispose() }
}

function Get-InputsHash([switch]$DependenciesOnly) {
    $files = @(
        foreach ($name in @('pubspec.yaml', 'pubspec.lock', 'pubspec_overrides.yaml')) {
            $path = Join-Path $projectRoot $name
            if (Test-Path -LiteralPath $path -PathType Leaf) { Get-Item -LiteralPath $path }
        }
        if (!$DependenciesOnly) {
            foreach ($name in @('lib', 'assets', 'examples/inspiration-previews', 'windows/runner')) {
                $path = Join-Path $projectRoot $name
                if (Test-Path -LiteralPath $path) { Get-ChildItem -LiteralPath $path -File -Recurse }
            }
            foreach ($name in @('windows/CMakeLists.txt', 'windows/flutter/CMakeLists.txt')) {
                $path = Join-Path $projectRoot $name
                if (Test-Path -LiteralPath $path) { Get-Item -LiteralPath $path }
            }
        }
    )
    $lines = foreach ($file in ($files | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($projectRoot.Length).Replace('\', '/')
        '{0}={1}' -f $relative, (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return Get-TextHash ($lines -join [Environment]::NewLine)
}

function Find-Flutter {
    $candidates = @(
        if ($env:FLUTTER_ROOT) { Join-Path $env:FLUTTER_ROOT 'bin/flutter.bat' }
        $command = Get-Command flutter.bat -ErrorAction SilentlyContinue
        if ($command) { $command.Source }
        $config = Join-Path $projectRoot '.dart_tool/package_config.json'
        if (Test-Path -LiteralPath $config) {
            $packages = (Get-Content -LiteralPath $config -Raw | ConvertFrom-Json).packages
            $flutter = $packages | Where-Object name -eq 'flutter' | Select-Object -First 1
            if ($flutter) {
                $baseUri = [Uri]::new($config)
                $packageUri = [Uri]::new($baseUri, [string]$flutter.rootUri)
                if ($packageUri.IsFile) { Join-Path $packageUri.LocalPath '../../bin/flutter.bat' }
            }
        }
        $generated = Join-Path $projectRoot 'windows/flutter/ephemeral/generated_config.cmake'
        if (Test-Path -LiteralPath $generated) {
            $match = [regex]::Match((Get-Content -LiteralPath $generated -Raw), 'file\(TO_CMAKE_PATH "([^"]+)" FLUTTER_ROOT\)')
            if ($match.Success) { Join-Path ($match.Groups[1].Value.Replace('\\', '\')) 'bin/flutter.bat' }
        }
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw 'Flutter SDK not found. Add Flutter bin to PATH or set FLUTTER_ROOT, then run start.bat again.'
}

function Invoke-Flutter([string[]]$Arguments) {
    Write-LaunchLog ('flutter ' + ($Arguments -join ' '))
    $previous = $ErrorActionPreference
    try {
        # Windows PowerShell wraps native stderr in ErrorRecord objects even when
        # the tool succeeds. Use the actual process exit code as the result.
        $ErrorActionPreference = 'Continue'
        & $script:flutterPath @Arguments 2>&1 |
            Tee-Object -FilePath $buildLog -Append |
            ForEach-Object { Write-Host "$_" }
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
}

function Ensure-PluginLinks {
    $metadata = Join-Path $projectRoot '.flutter-plugins-dependencies'
    if (!(Test-Path -LiteralPath $metadata)) { return }
    $plugins = Get-Content -LiteralPath $metadata -Raw | ConvertFrom-Json
    $links = Join-Path $projectRoot 'windows/flutter/ephemeral/.plugin_symlinks'
    New-Item -ItemType Directory -Path $links -Force | Out-Null
    foreach ($plugin in $plugins.plugins.windows) {
        $link = Join-Path $links $plugin.name
        if (!(Test-Path -LiteralPath $link)) {
            New-Item -ItemType Junction -Path $link -Target $plugin.path | Out-Null
        }
    }
}

function Get-RunningApp {
    $expectedPath = [IO.Path]::GetFullPath($appPath)
    return Get-Process -Name plana_app_for_windows -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path -eq $expectedPath } |
        Select-Object -First 1
}

function Show-RunningApp($Process) {
    if (-not ('PlanaLauncherWindow' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PlanaLauncherWindow {
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
}
'@
    }
    $handle = $Process.MainWindowHandle
    if ($handle -ne [IntPtr]::Zero) {
        if ([PlanaLauncherWindow]::IsIconic($handle)) {
            [PlanaLauncherWindow]::ShowWindowAsync($handle, 9) | Out-Null
        }
        [PlanaLauncherWindow]::SetForegroundWindow($handle) | Out-Null
    }
    Write-LaunchLog "Plana is already running (PID $($Process.Id)). Close the app and run start.bat again to apply source updates."
}

function Test-CachedBuild($Stamp, [string]$SourceHash) {
    if (!$Stamp -or $Stamp.schema -ne 1 -or $Stamp.sourceHash -ne $SourceHash) { return $false }
    foreach ($relative in @($Stamp.runtimeFiles)) {
        if (!(Test-Path -LiteralPath (Join-Path $releaseRoot $relative) -PathType Leaf)) { return $false }
    }
    foreach ($item in @(@('plana_app_for_windows.exe', $Stamp.exeHash), @('data/app.so', $Stamp.appHash))) {
        $path = Join-Path $releaseRoot $item[0]
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $item[1]) { return $false }
    }
    return $true
}

function Start-Plana {
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    Write-LaunchLog "Workspace: $workspaceRoot"
    $mutexName = 'Local\PlanaStarter-' + (Get-TextHash $workspaceRoot.ToLowerInvariant()).Substring(0, 20)
    $mutex = [Threading.Mutex]::new($false, $mutexName)
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        $running = Get-RunningApp
        if (!$BuildOnly -and $running) {
            Show-RunningApp $running
            return 0
        }
        if (!$locked) {
            Write-LaunchLog 'Another start.bat is already building or running this workspace.'
            if ($BuildOnly) { return 1 }
            return 0
        }
        $stamp = $null
        if (Test-Path -LiteralPath $stampPath) {
            try { $stamp = Get-Content -LiteralPath $stampPath -Raw | ConvertFrom-Json } catch { $stamp = $null }
        }
        $sourceHash = Get-InputsHash
        if ($Rebuild -or !(Test-CachedBuild $stamp $sourceHash)) {
            if ($running) { throw 'Close this workspace app before building an updated version.' }
            $script:flutterPath = Find-Flutter
            Write-LaunchLog "Source update detected. Building with $script:flutterPath"
            $dependencyHash = Get-InputsHash -DependenciesOnly
            if (!$stamp -or $stamp.dependencyHash -ne $dependencyHash -or !(Test-Path -LiteralPath (Join-Path $projectRoot '.dart_tool/package_config.json'))) {
                $pubExit = Invoke-Flutter -Arguments @('pub', 'get', '--offline')
                Ensure-PluginLinks
                if ($pubExit -ne 0) { $pubExit = Invoke-Flutter -Arguments @('pub', 'get', '--offline') }
                if ($pubExit -ne 0 -and !$Offline) {
                    $pubExit = Invoke-Flutter -Arguments @('pub', 'get')
                    Ensure-PluginLinks
                }
                if ($pubExit -ne 0) { throw "Dependency resolution failed. See $buildLog" }
            }
            Ensure-PluginLinks
            $sourceHash = Get-InputsHash
            if ((Invoke-Flutter -Arguments @('build', 'windows', '--release', '--no-pub')) -ne 0) {
                throw "Build failed. See $buildLog"
            }
            foreach ($required in @('plana_app_for_windows.exe', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat')) {
                if (!(Test-Path -LiteralPath (Join-Path $releaseRoot $required) -PathType Leaf)) {
                    throw "Build output missing: $required"
                }
            }
            if ((Get-InputsHash) -ne $sourceHash) {
                throw 'Source files changed during the build. Run start.bat again to build those changes.'
            }
            $runtimeFiles = @(Get-PlanaRuntimeFiles $releaseRoot |
                ForEach-Object { $_.FullName.Substring($releaseRoot.Length + 1) })
            @{
                schema = 1
                sourceHash = $sourceHash
                dependencyHash = Get-InputsHash -DependenciesOnly
                exeHash = (Get-FileHash -LiteralPath $appPath -Algorithm SHA256).Hash
                appHash = (Get-FileHash -LiteralPath (Join-Path $releaseRoot 'data/app.so') -Algorithm SHA256).Hash
                runtimeFiles = $runtimeFiles
                builtAt = Get-Date -Format o
            } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $stampPath -Encoding UTF8
            Write-LaunchLog 'Build completed.'
        } else {
            Write-LaunchLog 'Source unchanged. Using the current build.'
        }
        if ($BuildOnly) { return 0 }
        $stdout = Join-Path $logRoot "$runId-stdout.log"
        $stderr = Join-Path $logRoot "$runId-stderr.log"
        $app = Start-Process -FilePath $appPath -WorkingDirectory $releaseRoot -PassThru -WindowStyle Normal -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        try {
            # Retain the native handle so ExitCode remains available after exit.
            $null = $app.Handle
            Write-LaunchLog "Started PID $($app.Id): $appPath"
            Write-LaunchLog "Runtime logs: $stdout ; $stderr"
            $app.WaitForExit()
            $code = $app.ExitCode
            Write-LaunchLog ('Process exited: code={0}, hex=0x{0:X8}' -f $code)
            if ($code -ne 0) {
                Write-LaunchLog 'The app returned an abnormal exit code. Keep these logs for diagnosis.'
                return 1
            }
            return 0
        } finally { $app.Dispose() }
    } catch {
        Write-LaunchLog "ERROR: $($_.Exception.Message)"
        return 1
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

Push-Location -LiteralPath $projectRoot
try { $result = Start-Plana } finally { Pop-Location }
exit $result
