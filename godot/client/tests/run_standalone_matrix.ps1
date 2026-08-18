[CmdletBinding()]
param(
    [Parameter()]
    [string]$GodotExe = "godot"
)

$ErrorActionPreference = "Stop"
$projectDir = (Resolve-Path (Join-Path $PSScriptRoot ".." )).Path
$tests = @(
    "foundation_scene_test.gd",
    "jolt_capability_probe.gd",
    "jolt_bucket_query_spike.gd",
    "jolt_chassis_track_test.gd",
    "jolt_articulated_equipment_test.gd",
    "authority_shadow_test.gd",
    "sy205_glb_test.gd",
    "motion_client_test.gd",
    "model_switch_test.gd",
    "tracked_chassis_locomotion_test.gd",
    "bucket_ground_lift_test.gd",
    "construction_site_terrain_test.gd",
    "terrain3d_adapter_test.gd",
    "terrain_state_test.gd",
    "excavation_gameplay_test.gd",
    "visual_pass_test.gd",
    "release_candidate_test.gd"
)

function Invoke-Godot {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $process = Start-Process `
        -FilePath $GodotExe `
        -ArgumentList $Arguments `
        -NoNewWindow `
        -Wait `
        -PassThru
    return $process.ExitCode
}

$exitCode = Invoke-Godot -Arguments @("--headless", "--path", $projectDir, "--editor", "--quit")
if ($exitCode -ne 0) {
    throw "Godot import check failed"
}

foreach ($test in $tests) {
    $path = "res://tests/$test"
    Write-Host "[godot] $test"
    $exitCode = Invoke-Godot -Arguments @("--headless", "--path", $projectDir, "--script", $path)
    if ($exitCode -ne 0) {
        throw "Godot test failed: $test"
    }
}

Write-Host "Godot standalone matrix passed ($($tests.Count) scripts)."
