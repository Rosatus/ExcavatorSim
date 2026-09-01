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
$sourceProject = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$repoRoot = (Resolve-Path (Join-Path $sourceProject "..\..")).Path
. (Join-Path $repoRoot "tools\godot_voxel_toolchain.ps1")
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputDir = Join-Path $repoRoot "output\terrain3d_phase4\$stamp"
}
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$isolateRoot = Join-Path $tempBase ("ExcavatorSim-terrain3d-release-" + [guid]::NewGuid().ToString("N"))
$isolatedProject = Join-Path $isolateRoot "client"

function Invoke-CheckedProcess {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter()]
        [int]$TimeoutSeconds = 180
    )
    $stdout = Join-Path $OutputDir "$Name.stdout.log"
    $stderr = Join-Path $OutputDir "$Name.stderr.log"
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "$Name could not be started"
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill($true)
        throw "$Name timed out after $TimeoutSeconds seconds"
    }
    $stdoutText = $stdoutTask.GetAwaiter().GetResult()
    $stderrText = $stderrTask.GetAwaiter().GetResult()
    [IO.File]::WriteAllText($stdout, $stdoutText, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($stderr, $stderrText, [Text.UTF8Encoding]::new($false))
    if ($process.ExitCode -ne 0) {
        throw "$Name failed with exit code $($process.ExitCode); see $stdout and $stderr"
    }
}

function Copy-ReleaseNotices {
    param([Parameter(Mandatory)][string]$Destination)
    Copy-Item -LiteralPath (Join-Path $repoRoot "LICENSE") -Destination $Destination -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot "NOTICE.md") -Destination $Destination -Force
    $thirdPartyDir = Join-Path $Destination "THIRD_PARTY"
    New-Item -ItemType Directory -Path $thirdPartyDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceProject "addons\terrain_3d\LICENSE.txt") `
        -Destination (Join-Path $thirdPartyDir "Terrain3D-LICENSE.txt") -Force
    Copy-Item -LiteralPath (Join-Path $sourceProject "addons\sky_3d\LICENSE.txt") `
        -Destination (Join-Path $thirdPartyDir "Sky3D-LICENSE.txt") -Force
    Copy-Item -LiteralPath (Join-Path $sourceProject "addons\sky_3d\EXCAVATORSIM-PROVENANCE.md") `
        -Destination (Join-Path $thirdPartyDir "Sky3D-PROVENANCE.md") -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot "assets\licenses\VoxelTools-LICENSE.txt") `
        -Destination (Join-Path $thirdPartyDir "VoxelTools-LICENSE.txt") -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot "assets\licenses\VoxelTools-PROVENANCE.md") `
        -Destination (Join-Path $thirdPartyDir "VoxelTools-PROVENANCE.md") -Force
}

try {
    $toolchain = New-GodotVoxelExportProject -Source $sourceProject `
        -Destination $isolatedProject -GodotExe $GodotExe -ToolchainRoot $ToolchainRoot
    $GodotExe = [string]$toolchain.components.windows_editor.path

    Invoke-CheckedProcess -FilePath $GodotExe -Name "source-voxel-module" -Arguments @(
        "--headless", "--path", $sourceProject,
        "--script", "res://tests/voxel_module_smoke.gd"
    )

    $editorEvidence = Join-Path $OutputDir "editor-smoke.json"
    Invoke-CheckedProcess -FilePath $GodotExe -Name "editor-smoke" -Arguments @(
        "--headless", "--path", $sourceProject,
        "res://tests/terrain3d_export_smoke.tscn",
        "--", "--output-file", $editorEvidence
    )

    $projectFile = Join-Path $isolatedProject "project.godot"
    $projectText = [IO.File]::ReadAllText($projectFile)
    $projectText = $projectText.Replace(
        'run/main_scene="res://scenes/main.tscn"',
        'run/main_scene="res://tests/terrain3d_export_smoke.tscn"'
    )
    if (-not $projectText.Contains('run/main_scene="res://tests/terrain3d_export_smoke.tscn"')) {
        throw "Unable to select the isolated release-smoke entry scene"
    }
    [IO.File]::WriteAllText($projectFile, $projectText, [Text.UTF8Encoding]::new($false))

    Invoke-CheckedProcess -FilePath $GodotExe -Name "isolated-import" -Arguments @(
        "--headless", "--editor", "--quit", "--path", $isolatedProject
    )

    $packageDir = Join-Path $OutputDir "package\windows"
    New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
    $exportExe = Join-Path $packageDir "ExcavatorSim.exe"
    Invoke-CheckedProcess -FilePath $GodotExe -Name "windows-export" -TimeoutSeconds 300 -Arguments @(
        "--headless", "--path", $isolatedProject,
        "--export-release", "ExcavatorSim", $exportExe
    )

    $linuxPackageDir = Join-Path $OutputDir "package\linux"
    New-Item -ItemType Directory -Path $linuxPackageDir -Force | Out-Null
    $linuxExport = Join-Path $linuxPackageDir "ExcavatorSim.x86_64"
    Invoke-CheckedProcess -FilePath $GodotExe -Name "linux-export" -TimeoutSeconds 300 -Arguments @(
        "--headless", "--path", $isolatedProject,
        "--export-release", "Linux", $linuxExport
    )

    $terrainDll = Join-Path $packageDir "libterrain.windows.release.x86_64.dll"
    if (-not (Test-Path -LiteralPath $terrainDll -PathType Leaf)) {
        throw "Windows export omitted the Terrain3D release DLL"
    }
    $sourceTerrainDll = Join-Path $sourceProject "addons\terrain_3d\bin\libterrain.windows.release.x86_64.dll"
    $sourceTerrainHash = (Get-FileHash -LiteralPath $sourceTerrainDll -Algorithm SHA256).Hash
    $packageTerrainHash = (Get-FileHash -LiteralPath $terrainDll -Algorithm SHA256).Hash
    if ($sourceTerrainHash -ne $packageTerrainHash) {
        throw "Windows export Terrain3D DLL does not match the vendored release binary"
    }
    $linuxTerrainSo = Join-Path $linuxPackageDir "libterrain.linux.release.x86_64.so"
    if (-not (Test-Path -LiteralPath $linuxTerrainSo -PathType Leaf)) {
        throw "Linux export omitted the Terrain3D release SO"
    }
    $sourceTerrainSo = Join-Path $sourceProject "addons\terrain_3d\bin\libterrain.linux.release.x86_64.so"
    $sourceTerrainSoHash = (Get-FileHash -LiteralPath $sourceTerrainSo -Algorithm SHA256).Hash
    $packageTerrainSoHash = (Get-FileHash -LiteralPath $linuxTerrainSo -Algorithm SHA256).Hash
    if ($sourceTerrainSoHash -ne $packageTerrainSoHash) {
        throw "Linux export Terrain3D SO does not match the vendored release binary"
    }
    Copy-ReleaseNotices -Destination $packageDir
    Copy-ReleaseNotices -Destination $linuxPackageDir

    $exportEvidence = Join-Path $OutputDir "export-smoke.json"
    Invoke-CheckedProcess -FilePath $exportExe -Name "export-smoke" -Arguments @(
        "--headless", "--", "--output-file", $exportEvidence
    )
    $wslLinuxExport = (& wsl.exe wslpath -a $linuxExport.Replace("\", "/")).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($wslLinuxExport)) {
        throw "Unable to resolve the Linux validation executable inside WSL"
    }
    $linuxExportEvidence = Join-Path $OutputDir "linux-export-smoke.json"
    $wslLinuxEvidence = (& wsl.exe wslpath -a $linuxExportEvidence.Replace("\", "/")).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($wslLinuxEvidence)) {
        throw "Unable to resolve the Linux validation evidence path inside WSL"
    }
    Invoke-CheckedProcess -FilePath "wsl.exe" -Name "linux-export-smoke" -Arguments @(
        "--exec", "sh", "-c",
        'chmod +x "$1" && "$1" --headless -- --output-file "$2"',
        "sh", $wslLinuxExport, $wslLinuxEvidence
    )

    $editor = Get-Content -LiteralPath $editorEvidence -Raw | ConvertFrom-Json
    $exported = Get-Content -LiteralPath $exportEvidence -Raw | ConvertFrom-Json
    $linuxExported = Get-Content -LiteralPath $linuxExportEvidence -Raw | ConvertFrom-Json
    $parity = [ordered]@{
        configured_backend = ($editor.details.startup.configured_backend -eq $exported.details.startup.configured_backend)
        active_backend = ($editor.details.startup.active_backend -eq $exported.details.startup.active_backend)
        material_identity = ($editor.details.startup.material_identity -eq $exported.details.startup.material_identity)
        fallback_backend = ($editor.details.failed_open.active_backend -eq $exported.details.failed_open.active_backend)
        rollback_backend = ($editor.details.explicit_rollback.active_backend -eq $exported.details.explicit_rollback.active_backend)
        rollback_restored = ($editor.details.rollback_restored.active_backend -eq $exported.details.rollback_restored.active_backend)
        final_backend = ($editor.details.final.active_backend -eq $exported.details.final.active_backend)
        active_model_id = ($editor.details.active_model_id -eq $exported.details.active_model_id)
        bucket_ground_mode = ($editor.details.bucket_ground.restored_mode -eq $exported.details.bucket_ground.restored_mode)
        bucket_ground_entry_immutable = ([bool]$editor.details.bucket_ground.entry_terrain_unchanged -and [bool]$exported.details.bucket_ground.entry_terrain_unchanged)
        bucket_ground_exit_immutable = ([bool]$editor.details.bucket_ground.exit_terrain_unchanged -and [bool]$exported.details.bucket_ground.exit_terrain_unchanged)
        bucket_ground_query_bypass = ([int]$editor.details.bucket_ground.query_bypassed -gt 0 -and [int]$exported.details.bucket_ground.query_bypassed -gt 0)
        bucket_ground_soil_bypass = ([int]$editor.details.bucket_ground.soil_bypassed -gt 0 -and [int]$exported.details.bucket_ground.soil_bypassed -gt 0)
        bucket_ground_effects_bypass = ([int]$editor.details.bucket_ground.effects_bypassed -gt 0 -and [int]$exported.details.bucket_ground.effects_bypassed -gt 0)
    }
    $logText = @(
        Get-ChildItem -LiteralPath $OutputDir -Filter "*.log" -File |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }
    ) -join "`n"
    $fatalLogMatches = @(
        [regex]::Matches(
            $logText,
            '(?im)^.*(?:SCRIPT ERROR|FATAL|CRASH|Failed to load.*Terrain3D|GDExtension.*(?:fail|error)).*$'
        ) | ForEach-Object { $_.Value.Trim() } | Sort-Object -Unique
    )
    $summary = [ordered]@{
        schema_version = "terrain3d-release-validation-v1"
        passed = ([bool]$editor.passed -and [bool]$exported.passed -and [bool]$linuxExported.passed -and
            -not ($parity.Values -contains $false) -and $fatalLogMatches.Count -eq 0)
        editor_evidence = $editorEvidence
        export_evidence = $exportEvidence
        linux_export_evidence = $linuxExportEvidence
        package_dir = $packageDir
        linux_package_dir = $linuxPackageDir
        package_files = @(
            Get-ChildItem -LiteralPath $packageDir -Recurse -File | ForEach-Object {
                [ordered]@{
                    path = [IO.Path]::GetRelativePath($packageDir, $_.FullName)
                    size = $_.Length
                    sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
        )
        linux_package_files = @(
            Get-ChildItem -LiteralPath $linuxPackageDir -Recurse -File | ForEach-Object {
                [ordered]@{
                    path = [IO.Path]::GetRelativePath($linuxPackageDir, $_.FullName)
                    size = $_.Length
                    sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
        )
        parity = $parity
        terrain3d_release_sha256 = $packageTerrainHash.ToLowerInvariant()
        linux_terrain3d_release_sha256 = $packageTerrainSoHash.ToLowerInvariant()
        build_toolchain = $toolchain.build_toolchain
        fatal_log_matches = $fatalLogMatches
    }
    $summaryPath = Join-Path $OutputDir "run-summary.json"
    [IO.File]::WriteAllText(
        $summaryPath,
        ($summary | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false)
    )
    if (-not $summary.passed) {
        throw "Terrain3D editor/export parity failed; see $summaryPath"
    }
    Write-Output $summaryPath
}
finally {
    $resolvedIsolate = [IO.Path]::GetFullPath($isolateRoot)
    if ($resolvedIsolate.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
            $resolvedIsolate -ne $tempBase -and (Test-Path -LiteralPath $resolvedIsolate)) {
        Remove-Item -LiteralPath $resolvedIsolate -Recurse -Force
    }
}
