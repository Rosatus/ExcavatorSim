$script:GodotVoxelToolchainCli = Join-Path $PSScriptRoot "godot_voxel_toolchain.py"

function Invoke-GodotVoxelToolchainCli {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $outputPath = [IO.Path]::GetTempFileName()
    try {
        & python $script:GodotVoxelToolchainCli @Arguments --output $outputPath
        if ($LASTEXITCODE -ne 0) {
            throw "Godot/Voxel toolchain validation failed with exit code $LASTEXITCODE"
        }
        return Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
    }
    finally {
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-GodotVoxelToolchain {
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$GodotExe = "",

        [Parameter()]
        [AllowEmptyString()]
        [string]$ToolchainRoot = "",

        [Parameter()]
        [string[]]$Components = @("windows_editor")
    )

    $arguments = @("verify")
    foreach ($component in $Components) {
        $arguments += @("--component", $component)
    }
    if (-not [string]::IsNullOrWhiteSpace($GodotExe)) {
        $arguments += @("--godot-exe", $GodotExe)
    }
    if (-not [string]::IsNullOrWhiteSpace($ToolchainRoot)) {
        $arguments += @("--root", $ToolchainRoot)
    }
    return Invoke-GodotVoxelToolchainCli -Arguments $arguments
}

function New-GodotVoxelExportProject {
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination,

        [Parameter()]
        [AllowEmptyString()]
        [string]$GodotExe = "",

        [Parameter()]
        [AllowEmptyString()]
        [string]$ToolchainRoot = ""
    )

    $arguments = @("stage-project", "--source", $Source, "--destination", $Destination)
    if (-not [string]::IsNullOrWhiteSpace($GodotExe)) {
        $arguments += @("--godot-exe", $GodotExe)
    }
    if (-not [string]::IsNullOrWhiteSpace($ToolchainRoot)) {
        $arguments += @("--root", $ToolchainRoot)
    }
    return Invoke-GodotVoxelToolchainCli -Arguments $arguments
}
