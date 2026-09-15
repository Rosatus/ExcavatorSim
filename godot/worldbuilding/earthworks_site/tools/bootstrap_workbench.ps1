param([switch]$VerifyOnly, [switch]$SyncAssets)
$ErrorActionPreference = 'Stop'
$workbenchRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repositoryRoot = (Resolve-Path (Join-Path $workbenchRoot '../../..')).Path
$toolchain = Get-Content -LiteralPath (Join-Path $repositoryRoot 'tools/godot_voxel_toolchain.json') -Raw | ConvertFrom-Json
$enginePath = Join-Path $toolchain.default_root $toolchain.assets.windows_editor.filename
if (-not (Test-Path -LiteralPath $enginePath)) { throw "Missing custom Godot: $enginePath" }
if ((Get-FileHash -LiteralPath $enginePath -Algorithm SHA256).Hash -ne $toolchain.assets.windows_editor.binary_sha256) { throw 'Custom Godot SHA mismatch' }
foreach ($addon in @('terrain_3d', 'godot_ai')) {
    $sourceAddon = Join-Path $repositoryRoot "godot/client/addons/$addon"
    $target = Join-Path $workbenchRoot "addons/$addon"
    if (-not (Test-Path -LiteralPath (Join-Path $target 'plugin.cfg'))) {
        if ($VerifyOnly) { throw "Missing addon: $addon. Run bootstrap first." }
        New-Item -ItemType Directory -Path (Join-Path $workbenchRoot 'addons') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $repositoryRoot "godot/client/addons/$addon") -Destination $target -Recurse
    }
    $criticalFiles = Get-ChildItem -LiteralPath $sourceAddon -Recurse -File | Where-Object { $_.Extension -in @('.gd', '.cfg', '.gdextension', '.gdshader', '.gdshaderinc') -or $_.Name -eq 'libterrain.windows.debug.x86_64.dll' }
    foreach ($sourceFile in $criticalFiles) {
        $relativeName = [IO.Path]::GetRelativePath($sourceAddon, $sourceFile.FullName)
        $cachedFile = Join-Path $target $relativeName
        if (-not (Test-Path -LiteralPath $cachedFile) -or (Get-FileHash -LiteralPath $sourceFile.FullName).Hash -ne (Get-FileHash -LiteralPath $cachedFile).Hash) { throw "Addon cache differs from repository source: $addon/$relativeName. Restore that file from the pinned repository addon." }
    }
}
$catalog = Get-Content -LiteralPath (Join-Path $workbenchRoot 'asset_catalog/catalog.json') -Raw | ConvertFrom-Json
foreach ($asset in $catalog.assets) {
    $target = Join-Path $workbenchRoot $asset.cache
    if ($SyncAssets -and -not $VerifyOnly -and -not (Test-Path -LiteralPath $target)) {
        if (-not (Test-Path -LiteralPath $asset.source)) { Write-Warning "Missing $($asset.id); proxy retained"; continue }
        if ((Get-FileHash -LiteralPath $asset.source -Algorithm SHA256).Hash -ne $asset.sha256) { throw "Source SHA mismatch: $($asset.id)" }
        New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
        Copy-Item -LiteralPath $asset.source -Destination $target
        # Restore tracked import policy before the first editor scan.
        Copy-Item -LiteralPath (Join-Path $workbenchRoot "asset_catalog/imports/$($asset.id).glb.import") -Destination "$target.import"
    }
    if (Test-Path -LiteralPath $target) {
        if ((Get-Item -LiteralPath $target).Length -ne $asset.bytes -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $asset.sha256) { throw "Cache integrity failed: $($asset.id)" }
        if (-not (Test-Path -LiteralPath "$target.import")) {
            if ($VerifyOnly) { throw "Missing import metadata: $($asset.id)" }
            Copy-Item -LiteralPath (Join-Path $workbenchRoot "asset_catalog/imports/$($asset.id).glb.import") -Destination "$target.import"
        }
        $actualImport = Get-Content -LiteralPath "$target.import" -Raw
        $recordedImport = Get-Content -LiteralPath (Join-Path $workbenchRoot "asset_catalog/imports/$($asset.id).glb.import") -Raw
        $actualParams = ($actualImport -split '\[params\]', 2)[1].Replace("`r`n", "`n").Trim()
        $recordedParams = ($recordedImport -split '\[params\]', 2)[1].Replace("`r`n", "`n").Trim()
        if ($actualParams -ne $recordedParams) { throw "Import parameters differ from tracked policy: $($asset.id)" }
    }
}
Write-Output "Workbench dependencies verified. Engine: $enginePath"
