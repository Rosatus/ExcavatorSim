param([string]$GodotExe = '', [string]$Output = '', [switch]$SkipImport)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$project = Join-Path $repo 'godot/worldbuilding/construction'
if (-not $GodotExe) {
    $chain = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'godot_voxel_toolchain.json') -Raw | ConvertFrom-Json
    $GodotExe = Join-Path $chain.default_root $chain.assets.windows_editor.filename
}
if (-not $Output) { $Output = Join-Path $repo 'godot/dist/maps/construction.pck' }
$Output = [IO.Path]::GetFullPath($Output)
New-Item -ItemType Directory -Path (Split-Path $Output) -Force | Out-Null
& (Join-Path $project 'tools/bootstrap.ps1')
$logRoot = Join-Path $repo 'artifacts/construction-map'
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
function Run-Godot([string[]]$Arguments, [string]$Name) {
    $process = Start-Process -FilePath $GodotExe -ArgumentList $Arguments -WindowStyle Hidden -PassThru -Wait `
        -RedirectStandardOutput (Join-Path $logRoot "$Name.log") -RedirectStandardError (Join-Path $logRoot "$Name.err.log")
    if ($process.ExitCode -ne 0) { throw "$Name failed ($($process.ExitCode)); see $logRoot" }
    $engineErrors = @(Get-Content -LiteralPath (Join-Path $logRoot "$Name.log"), (Join-Path $logRoot "$Name.err.log") | Where-Object { $_ -match '^(SCRIPT ERROR:|ERROR:)' })
    # The pinned editor reports these known shutdown allocations after a headless
    # scene import. Keep them visible; loading, parsing and pack errors remain fatal.
    $fatalErrors = @($engineErrors | Where-Object { $Name -notin @('map-import', 'map-texture-import') -or $_ -notmatch '^ERROR: (\d+ resources still in use at exit|\d+ RID allocations of type .* were leaked at exit)' })
    if ($fatalErrors.Count -gt 0) {
        throw "$Name reported engine errors; see $logRoot"
    }
    if ($engineErrors.Count -gt 0) { Write-Warning "Pinned editor reported shutdown allocations; retained in $logRoot/$Name*.log" }
}
$texturePolicy = Join-Path $PSScriptRoot 'prepare_construction_textures.py'
if (-not $SkipImport) {
    & python $texturePolicy
    if ($LASTEXITCODE -ne 0) { throw 'Texture preparation failed' }
    Run-Godot @('--headless', '--path', "`"$project`"", '--editor', '--import') 'map-import'
    # A fresh GLB import can create new image sidecars. Normalize those before
    # the final import so the first clean build has the same budget as rebuilds.
    $textureResult = & python $texturePolicy | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Extracted texture preparation failed' }
    if ($textureResult.changed -gt 0) {
        Run-Godot @('--headless', '--path', "`"$project`"", '--editor', '--import') 'map-texture-import'
    }
}
& python $texturePolicy --check
if ($LASTEXITCODE -ne 0) { throw 'Texture budget check failed' }
$tempPack = "$Output.pending"
Run-Godot @('--headless', '--path', "`"$project`"", '--script', 'res://tools/build_pack.gd', '--', "`"$tempPack`"") 'map-pack'
Move-Item -LiteralPath $tempPack -Destination $Output -Force
Get-Item -LiteralPath $Output | Select-Object FullName, Length
$packHash = (Get-FileHash -LiteralPath $Output -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Output "SHA256 $packHash"
