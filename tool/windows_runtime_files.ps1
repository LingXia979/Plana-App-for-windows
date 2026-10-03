function Get-PlanaRuntimeFiles([string]$ReleaseRoot) {
    $releasePath = [IO.Path]::GetFullPath($ReleaseRoot).TrimEnd('\', '/')
    foreach ($directory in @($releasePath, (Join-Path $releasePath 'data'))) {
        if (Test-Path -LiteralPath $directory) {
            $item = Get-Item -LiteralPath $directory -Force
            if (!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Runtime directory must be an ordinary folder: $directory"
            }
        }
    }
    function Read-RuntimeEntry([string]$entryPath) {
        $entry = Get-Item -LiteralPath $entryPath -Force
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Runtime entry must not be a link: $entryPath"
        }
        if ($entry.PSIsContainer) {
            foreach ($child in Get-ChildItem -LiteralPath $entry.FullName -Force) {
                Read-RuntimeEntry $child.FullName
            }
        } else {
            $entry
        }
    }
    # Generated runtime only. In particular, never bundle output or old 作品
    # folder, user settings, credentials, logs or files added beside the EXE.
    Read-RuntimeEntry (Join-Path $releasePath 'plana_app_for_windows.exe')
    foreach ($dll in Get-ChildItem -LiteralPath $releasePath -Filter '*.dll' -File) {
        Read-RuntimeEntry $dll.FullName
    }
    foreach ($relative in @('native_assets.json', 'data/app.so', 'data/icudtl.dat', 'data/flutter_assets')) {
        $entryPath = Join-Path $releasePath $relative
        if (Test-Path -LiteralPath $entryPath) { Read-RuntimeEntry $entryPath }
    }
}
