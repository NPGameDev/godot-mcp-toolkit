# Build the AssetLib-distributable plugin zip from addons/godot_mcp_toolkit/.
# Output: dist-plugin\godot-mcp-toolkit-<version>.zip (zip's top entry is
# `addons/godot_mcp_toolkit/`, matching what both AssetLib and a manual
# extract-into-addons install expect), holding the release file list
# (release_files.sha256), and dist-plugin\godot-mcp-toolkit-<version>.update.json,
# the update manifest the toolkit's self-update reads. Both match what
# build-plugin-release.sh writes (scripts/lib/release_files.sh). The manifest is
# unsigned: the maintainer signs it with scripts/sign-release.sh.

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

# Ship .uid sidecars (Godot 4.4+): they are project state that must travel WITH
# the addon, or `uid://` references to addon files break on update. We must NOT
# strip them — keep the staged tree identical to the git tree and the AssetLib
# archive. Regression guard: a future re-introduction of any
# `.uid` strip would empty the staged tree and must break the build loudly.
$StagedUid = @(Get-ChildItem -Path (Join-Path $Stage "addons\godot_mcp_toolkit") -Recurse -Filter *.uid)
if ($StagedUid.Count -eq 0) {
    Write-Error ".uid sidecars must ship — none found in staged tree ($Stage). Do not strip *.uid from the addon."
    exit 1
}

$VersionUtils = Join-Path $RepoRoot "addons\godot_mcp_toolkit\versioning\mcp_version_utils.gd"
$MinGodotLine = Select-String -Path $VersionUtils -Pattern '^const GODOT_MIN_VERSION := "([^"]+)"' | Select-Object -First 1
if (-not $MinGodotLine) {
    Write-Error "error: could not read GODOT_MIN_VERSION from $VersionUtils."
    exit 1
}
$MinGodot = $MinGodotLine.Matches[0].Groups[1].Value
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

# The list of the release's files: one "<sha256>  <path>" line per file, paths
# relative to the addon folder with forward slashes, in byte order, the list left
# out. The self-update deletes only files an installed release listed.
$AddonStage = (Resolve-Path (Join-Path $Stage "addons\godot_mcp_toolkit")).Path
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
# hidden files (every dotfile on macOS and Linux), and Windows PowerShell 5.1's
# writes backslash separators, which the toolkit's self-update refuses.
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
$Manifest = '{"format": 1, "version": "' + $Version + '", "archive": "' + $ZipName + '", "archive_size": ' + $Size + ', "archive_sha256": "' + $ZipHash + '", "min_godot": "' + $MinGodot + '"}' + "`n"
[System.IO.File]::WriteAllText((Join-Path $OutDir $ManifestName), $Manifest, $Utf8NoBom)

Write-Host "Built dist-plugin\$ZipName"
Write-Host "Built dist-plugin\$ManifestName (unsigned; sign it with scripts/sign-release.sh)"
