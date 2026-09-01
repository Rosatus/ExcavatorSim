[CmdletBinding()]
param(
    [Parameter()]
    [string]$GodotExe = "",

    [Parameter()]
    [string]$ToolchainRoot = "",

    [Parameter()]
    [string]$OutputDir = "",

    [Parameter()]
    [switch]$KeepIsolatedProject
)

$ErrorActionPreference = "Stop"
$sourceProject = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$repoRoot = (Resolve-Path (Join-Path $sourceProject "..\..")).Path
. (Join-Path $repoRoot "tools\godot_voxel_toolchain.ps1")
$toolchain = Get-GodotVoxelToolchain -GodotExe $GodotExe `
    -ToolchainRoot $ToolchainRoot -Components @("windows_editor")
$GodotExe = [string]$toolchain.components.windows_editor.path
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputDir = Join-Path $repoRoot "output\terrain3d_phase1\$stamp"
}
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$isolateRoot = Join-Path $tempBase ("ExcavatorSim-terrain3d-probe-" + [guid]::NewGuid().ToString("N"))
$isolatedProject = Join-Path $isolateRoot "client"
New-Item -ItemType Directory -Path $isolatedProject -Force | Out-Null

function Invoke-GodotProcess {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [Parameter(Mandatory)]
        [string]$StdoutPath,
        [Parameter(Mandatory)]
        [string]$StderrPath,
        [Parameter()]
        [int]$TimeoutSeconds = 180
    )
    $process = Start-Process -FilePath $GodotExe -ArgumentList $Arguments -NoNewWindow `
        -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath -PassThru
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill($true)
        throw "Godot probe timed out after $TimeoutSeconds seconds"
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
        "--headless", "--editor", "--quit", "--path", $isolatedProject,
        "--log-file", $importLog
    ) -StdoutPath $importOut -StderrPath $importErr
    if ($importExit -ne 0) {
        throw "Godot isolated import failed with exit code $importExit"
    }

    $probeOut = Join-Path $OutputDir "probe.stdout.log"
    $probeErr = Join-Path $OutputDir "probe.stderr.log"
    $probeLog = Join-Path $OutputDir "probe.godot.log"
    $probeExit = Invoke-GodotProcess -Arguments @(
        "--path", $isolatedProject,
        "--resolution", "960x540",
        "--rendering-method", "forward_plus",
        "--rendering-driver", "d3d12",
        "--log-file", $probeLog,
        "--script", "res://tests/terrain3d_forwardplus_probe.gd",
        "--", "--output-dir", $OutputDir
    ) -StdoutPath $probeOut -StderrPath $probeErr

    $evidencePath = Join-Path $OutputDir "evidence.json"
    if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
        throw "Terrain3D probe produced no evidence.json (exit $probeExit)"
    }
    $evidence = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json
    $currentRunText = @(
        Get-Content -LiteralPath $importOut -Raw -ErrorAction SilentlyContinue
        Get-Content -LiteralPath $importErr -Raw -ErrorAction SilentlyContinue
        Get-Content -LiteralPath $importLog -Raw -ErrorAction SilentlyContinue
        Get-Content -LiteralPath $probeOut -Raw -ErrorAction SilentlyContinue
        Get-Content -LiteralPath $probeErr -Raw -ErrorAction SilentlyContinue
        Get-Content -LiteralPath $probeLog -Raw -ErrorAction SilentlyContinue
    ) -join "`n"
    $fatalPatterns = [regex]::Matches(
        $currentRunText,
        '(?im)^.*(?:SCRIPT ERROR|FATAL|CRASH|ERROR:.*(?:shader|GDExtension|material|texture.?array|Terrain3D|map.?import)).*$'
    ) |
        ForEach-Object { $_.Value.Trim() } |
        Sort-Object -Unique
    $summary = [ordered]@{
        schema_version = "terrain3d-forwardplus-run-v2"
        passed = ($probeExit -eq 0 -and [bool]$evidence.passed -and $fatalPatterns.Count -eq 0)
        probe_exit_code = $probeExit
        evidence_path = $evidencePath
        isolated_project = $isolatedProject
        fatal_log_matches = @($fatalPatterns)
    }
    $summaryPath = Join-Path $OutputDir "run-summary.json"
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
    if (-not $summary.passed) {
        throw "Terrain3D Forward+ probe failed; see $summaryPath"
    }
    Write-Host "Terrain3D Forward+ probe passed: $summaryPath"
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
