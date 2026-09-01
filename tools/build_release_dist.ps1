[CmdletBinding()]
param(
    [Parameter()]
    [string]$GodotExe = "",

    [Parameter()]
    [string]$ToolchainRoot = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$godotProject = Join-Path $repoRoot "godot\client"
$godotDist = Join-Path $repoRoot "godot\dist"
$gatewayWindows = Join-Path $repoRoot "dist\can_gateway"
$gatewayLinux = Join-Path $repoRoot "dist\can_gateway_linux"
$manifestTool = Join-Path $repoRoot "tools\build_manifest.py"
$linuxPackager = Join-Path $repoRoot "tools\package_linux_release.sh"
$stagingRoot = Join-Path $godotDist (".release-staging-" + [guid]::NewGuid().ToString("N"))
. (Join-Path $PSScriptRoot "godot_voxel_toolchain.ps1")

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter()]
        [string]$WorkingDirectory = $repoRoot,
        [Parameter()]
        [int]$TimeoutSeconds = 1800
    )
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.WorkingDirectory = $WorkingDirectory
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
    if (-not [string]::IsNullOrEmpty($stdoutText)) {
        [Console]::Out.Write($stdoutText)
    }
    if (-not [string]::IsNullOrEmpty($stderrText)) {
        [Console]::Error.Write($stderrText)
    }
    if ($process.ExitCode -ne 0) {
        throw "$Name failed with exit code $($process.ExitCode)"
    }
}

function Copy-ReleaseNotices {
    param([Parameter(Mandatory)][string]$Destination)
    Copy-Item -LiteralPath (Join-Path $repoRoot "LICENSE") -Destination $Destination -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot "NOTICE.md") -Destination $Destination -Force
    $thirdParty = Join-Path $Destination "THIRD_PARTY"
    New-Item -ItemType Directory -Path $thirdParty -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $godotProject "addons\terrain_3d\LICENSE.txt") `
        -Destination (Join-Path $thirdParty "Terrain3D-LICENSE.txt") -Force
    Copy-Item -LiteralPath (Join-Path $godotProject "addons\sky_3d\LICENSE.txt") `
        -Destination (Join-Path $thirdParty "Sky3D-LICENSE.txt") -Force
    Copy-Item -LiteralPath (Join-Path $godotProject "addons\sky_3d\EXCAVATORSIM-PROVENANCE.md") `
        -Destination (Join-Path $thirdParty "Sky3D-PROVENANCE.md") -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot "assets\licenses\VoxelTools-LICENSE.txt") `
        -Destination (Join-Path $thirdParty "VoxelTools-LICENSE.txt") -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot "assets\licenses\VoxelTools-PROVENANCE.md") `
        -Destination (Join-Path $thirdParty "VoxelTools-PROVENANCE.md") -Force
}

function Assert-ReleaseFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required release file is missing: $Path"
    }
}

function Assert-ReleaseHash {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    Assert-ReleaseFile -Path $Source
    Assert-ReleaseFile -Path $Destination
    $sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    $destinationHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    if ($sourceHash -ne $destinationHash) {
        throw "Release file does not match the vendored source: $Destination"
    }
}

function Move-GatewayRuntimeResidue {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$Platform
    )
    $residue = Join-Path $PackageRoot "output"
    if (-not (Test-Path -LiteralPath $residue)) {
        return
    }
    $resolvedPackage = [IO.Path]::GetFullPath($PackageRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $resolvedResidue = [IO.Path]::GetFullPath($residue)
    if (-not $resolvedResidue.StartsWith(
        $resolvedPackage + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Refusing to move residue outside the Gateway package: $resolvedResidue"
    }
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $recoveryRoot = Join-Path $repoRoot "output\release-build-residue\$stamp-$Platform"
    New-Item -ItemType Directory -Path (Split-Path -Parent $recoveryRoot) -Force | Out-Null
    Move-Item -LiteralPath $resolvedResidue -Destination $recoveryRoot
    Write-Output "preserved runtime residue: $recoveryRoot"
}

function Assert-GatewayPackageLayout {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string[]]$AllowedFiles
    )
    $unexpected = @(
        Get-ChildItem -LiteralPath $PackageRoot -Recurse -File | Where-Object {
            $relative = [IO.Path]::GetRelativePath($PackageRoot, $_.FullName).Replace("\", "/")
            $AllowedFiles -notcontains $relative -and $relative -notlike "dbc/*.dbc"
        }
    )
    if ($unexpected.Count -gt 0) {
        throw "Unexpected Gateway release files: $(($unexpected.FullName) -join ', ')"
    }
}

function Assert-NoRunningReleaseProcesses {
    $releaseRoot = [IO.Path]::GetFullPath($godotDist).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $locked = @(
        Get-CimInstance Win32_Process | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) -and
            [IO.Path]::GetFullPath($_.ExecutablePath).StartsWith(
                $releaseRoot + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase
            )
        }
    )
    if ($locked.Count -gt 0) {
        $details = ($locked | ForEach-Object {
            "PID $($_.ProcessId) $($_.ExecutablePath)"
        }) -join "; "
        throw "Close the running release before rebuilding: $details"
    }
}

function Install-StagedRelease {
    param(
        [Parameter(Mandatory)][string]$StagedWindows,
        [Parameter(Mandatory)][string]$StagedLinux,
        [Parameter(Mandatory)][string]$StagedLinuxArchive
    )
    $resolvedDist = [IO.Path]::GetFullPath($godotDist).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $items = @(
        [pscustomobject]@{ Staged = $StagedWindows; Target = (Join-Path $godotDist "windows"); Kind = "directory" },
        [pscustomobject]@{ Staged = $StagedLinux; Target = (Join-Path $godotDist "linux"); Kind = "directory" },
        [pscustomobject]@{ Staged = $StagedLinuxArchive; Target = (Join-Path $godotDist "ExcavatorSim-linux-x86_64.tar.gz"); Kind = "file" }
    )
    foreach ($item in $items) {
        $item.Target = [IO.Path]::GetFullPath($item.Target)
        if (-not $item.Target.StartsWith(
            $resolvedDist + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Refusing to replace path outside Godot dist: $($item.Target)"
        }
    }

    $backups = @()
    $installed = @()
    try {
        foreach ($item in $items) {
            if (Test-Path -LiteralPath $item.Target) {
                $backup = Join-Path $godotDist (".release-backup-" + [guid]::NewGuid().ToString("N"))
                Move-Item -LiteralPath $item.Target -Destination $backup
                $backups += [pscustomobject]@{ Backup = $backup; Target = $item.Target }
            }
            Move-Item -LiteralPath $item.Staged -Destination $item.Target
            $installed += $item
        }
    }
    catch {
        for ($index = $installed.Count - 1; $index -ge 0; $index--) {
            $item = $installed[$index]
            if (Test-Path -LiteralPath $item.Target) {
                if ($item.Kind -eq "directory") {
                    Remove-Item -LiteralPath $item.Target -Recurse -Force
                }
                else {
                    Remove-Item -LiteralPath $item.Target -Force
                }
            }
        }
        for ($index = $backups.Count - 1; $index -ge 0; $index--) {
            $backup = $backups[$index]
            if (Test-Path -LiteralPath $backup.Backup) {
                Move-Item -LiteralPath $backup.Backup -Destination $backup.Target
            }
        }
        throw
    }
    foreach ($backup in $backups) {
        if (Test-Path -LiteralPath $backup.Backup) {
            if ((Get-Item -LiteralPath $backup.Backup).PSIsContainer) {
                Remove-Item -LiteralPath $backup.Backup -Recurse -Force
            }
            else {
                Remove-Item -LiteralPath $backup.Backup -Force
            }
        }
    }
}

function Write-BuildManifest {
    param(
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ArtifactRoot,
        [Parameter()][string]$BuildToolchain = ""
    )
    $arguments = @(
        $manifestTool,
        "--output", $Output,
        "--artifact-root", "$Name=$ArtifactRoot"
    )
    if (-not [string]::IsNullOrWhiteSpace($BuildToolchain)) {
        $arguments += @("--build-toolchain", $BuildToolchain)
    }
    Invoke-NativeChecked -FilePath "python" -Name "manifest $Name" -Arguments $arguments
}

Assert-NoRunningReleaseProcesses
New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
try {
    $isolatedProject = Join-Path $stagingRoot "client"
    $toolchain = New-GodotVoxelExportProject -Source $godotProject `
        -Destination $isolatedProject -GodotExe $GodotExe -ToolchainRoot $ToolchainRoot
    $GodotExe = [string]$toolchain.components.windows_editor.path
    $toolchainEvidence = Join-Path $stagingRoot "build-toolchain.json"
    [IO.File]::WriteAllText(
        $toolchainEvidence,
        ($toolchain | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false)
    )

    Write-Output "== Import isolated Godot project =="
    Invoke-NativeChecked -FilePath $GodotExe -Name "isolated Godot import" -Arguments @(
        "--headless", "--path", $isolatedProject, "--editor", "--quit"
    )

    Write-Output "== Verify source Voxel Tools module =="
    Invoke-NativeChecked -FilePath $GodotExe -Name "source Voxel module canary" -Arguments @(
        "--headless", "--path", $isolatedProject,
        "--script", "res://tests/voxel_module_smoke.gd"
    )

    Write-Output "== Build Windows Gateway =="
    Invoke-NativeChecked -FilePath "python" -Name "Windows Gateway build" -Arguments @(
        (Join-Path $repoRoot "tools\can_gateway\build_exe.py")
    )

    Write-Output "== Build Linux Gateway in WSL =="
    $wslPathInput = $repoRoot.Replace("\", "/")
    $wslPathOutput = & wsl.exe wslpath -a $wslPathInput
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($wslPathOutput)) {
        throw "Unable to resolve the repository path inside WSL"
    }
    $wslRepoRoot = $wslPathOutput.Trim()
    if ($wslRepoRoot.Contains("'")) {
        throw "WSL repository path contains an unsupported quote: $wslRepoRoot"
    }
    Invoke-NativeChecked -FilePath "wsl.exe" -Name "Linux Gateway build" -Arguments @(
        "bash", "-lc", "cd '$wslRepoRoot/tools/can_gateway' && ./dist_linux.sh"
    )

    Move-GatewayRuntimeResidue -PackageRoot $gatewayWindows -Platform "gateway-windows"
    Move-GatewayRuntimeResidue -PackageRoot $gatewayLinux -Platform "gateway-linux"
    Assert-GatewayPackageLayout -PackageRoot $gatewayWindows -AllowedFiles @("gateway.exe", "build-manifest.json")
    Assert-GatewayPackageLayout -PackageRoot $gatewayLinux -AllowedFiles @(
        "gateway", "can0-setup-helper", "install_can0_helper.sh",
        "uninstall_can0_helper.sh", "build-manifest.json"
    )

    Write-BuildManifest -Output (Join-Path $gatewayWindows "build-manifest.json") `
        -Name "gateway-windows" -ArtifactRoot $gatewayWindows
    Write-BuildManifest -Output (Join-Path $gatewayLinux "build-manifest.json") `
        -Name "gateway-linux" -ArtifactRoot $gatewayLinux

    $stagedWindows = Join-Path $stagingRoot "windows"
    $stagedLinux = Join-Path $stagingRoot "linux"
    New-Item -ItemType Directory -Path $stagedWindows, $stagedLinux -Force | Out-Null

    Write-Output "== Export Godot Windows =="
    Invoke-NativeChecked -FilePath $GodotExe -Name "Godot Windows export" -Arguments @(
        "--headless", "--path", $isolatedProject,
        "--export-release", "ExcavatorSim", (Join-Path $stagedWindows "ExcavatorSim.exe")
    )

    Write-Output "== Export Godot Linux =="
    Invoke-NativeChecked -FilePath $GodotExe -Name "Godot Linux export" -Arguments @(
        "--headless", "--path", $isolatedProject,
        "--export-release", "Linux", (Join-Path $stagedLinux "ExcavatorSim.x86_64")
    )

    Write-Output "== Export and run Voxel Tools template canaries =="
    $projectFile = Join-Path $isolatedProject "project.godot"
    $productProjectText = [IO.File]::ReadAllText($projectFile)
    $canaryProjectText = $productProjectText.Replace(
        'run/main_scene="res://scenes/main.tscn"',
        'run/main_scene="res://tests/voxel_module_export_smoke.tscn"'
    )
    if (-not $canaryProjectText.Contains(
            'run/main_scene="res://tests/voxel_module_export_smoke.tscn"')) {
        throw "Unable to select the isolated Voxel module export canary scene"
    }
    $canaryRoot = Join-Path $stagingRoot "voxel-canary"
    $canaryWindows = Join-Path $canaryRoot "windows\VoxelModuleCanary.exe"
    $canaryLinux = Join-Path $canaryRoot "linux\VoxelModuleCanary.x86_64"
    New-Item -ItemType Directory -Path (Split-Path -Parent $canaryWindows), `
        (Split-Path -Parent $canaryLinux) -Force | Out-Null
    try {
        [IO.File]::WriteAllText(
            $projectFile,
            $canaryProjectText,
            [Text.UTF8Encoding]::new($false)
        )
        Invoke-NativeChecked -FilePath $GodotExe -Name "Windows Voxel template canary export" `
            -Arguments @(
                "--headless", "--path", $isolatedProject,
                "--export-release", "ExcavatorSim", $canaryWindows
            )
        Invoke-NativeChecked -FilePath $GodotExe -Name "Linux Voxel template canary export" `
            -Arguments @(
                "--headless", "--path", $isolatedProject,
                "--export-release", "Linux", $canaryLinux
            )
    }
    finally {
        [IO.File]::WriteAllText(
            $projectFile,
            $productProjectText,
            [Text.UTF8Encoding]::new($false)
        )
    }
    Invoke-NativeChecked -FilePath $canaryWindows `
        -Name "Windows packaged Voxel module canary" -Arguments @("--headless")
    $wslCanaryLinux = (& wsl.exe wslpath -a $canaryLinux.Replace("\", "/")).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($wslCanaryLinux)) {
        throw "Unable to resolve the Linux Voxel canary executable inside WSL"
    }
    Invoke-NativeChecked -FilePath "wsl.exe" -Name "Linux packaged Voxel module canary" `
        -Arguments @(
            "--exec", "sh", "-c", 'chmod +x "$1" && "$1" --headless',
            "sh", $wslCanaryLinux
        )

    Copy-Item -LiteralPath $gatewayWindows -Destination (Join-Path $stagedWindows "can_gateway") -Recurse -Force
    Copy-Item -LiteralPath $gatewayLinux -Destination (Join-Path $stagedLinux "can_gateway") -Recurse -Force
    Copy-ReleaseNotices -Destination $stagedWindows
    Copy-ReleaseNotices -Destination $stagedLinux

    Assert-ReleaseFile -Path (Join-Path $stagedWindows "ExcavatorSim.exe")
    Assert-ReleaseFile -Path (Join-Path $stagedWindows "can_gateway\gateway.exe")
    Assert-ReleaseFile -Path (Join-Path $stagedLinux "ExcavatorSim.x86_64")
    Assert-ReleaseFile -Path (Join-Path $stagedLinux "can_gateway\gateway")
    Assert-ReleaseHash `
        -Source (Join-Path $godotProject "addons\terrain_3d\bin\libterrain.windows.release.x86_64.dll") `
        -Destination (Join-Path $stagedWindows "libterrain.windows.release.x86_64.dll")
    Assert-ReleaseHash `
        -Source (Join-Path $godotProject "addons\terrain_3d\bin\libterrain.linux.release.x86_64.so") `
        -Destination (Join-Path $stagedLinux "libterrain.linux.release.x86_64.so")

    Write-BuildManifest -Output (Join-Path $stagedWindows "build-manifest.json") `
        -Name "godot-windows" -ArtifactRoot $stagedWindows -BuildToolchain $toolchainEvidence
    Write-BuildManifest -Output (Join-Path $stagedLinux "build-manifest.json") `
        -Name "godot-linux" -ArtifactRoot $stagedLinux -BuildToolchain $toolchainEvidence

    $wslStagedLinux = (& wsl.exe wslpath -a $stagedLinux.Replace("\", "/")).Trim()
    $stagedLinuxArchive = Join-Path $stagingRoot "ExcavatorSim-linux-x86_64.tar.gz"
    $wslStagedLinuxArchive = (& wsl.exe wslpath -a $stagedLinuxArchive.Replace("\", "/")).Trim()
    $wslLinuxPackager = (& wsl.exe wslpath -a $linuxPackager.Replace("\", "/")).Trim()
    Invoke-NativeChecked -FilePath "wsl.exe" -Name "Linux release archive" -Arguments @(
        "bash", $wslLinuxPackager, $wslStagedLinux, $wslStagedLinuxArchive
    )

    Install-StagedRelease -StagedWindows $stagedWindows -StagedLinux $stagedLinux `
        -StagedLinuxArchive $stagedLinuxArchive

    Write-Output "release dist ready:"
    Write-Output "  $($godotDist)\windows"
    Write-Output "  $($godotDist)\linux"
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}
