[CmdletBinding()]
param(
    [Parameter()]
    [string]$GodotExe = "",

    [Parameter()]
    [string]$ToolchainRoot = "",

    [Parameter()]
    [string]$OutputDir = ""
)

$ErrorActionPreference = "Stop"
$projectDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$repoRoot = (Resolve-Path (Join-Path $projectDir "..\..")).Path
. (Join-Path $repoRoot "tools\godot_voxel_toolchain.ps1")
$toolchain = Get-GodotVoxelToolchain -GodotExe $GodotExe `
    -ToolchainRoot $ToolchainRoot -Components @("windows_editor")
$GodotExe = [string]$toolchain.components.windows_editor.path
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputDir = Join-Path $repoRoot "output\terrain3d_phase3\$stamp"
}
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

function Invoke-GodotProcess {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [Parameter(Mandatory)]
        [string]$StdoutPath,
        [Parameter(Mandatory)]
        [string]$StderrPath
    )

    $process = Start-Process -FilePath $GodotExe -ArgumentList $Arguments -NoNewWindow `
        -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath -Wait -PassThru
    return $process.ExitCode
}

$importOut = Join-Path $OutputDir "import.stdout.log"
$importErr = Join-Path $OutputDir "import.stderr.log"
$importExit = Invoke-GodotProcess -Arguments @(
    "--headless", "--path", $projectDir, "--editor", "--quit"
) -StdoutPath $importOut -StderrPath $importErr
if ($importExit -ne 0) {
    throw "Godot import failed with exit code $importExit"
}

$testOut = Join-Path $OutputDir "test.stdout.log"
$testErr = Join-Path $OutputDir "test.stderr.log"
$testExit = Invoke-GodotProcess -Arguments @(
    "--headless", "--path", $projectDir,
    "--script", "res://tests/terrain3d_authority_equivalence_test.gd",
    "--", "--output-dir", $OutputDir
) -StdoutPath $testOut -StderrPath $testErr
$evidencePath = Join-Path $OutputDir "authority-equivalence.json"
if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
    throw "Authority equivalence test produced no evidence file (exit $testExit)"
}
$evidence = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json
$summary = [ordered]@{
    schema_version = "terrain3d-authority-equivalence-run-v1"
    passed = ($testExit -eq 0 -and [bool]$evidence.passed)
    test_exit_code = $testExit
    evidence_path = $evidencePath
}
$summaryPath = Join-Path $OutputDir "run-summary.json"
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $summaryPath -Encoding utf8
if (-not $summary.passed) {
    throw "Terrain3D authority equivalence failed; see $summaryPath"
}
Write-Host "Terrain3D authority equivalence passed: $summaryPath"
