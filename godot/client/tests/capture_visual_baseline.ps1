[CmdletBinding()]
param(
    [Parameter()]
    [string]$GodotExe = "godot",

    [Parameter()]
    [string]$OutputDir = "",

    [Parameter()]
    [ValidateSet("sy205", "sy135", "all")]
    [string]$Model = "all",

    [Parameter()]
    [ValidateSet("low", "balanced", "high", "all")]
    [string]$QualityProfile = "all",

    [Parameter()]
    [ValidateSet("before", "after")]
    [string]$EvidencePhase = "before"
)

$ErrorActionPreference = "Stop"
$projectDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../../..")).Path
$commit = (& git -C $repoRoot rev-parse HEAD).Trim()
$timestamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$runId = "$timestamp-$($commit.Substring(0, 8))"
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot "artifacts/benchmark/visual-baseline-$EvidencePhase-raw/$runId"
}
$resolvedOutput = [System.IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null
$stdoutLog = Join-Path $resolvedOutput "godot.stdout.log"
$stderrLog = Join-Path $resolvedOutput "godot.stderr.log"
$summaryPath = Join-Path $resolvedOutput "run-summary.json"
$modelList = if ($Model -eq "all") { "sy205,sy135" } else { $Model }
$qualityList = if ($QualityProfile -eq "all") { "low,balanced,high" } else { $QualityProfile }
$partialSelection = $Model -ne "all" -or $QualityProfile -ne "all"
$captureCommand = "capture_visual_baseline.ps1 -EvidencePhase $EvidencePhase -Model $Model -QualityProfile $QualityProfile -OutputDir `"$resolvedOutput`""
$godotArguments = @(
    "--path", $projectDir,
    "--audio-driver", "Dummy",
    "--resolution", "1920x1080",
    "--script", "res://tests/visual_evidence_matrix.gd",
    "--",
    "--evidence-output", $resolvedOutput,
    "--evidence-commit", $commit,
    "--evidence-command", $captureCommand,
    "--evidence-run-id", $runId,
    "--evidence-error-log", $summaryPath,
    "--evidence-models", $modelList,
    "--evidence-quality-profiles", $qualityList
    "--evidence-phase", $EvidencePhase
)

Write-Host "[visual-evidence] run $runId"
Write-Host "[visual-evidence] output $resolvedOutput"
& $GodotExe @godotArguments 1> $stdoutLog 2> $stderrLog
$exitCode = $LASTEXITCODE
$errorMatches = @(
    Select-String -Path $stdoutLog, $stderrLog -Pattern "SCRIPT ERROR|ERROR:|FATAL|CRASH" -AllMatches
)
$errorResult = [ordered]@{
    status = if ($errorMatches.Count -eq 0) { "clean" } else { "errors_observed" }
    match_count = $errorMatches.Count
    stdout_log = $stdoutLog
    stderr_log = $stderrLog
    process_exit_code = $exitCode
}
$summary = [ordered]@{
    schema_version = "excavator-sim-visual-evidence-run-v2"
    run_id = $runId
    evidence_phase = $EvidencePhase
    captured_at_utc = [DateTime]::UtcNow.ToString("o")
    commit = $commit
    command = $captureCommand
    model_selection = $modelList
    quality_selection = $qualityList
    partial = $partialSelection
    resolution = @(1920, 1080)
    error_log_result = $errorResult
}
$summary | ConvertTo-Json -Depth 20 | Set-Content -Encoding utf8 $summaryPath

$manifestPath = Join-Path $resolvedOutput "manifest.json"
$manifestComplete = $false
if (Test-Path -LiteralPath $manifestPath) {
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    $manifest | Add-Member -NotePropertyName evidence_phase -NotePropertyValue $EvidencePhase -Force
    $manifest | Add-Member -NotePropertyName error_log_result -NotePropertyValue $errorResult -Force
    foreach ($entry in $manifest.entries) {
        $entry | Add-Member -NotePropertyName error_log_result -NotePropertyValue $errorResult -Force
        foreach ($checkpoint in $entry.checkpoints) {
            $checkpoint | Add-Member -NotePropertyName error_log_result -NotePropertyValue $errorResult -Force
        }

        $metadataPath = [string]$entry.metadata_path
        if (-not [string]::IsNullOrWhiteSpace($metadataPath) -and (Test-Path -LiteralPath $metadataPath)) {
            $metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json
            $metadata | Add-Member -NotePropertyName error_log_result -NotePropertyValue $errorResult -Force
            foreach ($checkpoint in $metadata.checkpoints) {
                $checkpoint | Add-Member -NotePropertyName error_log_result -NotePropertyValue $errorResult -Force
            }
            $metadata | ConvertTo-Json -Depth 100 | Set-Content -Encoding utf8 -LiteralPath $metadataPath
        }
        else {
            throw "Visual evidence metadata is missing: $metadataPath"
        }
    }
    if ($errorMatches.Count -gt 0 -or $exitCode -ne 0) {
        $manifest.complete = $false
        $failureReason = if ($errorMatches.Count -gt 0) {
            "godot_error_log_errors_observed"
        }
        else {
            "godot_process_failed"
        }
        $manifest.failures = @($manifest.failures) + $failureReason
    }
    $manifest | ConvertTo-Json -Depth 100 | Set-Content -Encoding utf8 $manifestPath
    $manifestComplete = [bool]$manifest.complete
}
else {
    throw "Visual evidence manifest is missing: $manifestPath"
}

if ($exitCode -ne 0) {
    throw "Visual evidence capture failed with exit code $exitCode. See $summaryPath"
}
if ($errorMatches.Count -gt 0) {
    throw "Visual evidence capture produced $($errorMatches.Count) Godot error log matches. See $summaryPath"
}
if (-not $partialSelection -and -not $manifestComplete) {
    throw "Visual evidence full matrix is incomplete. See $manifestPath"
}
if ($EvidencePhase -eq "after" -and -not [bool]$manifest.all_scenarios_achieved) {
    throw "After evidence contains unachieved product scenarios. See $manifestPath"
}
if ($partialSelection) {
    Write-Host "Visual evidence partial selection passed (not a complete baseline). Summary: $summaryPath"
}
else {
    Write-Host "Visual evidence capture passed. Summary: $summaryPath"
}
