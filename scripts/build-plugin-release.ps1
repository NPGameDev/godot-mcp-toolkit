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

# Drop .uid files — editor-managed per-project, shouldn't ship.
Get-ChildItem -Path (Join-Path $Stage "addons\godot_mcp_toolkit") -Recurse -Filter *.uid |
    Remove-Item -Force

if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath }
Compress-Archive -Path (Join-Path $Stage "addons") -DestinationPath $ZipPath

Remove-Item -Recurse -Force $Stage

Write-Host "Built dist-plugin\$ZipName"
