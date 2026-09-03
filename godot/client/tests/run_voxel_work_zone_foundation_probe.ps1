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
$toolchain = Get-GodotVoxelToolchain -GodotExe $GodotExe `
    -ToolchainRoot $ToolchainRoot -Components @("windows_editor", "windows_release_template")
$GodotExe = [string]$toolchain.components.windows_editor.path
$ReleaseTemplateExe = [string]$toolchain.components.windows_release_template.path
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot ("output\voxel_foundation\" + (Get-Date -Format "yyyyMMdd-HHmmss"))
}
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$isolateRoot = Join-Path $tempBase ("ExcavatorSim-voxel-foundation-" + [guid]::NewGuid().ToString("N"))
$isolatedProject = Join-Path $isolateRoot "client"
New-Item -ItemType Directory -Path $isolatedProject -Force | Out-Null

function Invoke-GodotProcess {
    param([string[]]$Arguments, [string]$StdoutPath, [string]$StderrPath, [int]$TimeoutSeconds = 180)
    $process = Start-Process -FilePath $GodotExe -ArgumentList $Arguments -NoNewWindow `
        -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath -PassThru
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill($true)
        throw "Godot voxel foundation probe timed out after $TimeoutSeconds seconds"
    }
    return $process.ExitCode
}

try {
    Get-ChildItem -LiteralPath $sourceProject -Force |
        Where-Object { $_.Name -notin @(".godot", "output") } |
        Copy-Item -Destination $isolatedProject -Recurse -Force

    $importOut = Join-Path $OutputDir "import.stdout.log"
    $importErr = Join-Path $OutputDir "import.stderr.log"
    $importLog = Join-Path $OutputDir "import.godot.log"
    $importExit = Invoke-GodotProcess -Arguments @(
        "--headless", "--editor", "--quit", "--path", $isolatedProject, "--log-file", $importLog
    ) -StdoutPath $importOut -StderrPath $importErr
    if ($importExit -ne 0) { throw "Godot isolated import failed with exit code $importExit" }

    $configOut = Join-Path $OutputDir "config.stdout.log"
    $configErr = Join-Path $OutputDir "config.stderr.log"
    $configExit = Invoke-GodotProcess -Arguments @(
        "--headless", "--path", $isolatedProject,
        "--script", "res://tests/voxel_work_zone_config_test.gd"
    ) -StdoutPath $configOut -StderrPath $configErr
    if ($configExit -ne 0) { throw "Voxel config/readiness test failed with exit code $configExit" }

    $seamOut = Join-Path $OutputDir "seam.stdout.log"
    $seamErr = Join-Path $OutputDir "seam.stderr.log"
    $seamExit = Invoke-GodotProcess -Arguments @(
        "--headless", "--path", $isolatedProject,
        "--script", "res://tests/voxel_work_zone_seam_test.gd"
    ) -StdoutPath $seamOut -StderrPath $seamErr
    if ($seamExit -ne 0) { throw "Voxel ownership seam test failed with exit code $seamExit" }

    $sceneOut = Join-Path $OutputDir "scene.stdout.log"
    $sceneErr = Join-Path $OutputDir "scene.stderr.log"
    $sceneExit = Invoke-GodotProcess -Arguments @(
        "--headless", "--path", $isolatedProject,
        "--script", "res://tests/voxel_work_zone_scene_test.gd"
    ) -StdoutPath $sceneOut -StderrPath $sceneErr -TimeoutSeconds 240
    if ($sceneExit -ne 0) { throw "Voxel work-zone scene/reset test failed with exit code $sceneExit" }

    $siteOut = Join-Path $OutputDir "site.stdout.log"
    $siteErr = Join-Path $OutputDir "site.stderr.log"
    $siteExit = Invoke-GodotProcess -Arguments @(
        "--headless", "--path", $isolatedProject,
        "--script", "res://tests/construction_site_terrain_test.gd"
    ) -StdoutPath $siteOut -StderrPath $siteErr
    if ($siteExit -ne 0) { throw "Construction-site ownership test failed with exit code $siteExit" }

    $probeOut = Join-Path $OutputDir "probe.stdout.log"
    $probeErr = Join-Path $OutputDir "probe.stderr.log"
    $probeLog = Join-Path $OutputDir "probe.godot.log"
    $probeExit = Invoke-GodotProcess -Arguments @(
        "--headless", "--path", $isolatedProject, "--log-file", $probeLog,
        "--script", "res://tests/voxel_work_zone_foundation_probe.gd",
        "--", "--output-dir", $OutputDir
    ) -StdoutPath $probeOut -StderrPath $probeErr -TimeoutSeconds 240

    $evidencePath = Join-Path $OutputDir "evidence.json"
    if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
        throw "Voxel foundation probe produced no evidence.json (exit $probeExit)"
    }
    $evidence = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json
    # The vendored Terrain3D demo contains optional OBJ/MTL references that
    # already warn during a clean import. They are not part of this probe. Only
    # runtime parser/crash/native-module failures can invalidate voxel evidence.
    $allText = @(
        Get-Content -LiteralPath $configOut -Raw -ErrorAction SilentlyContinue
        Get-Content -LiteralPath $configErr -Raw -ErrorAction SilentlyContinue
        Get-Content -LiteralPath $seamOut -Raw -ErrorAction SilentlyContinue
        Get-Content -LiteralPath $seamErr -Raw -ErrorAction SilentlyContinue
        Get-Content -LiteralPath $sceneOut -Raw -ErrorAction SilentlyContinue
        Get-Content -LiteralPath $sceneErr -Raw -ErrorAction SilentlyContinue
        Get-Content -LiteralPath $siteOut -Raw -ErrorAction SilentlyContinue
        Get-Content -LiteralPath $siteErr -Raw -ErrorAction SilentlyContinue
        Get-Content -LiteralPath $probeOut -Raw -ErrorAction SilentlyContinue
        Get-Content -LiteralPath $probeErr -Raw -ErrorAction SilentlyContinue
        Get-Content -LiteralPath $probeLog -Raw -ErrorAction SilentlyContinue
    ) -join "`n"
    $fatalPatterns = [regex]::Matches(
        $allText,
        '(?im)^.*(?:SCRIPT ERROR|FATAL|CRASH|ERROR:.*(?:GDExtension|VoxelTerrain|VoxelTool|VoxelViewer|Invalid call|Parse Error)).*$'
    ) |
        ForEach-Object { $_.Value.Trim() } | Sort-Object -Unique
    $summary = [ordered]@{
        schema_version = "voxel-work-zone-foundation-run-v1"
        passed = ($probeExit -eq 0 -and [bool]$evidence.passed -and $fatalPatterns.Count -eq 0)
        probe_exit_code = $probeExit
        evidence_path = $evidencePath
        selected_scale_m = $evidence.selected_scale_m
        release_template_verified_path = $ReleaseTemplateExe
        release_template_runtime = "deferred_requires_export_package"
        fatal_log_matches = @($fatalPatterns)
    }
    $summaryPath = Join-Path $OutputDir "run-summary.json"
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
    if (-not $summary.passed) { throw "Voxel work-zone foundation probe failed; see $summaryPath" }
    Write-Host "Voxel work-zone foundation probe passed: $summaryPath"
}
finally {
    if (-not $KeepIsolatedProject) {
        $resolvedIsolate = [IO.Path]::GetFullPath($isolateRoot)
        if (-not $resolvedIsolate.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove isolate outside the system temp directory: $resolvedIsolate"
        }
        if (Test-Path -LiteralPath $resolvedIsolate) {
            Remove-Item -LiteralPath $resolvedIsolate -Recurse -Force
        }
    }
}
