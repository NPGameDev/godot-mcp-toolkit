# Build the AssetLib-distributable plugin zip from addons/godot_mcp_toolkit/.
# Output: dist-plugin\godot-mcp-toolkit-<version>.zip (zip's top entry is
# `addons/godot_mcp_toolkit/`, matching what both AssetLib and a manual
# extract-into-addons install expect).

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
# archive. Regression guard for concern 051: a future re-introduction of any
# `.uid` strip would empty the staged tree and must break the build loudly.
$StagedUid = @(Get-ChildItem -Path (Join-Path $Stage "addons\godot_mcp_toolkit") -Recurse -Filter *.uid)
if ($StagedUid.Count -eq 0) {
    Write-Error "concern 051: .uid sidecars must ship — none found in staged tree ($Stage). Do not strip *.uid from the addon."
    exit 1
}

if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath }
Compress-Archive -Path (Join-Path $Stage "addons") -DestinationPath $ZipPath

Remove-Item -Recurse -Force $Stage

Write-Host "Built dist-plugin\$ZipName"
