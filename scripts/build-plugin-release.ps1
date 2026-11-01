# Build the AssetLib-distributable plugin zip from addons/godot_mcp_toolkit/.
# Output: dist-plugin\godot-mcp-toolkit-<version>.zip (zip's top entry is
# `addons/godot_mcp_toolkit/`, matching what both AssetLib and a manual
# extract-into-addons install expect), holding the release file list
# (release_files.sha256), and dist-plugin\godot-mcp-toolkit-<version>.update.json,
# the update manifest that pins the zip by size and hash. The list matches what
# build-plugin-release.sh writes (scripts/lib/release_files.sh) byte for byte. The
# manifest has the same keys but is for local tests only: a .NET zip cannot match
# `zip -qr` byte for byte, so its size and hash differ, and only the bash build's
# manifest, the one the release workflow builds, is ever signed.
#
# Keep this file ASCII: Windows PowerShell 5.1 reads a script with no BOM in the
# system code page, where a UTF-8 dash can end a string early.

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

$PluginCfg = Join-Path $RepoRoot "addons\godot_mcp_toolkit\plugin.cfg"
if (-not (Test-Path $PluginCfg)) {
    Write-Error "error: $PluginCfg not found (run from toolkit-repo root)."
    exit 1
}

$VersionLine = Select-String -Path $PluginCfg -Pattern '^version="([^"]+)"' | Select-Object -First 1
if (-not $VersionLine) {
    Write-Error "error: could not read version from $PluginCfg."
    exit 1
}
$Version = $VersionLine.Matches[0].Groups[1].Value

$OutDir = Join-Path $RepoRoot "dist-plugin"
$Stage = Join-Path $OutDir "stage"
$ZipName = "godot-mcp-toolkit-$Version.zip"
$ZipPath = Join-Path $OutDir $ZipName

if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
New-Item -ItemType Directory -Force -Path (Join-Path $Stage "addons") | Out-Null
Copy-Item -Recurse -Force `
    (Join-Path $RepoRoot "addons\godot_mcp_toolkit") `
    (Join-Path $Stage "addons\godot_mcp_toolkit")
$AddonStage = (Resolve-Path (Join-Path $Stage "addons\godot_mcp_toolkit")).Path

# The engine skips a folder holding a .gdignore and everything under it, so it never
# gives those scripts a uid and they need no sidecar.
function Test-InGdignoredFolder($Folder) {
    $Current = $Folder
    while ($Current -and $Current.FullName.Length -ge $AddonStage.Length) {
        if (Test-Path -LiteralPath (Join-Path $Current.FullName ".gdignore")) { return $true }
        $Current = $Current.Parent
    }
    return $false
}

# .uid sidecars (Godot 4.4+) are project state that must travel WITH the addon. A
# script shipped without one gets a new random uid on each machine after each update,
# which breaks `uid://` references to it and leaves a file in the addon folder that no
# release listed.
$MissingUid = @(Get-ChildItem -LiteralPath $AddonStage -Recurse -File -Force | Where-Object {
    $_.Extension -ceq ".gd" -and
        -not (Test-Path -LiteralPath "$($_.FullName).uid") -and
        -not (Test-InGdignoredFolder $_.Directory)
} | ForEach-Object { $_.FullName.Substring($AddonStage.Length + 1).Replace('\', '/') })
if ($MissingUid.Count -gt 0) {
    Write-Error ("error: every scanned script must ship with its .uid sidecar. Open the project in Godot 4.4+ to mint it, and commit it. Missing for: " + ($MissingUid -join ", "))
    exit 1
}

$VersionUtils = Join-Path $RepoRoot "addons\godot_mcp_toolkit\versioning\mcp_version_utils.gd"
$MinGodotLine = Select-String -Path $VersionUtils -Pattern '^const GODOT_MIN_VERSION := "([^"]+)"' | Select-Object -First 1
if (-not $MinGodotLine) {
    Write-Error "error: could not read GODOT_MIN_VERSION from $VersionUtils."
    exit 1
}
$MinGodot = $MinGodotLine.Matches[0].Groups[1].Value

$CompatibleServerLine = Select-String -Path $VersionUtils -Pattern '^const COMPATIBLE_SERVER_VERSION := "([^"]*)"' | Select-Object -First 1
if (-not $CompatibleServerLine -or -not $CompatibleServerLine.Matches[0].Groups[1].Value) {
    Write-Error "error: could not read COMPATIBLE_SERVER_VERSION from $VersionUtils."
    exit 1
}
$CompatibleServer = $CompatibleServerLine.Matches[0].Groups[1].Value

# Commit time, never the clock, as in rf_expires_at: the same commit, the same expiry.
$CommitTime = $null
try { $CommitTime = & git -C $RepoRoot log -1 --format=%ct HEAD 2>$null } catch { }
if ("$CommitTime" -notmatch '^\d+$') {
    Write-Error "error: could not read HEAD's commit time, which sets the manifest's expires_at (is this a git checkout with a commit?)."
    exit 1
}
$ExpiresAt = [long]"$CommitTime" + 15552000

$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

# The list of the release's files, inside the zip: one "<sha256>  <path>" line per
# file, paths relative to the addon folder with forward slashes, in byte order, the
# list left out. It names every file a zip may hold but itself, and its hashes show a hand-edited
# file.
$ListName = "release_files.sha256"
# A typed string array, so Sort compares ordinally: the items of a pipeline's object
# array compare through PowerShell's case-insensitive rules instead.
$Paths = [string[]]@(Get-ChildItem -Path $AddonStage -Recurse -File -Force | ForEach-Object {
    $_.FullName.Substring($AddonStage.Length + 1).Replace('\', '/')
} | Where-Object { $_ -ne $ListName })
[System.Array]::Sort($Paths, [System.StringComparer]::Ordinal)
$Lines = foreach ($Path in $Paths) {
    $Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $AddonStage $Path)).Hash.ToLowerInvariant()
    "$Hash  $Path"
}
[System.IO.File]::WriteAllText((Join-Path $AddonStage $ListName), (($Lines -join "`n") + "`n"), $Utf8NoBom)

# Written entry by entry under forward-slash names: Compress-Archive leaves out
# hidden files (every dotfile on macOS and Linux), and on Windows PowerShell 5.1 it
# writes backslash separators, where a release's entry names must use forward slashes.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath }
$Zip = [System.IO.Compression.ZipFile]::Open($ZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($Path in ($Paths + $ListName)) {
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $Zip, (Join-Path $AddonStage $Path), "addons/godot_mcp_toolkit/$Path")
    }
} finally {
    $Zip.Dispose()
}

Remove-Item -Recurse -Force $Stage

$ManifestName = "godot-mcp-toolkit-$Version.update.json"
$Size = (Get-Item -LiteralPath $ZipPath).Length
$ZipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ZipPath).Hash.ToLowerInvariant()
$Manifest = '{"format": 1, "version": "' + $Version + '", "archive": "' + $ZipName + '", "archive_size": ' + $Size + ', "archive_sha256": "' + $ZipHash + '", "min_godot": "' + $MinGodot + '", "compatible_server": "' + $CompatibleServer + '", "expires_at": ' + $ExpiresAt + '}' + "`n"
[System.IO.File]::WriteAllText((Join-Path $OutDir $ManifestName), $Manifest, $Utf8NoBom)

Write-Host "Built dist-plugin\$ZipName"
Write-Host "Built dist-plugin\$ManifestName (local tests only; sign the manifest the release workflow builds)"
