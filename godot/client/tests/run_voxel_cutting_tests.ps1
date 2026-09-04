[CmdletBinding()]
param(
    [string]$GodotExe = "",
    [string]$ToolchainRoot = "",
    [string]$OutputDir = "",
    [switch]$KeepIsolatedProject
)

$ErrorActionPreference = "Stop"
$sourceProject = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$repoRoot = (Resolve-Path (Join-Path $sourceProject "..\..")).Path
. (Join-Path $repoRoot "tools\godot_voxel_toolchain.ps1")
$toolchain = Get-GodotVoxelToolchain -GodotExe $GodotExe -ToolchainRoot $ToolchainRoot -Components @("windows_editor")
$GodotExe = [string]$toolchain.components.windows_editor.path
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot ("output\voxel_cutting\" + (Get-Date -Format "yyyyMMdd-HHmmss"))
}
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$isolateRoot = Join-Path $tempBase ("ExcavatorSim-voxel-cutting-" + [guid]::NewGuid().ToString("N"))
$isolatedProject = Join-Path $isolateRoot "client"
New-Item -ItemType Directory -Path $isolatedProject -Force | Out-Null

function Invoke-GodotTest {
    param([string]$Name, [string[]]$Arguments, [int]$TimeoutSeconds = 180)
    $stdout = Join-Path $OutputDir "$Name.stdout.log"
    $stderr = Join-Path $OutputDir "$Name.stderr.log"
    $process = Start-Process -FilePath $GodotExe -ArgumentList $Arguments -NoNewWindow `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill($true)
        throw "$Name timed out after $TimeoutSeconds seconds"
    }
    if ($process.ExitCode -ne 0) {
        throw "$Name failed with exit code $($process.ExitCode); see $stdout and $stderr"
    }
    return [ordered]@{ name = $Name; exit_code = $process.ExitCode; stdout = $stdout; stderr = $stderr }
}

try {
    Get-ChildItem -LiteralPath $sourceProject -Force |
        Where-Object { $_.Name -notin @(".godot", "output") } |
        Copy-Item -Destination $isolatedProject -Recurse -Force

    $results = @()
    $results += Invoke-GodotTest -Name "import" -Arguments @(
        "--headless", "--editor", "--quit", "--path", $isolatedProject
    )
    foreach ($testName in @(
        "voxel_work_zone_config_test.gd",
        "voxel_bucket_cutter_test.gd",
        "voxel_cut_queue_order_test.gd",
        "voxel_soil_material_field_test.gd",
        "voxel_excavation_authority_test.gd",
        "soil_effects_visual_mound_test.gd",
        "soil_authority_migration_test.gd",
        "voxel_excavation_world_test.gd"
    )) {
        $stem = [IO.Path]::GetFileNameWithoutExtension($testName)
        $results += Invoke-GodotTest -Name $stem -Arguments @(
            "--headless", "--path", $isolatedProject, "--script", "res://tests/$testName"
        )
    }
    $fatalMatches = @()
    foreach ($result in $results) {
        foreach ($path in @($result.stdout, $result.stderr)) {
            $text = [string](Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue)
            $fatalMatches += [regex]::Matches($text, '(?im)^.*(?:SCRIPT ERROR|Parse Error|FATAL|CRASH).*$') |
                ForEach-Object { $_.Value.Trim() }
        }
    }
    $summary = [ordered]@{
        schema_version = "voxel-soil-cycle-focused-run-v2"
        passed = ($fatalMatches.Count -eq 0)
        godot = $toolchain.components.windows_editor
        tests = $results
        fatal_log_matches = @($fatalMatches | Sort-Object -Unique)
    }
    $summaryPath = Join-Path $OutputDir "run-summary.json"
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
    if (-not $summary.passed) { throw "Voxel cutting focused tests contained fatal log matches; see $summaryPath" }
    Write-Host "Voxel cutting focused tests passed: $summaryPath"
}
finally {
    if (-not $KeepIsolatedProject) {
        $resolvedIsolate = [IO.Path]::GetFullPath($isolateRoot)
        if (-not $resolvedIsolate.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove isolate outside system temp: $resolvedIsolate"
        }
        if (Test-Path -LiteralPath $resolvedIsolate) {
            Remove-Item -LiteralPath $resolvedIsolate -Recurse -Force
        }
    }
}
