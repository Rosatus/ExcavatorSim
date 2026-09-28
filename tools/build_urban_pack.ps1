param([string]$GodotExe = '', [string]$Output = '', [switch]$SkipImport)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$project = Join-Path $repo 'godot/worldbuilding/urban'
if (-not $GodotExe) {
    $chain = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'godot_voxel_toolchain.json') -Raw | ConvertFrom-Json
    $GodotExe = Join-Path $chain.default_root $chain.assets.windows_editor.filename
}
if (-not $Output) { $Output = Join-Path $repo 'godot/dist/windows/maps/urban.pck' }
$Output = [IO.Path]::GetFullPath($Output)
New-Item -ItemType Directory -Path (Split-Path $Output) -Force | Out-Null
$logRoot = Join-Path $repo 'artifacts/urban-map'
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
function Run-Godot([string[]]$Arguments, [string]$Name) {
    $process = Start-Process -FilePath $GodotExe -ArgumentList $Arguments -WindowStyle Hidden -PassThru -Wait `
        -RedirectStandardOutput (Join-Path $logRoot "$Name.log") -RedirectStandardError (Join-Path $logRoot "$Name.err.log")
    if ($process.ExitCode -ne 0) { throw "$Name failed ($($process.ExitCode)); see $logRoot" }
    $engineErrors = @(Get-Content -LiteralPath (Join-Path $logRoot "$Name.log"), (Join-Path $logRoot "$Name.err.log") | Where-Object { $_ -match '^(SCRIPT ERROR:|ERROR:)' })
    # The pinned editor reports these known shutdown allocations after a headless
    # scene import. Keep them visible; loading, parsing and pack errors remain fatal.
    $fatalErrors = @($engineErrors | Where-Object { $Name -notin @('map-import') -or $_ -notmatch '^ERROR: (\d+ resources still in use at exit|\d+ RID allocations of type .* were leaked at exit)' })
    if ($fatalErrors.Count -gt 0) {
        throw "$Name reported engine errors; see $logRoot"
    }
    if ($engineErrors.Count -gt 0) { Write-Warning "Pinned editor reported shutdown allocations; retained in $logRoot/$Name*.log" }
}
if (-not $SkipImport) {
    Run-Godot @('--headless', '--path', "`"$project`"", '--editor', '--import') 'map-import'
}
$tempPack = "$Output.pending"
Run-Godot @('--headless', '--path', "`"$project`"", '--script', 'res://tests/_check_wind_shader.gd') 'wind-shader-check'
Run-Godot @('--headless', '--path', "`"$project`"", '--script', 'res://tools/build_pack.gd', '--', "`"$tempPack`"") 'map-pack'
Move-Item -LiteralPath $tempPack -Destination $Output -Force
# The editor and release staging resolve packs from godot/dist/maps; mirror the
# exe-adjacent copy there so both lookup roots stay valid.
$editorMirror = Join-Path $repo 'godot/dist/maps'
New-Item -ItemType Directory -Path $editorMirror -Force | Out-Null
Copy-Item -LiteralPath $Output -Destination (Join-Path $editorMirror 'urban.pck') -Force
Get-Item -LiteralPath $Output | Select-Object FullName, Length
$sha = [System.Security.Cryptography.SHA256]::Create()
$stream = [IO.File]::OpenRead($Output)
try {
    $packHash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
} finally {
    $stream.Close()
}
Write-Output "SHA256 $packHash"
