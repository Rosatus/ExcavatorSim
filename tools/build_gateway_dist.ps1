[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet("all", "windows", "linux")]
    [string]$Platform = "all",
    [Parameter()][switch]$RefreshWebDependencies,
    [Parameter()][switch]$RequireClean,
    [Parameter()][switch]$SkipSmoke,
    [Parameter()][switch]$PlanOnly
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$distRoot = Join-Path $repoRoot "dist"
$webRoot = Join-Path $repoRoot "tools\can_gateway\web"
$webBundle = Join-Path $repoRoot "tools\can_gateway\resources\web"
$manifestTool = Join-Path $repoRoot "tools\build_manifest.py"
$frozenSmokeTool = Join-Path $repoRoot "tools\can_gateway\smoke_frozen_gateway.py"
$windowsTarget = Join-Path $distRoot "can_gateway"
$linuxTarget = Join-Path $distRoot "can_gateway_linux"
$selectedPlatforms = if ($Platform -eq "all") { @("windows", "linux") } else { @($Platform) }

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][string]$WorkingDirectory = $repoRoot
    )
    Write-Host "== $Name =="
    Push-Location $WorkingDirectory
    try {
        & $FilePath @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "$Name failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
}

function Assert-CleanTree {
    $status = & git -C $repoRoot status --porcelain=v1 --untracked-files=normal
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect the Git worktree"
    }
    if ($status) {
        throw "The worktree is dirty. Commit/stash intended release changes or omit -RequireClean."
    }
}

function Assert-WebBundle {
    $index = Join-Path $webBundle "index.html"
    $scripts = @(Get-ChildItem -LiteralPath (Join-Path $webBundle "assets") -Filter "index-*.js" -File -ErrorAction SilentlyContinue)
    if (-not (Test-Path -LiteralPath $index -PathType Leaf) -or $scripts.Count -eq 0) {
        throw "Gateway Web production bundle is missing under $webBundle"
    }
}

function Build-WebBundle {
    $bootstrap = Join-Path $env:USERPROFILE ".codex\scripts\Initialize-NodeCli.ps1"
    if (-not (Test-Path -LiteralPath $bootstrap -PathType Leaf)) {
        throw "Node CLI bootstrap is missing: $bootstrap"
    }
    & $bootstrap -Require node
    $npmCommand = (Get-Command npm.cmd, npm -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if ([string]::IsNullOrWhiteSpace($npmCommand)) {
        throw "npm is unavailable after Node CLI initialization"
    }
    $nodeVersion = (& node --version).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Unable to read the Node.js version" }
    $npmVersion = (& $npmCommand --version).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Unable to read the npm version" }

    $lockPath = Join-Path $webRoot "package-lock.json"
    $packagePath = Join-Path $webRoot "package.json"
    $nodeModules = Join-Path $webRoot "node_modules"
    $statePath = Join-Path $nodeModules ".excavatorsim-build-state.json"
    $expectedState = [ordered]@{
        package_lock_sha256 = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash.ToLowerInvariant()
        package_sha256 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
        node_version = $nodeVersion
        npm_version = $npmVersion
    }
    $requiredNodeTools = @(
        (Join-Path $nodeModules ".bin\tsc.cmd"),
        (Join-Path $nodeModules ".bin\vite.cmd")
    )
    $installDependencies = $RefreshWebDependencies `
        -or -not (Test-Path -LiteralPath $statePath -PathType Leaf) `
        -or @($requiredNodeTools | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count -gt 0
    if (-not $installDependencies) {
        try {
            $cachedState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
            foreach ($key in $expectedState.Keys) {
                if ($cachedState.$key -ne $expectedState[$key]) {
                    $installDependencies = $true
                    break
                }
            }
        }
        catch {
            $installDependencies = $true
        }
    }
    if ($installDependencies) {
        Invoke-NativeChecked -FilePath $npmCommand `
            -Arguments @("ci", "--prefer-offline", "--no-audit", "--no-fund") `
            -Name "Install Gateway Web dependencies" -WorkingDirectory $webRoot
        $expectedState | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding utf8
    }
    else {
        Write-Host "== Reuse Gateway Web dependencies ($nodeVersion / npm $npmVersion) =="
    }
    Invoke-NativeChecked -FilePath $npmCommand -Arguments @("run", "build") `
        -Name "Build Gateway Web once" -WorkingDirectory $webRoot
    Assert-WebBundle
}

function Assert-PackageLayout {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string[]]$RequiredFiles,
        [Parameter(Mandatory)][string[]]$AllowedFiles
    )
    foreach ($relative in $RequiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $PackageRoot $relative) -PathType Leaf)) {
            throw "Required Gateway release file is missing: $PackageRoot\$relative"
        }
    }
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

function Preserve-RuntimeResidue {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$Label
    )
    $runtimeOutput = Join-Path $PackageRoot "output"
    if (-not (Test-Path -LiteralPath $runtimeOutput)) { return }
    $resolvedPackage = [IO.Path]::GetFullPath($PackageRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $resolvedOutput = [IO.Path]::GetFullPath($runtimeOutput)
    if (-not $resolvedOutput.StartsWith(
        $resolvedPackage + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Refusing to move residue outside the Gateway package: $resolvedOutput"
    }
    $recoveryParent = Join-Path $repoRoot "output\release-build-residue"
    New-Item -ItemType Directory -Path $recoveryParent -Force | Out-Null
    $recoveryPath = Join-Path $recoveryParent "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$Label"
    Move-Item -LiteralPath $resolvedOutput -Destination $recoveryPath
    Write-Host "Preserved runtime residue: $recoveryPath"
}

function Remove-TreeWithRetry {
    param([Parameter(Mandatory)][string]$Path)

    for ($attempt = 1; $attempt -le 20; $attempt++) {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force
            return
        }
        catch {
            if ($attempt -eq 20) { throw }
            Start-Sleep -Milliseconds 250
        }
    }
}

function Install-StagedPackages {
    param([Parameter(Mandatory)][hashtable[]]$Packages)

    $resolvedDist = [IO.Path]::GetFullPath($distRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    foreach ($package in $Packages) {
        $resolvedTarget = [IO.Path]::GetFullPath([string]$package.Target)
        if (-not $resolvedTarget.StartsWith(
            $resolvedDist + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Refusing to install outside the distribution root: $resolvedTarget"
        }
        $package.Backup = Join-Path $distRoot (".gateway-backup-" + [guid]::NewGuid().ToString("N"))
        $package.HadTarget = Test-Path -LiteralPath ([string]$package.Target)
        $package.BackupMoved = $false
        $package.Installed = $false
    }

    $committed = $false
    try {
        foreach ($package in $Packages) {
            if ($package.HadTarget) {
                Move-Item -LiteralPath ([string]$package.Target) -Destination ([string]$package.Backup)
                $package.BackupMoved = $true
            }
        }
        foreach ($package in $Packages) {
            Move-Item -LiteralPath ([string]$package.Staged) -Destination ([string]$package.Target)
            $package.Installed = $true
        }
        $committed = $true
    }
    catch {
        foreach ($package in $Packages) {
            if ($package.Installed -and (Test-Path -LiteralPath ([string]$package.Target))) {
                Remove-Item -LiteralPath ([string]$package.Target) -Recurse -Force
            }
        }
        foreach ($package in $Packages) {
            if ($package.BackupMoved -and (Test-Path -LiteralPath ([string]$package.Backup))) {
                Move-Item -LiteralPath ([string]$package.Backup) -Destination ([string]$package.Target)
            }
        }
        throw
    }
    finally {
        if ($committed) {
            foreach ($package in $Packages) {
                if (Test-Path -LiteralPath ([string]$package.Backup)) {
                    try {
                        Remove-Item -LiteralPath ([string]$package.Backup) -Recurse -Force
                    }
                    catch {
                        Write-Warning "New package is installed, but its old backup could not be removed: $($package.Backup)"
                    }
                }
            }
        }
    }
}

if ($PlanOnly) {
    [ordered]@{
        platform = $Platform
        platforms = [string[]]$selectedPlatforms
        web_builds = 1
        dependency_cache = "tools/can_gateway/web/node_modules/.excavatorsim-build-state.json"
        windows_output = if ($selectedPlatforms -contains "windows") { "dist/can_gateway" } else { $null }
        linux_output = if ($selectedPlatforms -contains "linux") { "dist/can_gateway_linux" } else { $null }
        manifests = $true
        packaged_smoke = -not $SkipSmoke
    } | ConvertTo-Json -Depth 3
    return
}

if ($RequireClean) {
    Assert-CleanTree
}
elseif (& git -C $repoRoot status --porcelain=v1 --untracked-files=normal) {
    Write-Warning "The worktree is dirty; generated manifests will record git_tree_dirty=true."
}

Build-WebBundle
if ($RequireClean) { Assert-CleanTree }

New-Item -ItemType Directory -Path $distRoot -Force | Out-Null
$stagingRoot = Join-Path $distRoot (".gateway-staging-" + [guid]::NewGuid().ToString("N"))
$windowsStage = Join-Path $stagingRoot "can_gateway"
$linuxStage = Join-Path $stagingRoot "can_gateway_linux"
$smokeRoot = Join-Path $stagingRoot "smoke"
New-Item -ItemType Directory -Path $stagingRoot | Out-Null

try {
    if ($selectedPlatforms -contains "windows") {
        Invoke-NativeChecked -FilePath "python" -Arguments @(
            (Join-Path $repoRoot "tools\can_gateway\build_exe.py"),
            "--skip-web-build", "--dist-dir", $windowsStage
        ) -Name "Build Windows Gateway"
        Assert-PackageLayout -PackageRoot $windowsStage `
            -RequiredFiles @("gateway.exe", "dbc/can3.sy135c.dbc", "dbc/can4.sy135c.dbc") `
            -AllowedFiles @("gateway.exe", "build-manifest.json")
        if (-not $SkipSmoke) {
            Invoke-NativeChecked -FilePath "python" -Arguments @(
                $frozenSmokeTool, (Join-Path $windowsStage "gateway.exe")
            ) -Name "Smoke Windows frozen Gateway Web and DBCs"
        }
        Invoke-NativeChecked -FilePath "python" -Arguments @(
            $manifestTool, "--output", (Join-Path $windowsStage "build-manifest.json"),
            "--artifact-root", "gateway-windows=$windowsStage"
        ) -Name "Write Windows Gateway manifest"
    }

    if ($selectedPlatforms -contains "linux") {
        $wslRepoRoot = (& wsl.exe wslpath -a $repoRoot.Replace("\", "/")).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($wslRepoRoot)) {
            throw "Unable to resolve the repository path inside WSL"
        }
        $wslLinuxStage = (& wsl.exe wslpath -a $linuxStage.Replace("\", "/")).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($wslLinuxStage)) {
            throw "Unable to resolve the Linux staging path inside WSL"
        }
        $wslSmokeRoot = (& wsl.exe wslpath -a $smokeRoot.Replace("\", "/")).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($wslSmokeRoot)) {
            throw "Unable to resolve the smoke output path inside WSL"
        }
        foreach ($value in @($wslRepoRoot, $wslLinuxStage, $wslSmokeRoot)) {
            if ($value.Contains("'")) { throw "WSL build path contains an unsupported quote: $value" }
        }
        $linuxBuildCommand = @"
export PATH="`$HOME/.local/share/fnm/aliases/default/bin:`$HOME/.local/bin:`$PATH"
cd '$wslRepoRoot/tools/can_gateway'
./dist_linux.sh --skip-web-build --dist-dir '$wslLinuxStage' --build-dir "`$HOME/.cache/excavatorsim/can-gateway-build" --keep-build-dir
"@
        Invoke-NativeChecked -FilePath "wsl.exe" -Arguments @("bash", "-lc", $linuxBuildCommand) `
            -Name "Build Linux Gateway in WSL"
        Assert-PackageLayout -PackageRoot $linuxStage `
            -RequiredFiles @(
                "gateway", "can0-setup-helper", "install_can0_helper.sh",
                "uninstall_can0_helper.sh", "dbc/can3.sy135c.dbc", "dbc/can4.sy135c.dbc"
            ) `
            -AllowedFiles @(
                "gateway", "can0-setup-helper", "install_can0_helper.sh",
                "uninstall_can0_helper.sh", "build-manifest.json"
        )
        if (-not $SkipSmoke) {
            $udpProbe = [Net.Sockets.UdpClient]::new(0)
            $linuxSmokePort = ([Net.IPEndPoint]$udpProbe.Client.LocalEndPoint).Port
            $udpProbe.Close()
            $linuxSmokeCommand = @"
set -e
'$wslLinuxStage/gateway' --sink csv --max-rows 10 --host 127.0.0.1 --port '$linuxSmokePort' --out '$wslSmokeRoot/linux'
bash -n '$wslLinuxStage/install_can0_helper.sh'
bash -n '$wslLinuxStage/uninstall_can0_helper.sh'
"@
            Invoke-NativeChecked -FilePath "wsl.exe" -Arguments @("bash", "-lc", $linuxSmokeCommand) `
                -Name "Smoke Linux packaged Gateway"
        }
        Invoke-NativeChecked -FilePath "python" -Arguments @(
            $manifestTool, "--output", (Join-Path $linuxStage "build-manifest.json"),
            "--artifact-root", "gateway-linux=$linuxStage"
        ) -Name "Write Linux Gateway manifest"
    }

    $installPackages = @()
    if ($selectedPlatforms -contains "windows") {
        Preserve-RuntimeResidue -PackageRoot $windowsTarget -Label "gateway-windows"
        $installPackages += @{ Staged = $windowsStage; Target = $windowsTarget }
    }
    if ($selectedPlatforms -contains "linux") {
        Preserve-RuntimeResidue -PackageRoot $linuxTarget -Label "gateway-linux"
        $installPackages += @{ Staged = $linuxStage; Target = $linuxTarget }
    }
    Install-StagedPackages -Packages $installPackages
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-TreeWithRetry -Path $stagingRoot
    }
}

Write-Host "Gateway distribution complete:"
if ($selectedPlatforms -contains "windows") { Write-Host "  Windows: $windowsTarget" }
if ($selectedPlatforms -contains "linux") { Write-Host "  Linux:   $linuxTarget" }
