[CmdletBinding()]
param(
    [Parameter()]
    [string]$GodotExe = "godot"
)

$ErrorActionPreference = "Stop"
$projectDir = (Resolve-Path (Join-Path $PSScriptRoot ".." )).Path
$tests = @(
    "foundation_scene_test.gd",
    "sy205_glb_test.gd",
    "motion_client_test.gd",
    "terrain3d_adapter_test.gd",
    "terrain_state_test.gd",
    "excavation_gameplay_test.gd",
    "visual_pass_test.gd",
    "release_candidate_test.gd"
)

& $GodotExe --headless --path $projectDir --editor --quit
if ($LASTEXITCODE -ne 0) {
    throw "Godot import check failed"
}

foreach ($test in $tests) {
    $path = "res://tests/$test"
    Write-Host "[godot] $test"
    & $GodotExe --headless --path $projectDir --script $path
    if ($LASTEXITCODE -ne 0) {
        throw "Godot test failed: $test"
    }
}

Write-Host "Godot standalone matrix passed ($($tests.Count) scripts)."
