param()
$ErrorActionPreference = 'Stop'
$workbench = Split-Path $PSScriptRoot
$repo = (Resolve-Path (Join-Path $workbench '../../..')).Path
foreach ($addon in @('terrain_3d', 'sky_3d')) {
    $target = Join-Path $workbench "addons/$addon"
    if (-not (Test-Path -LiteralPath $target)) {
        New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $repo "godot/client/addons/$addon") -Destination $target -Recurse
    }
}
