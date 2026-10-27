#Requires -Version 5.1
<#
.SYNOPSIS
Build the combined PinPin Windows app without launching it.
.EXAMPLE
  .\scripts\build-windows.ps1 -RunChecks
.EXAMPLE
  .\scripts\build-windows.ps1 -VerifyCleanupSafety
.EXAMPLE
  .\scripts\build-windows.ps1 -DotnetPath C:\Tools\dotnet\dotnet.exe -SelfContained
#>
[CmdletBinding()]
param(
    [string]$DotnetPath = 'dotnet',
    [ValidateSet('win-x64', 'win-arm64')][string]$Runtime = 'win-x64',
    [switch]$SelfContained,
    [switch]$RunChecks,
    [switch]$VerifyCleanupSafety
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$backendRoot = Join-Path $repoRoot 'backend'
$frontendRoot = Join-Path $repoRoot 'frontend'
$windowsRoot = Join-Path $backendRoot 'platforms/windows'
$appProject = Join-Path $windowsRoot 'PinPin.App/PinPin.App.csproj'
$presentationProject = Join-Path $frontendRoot 'windows/PinPin.Presentation/PinPin.Presentation.csproj'
$buildRoot = Join-Path $repoRoot '.build/windows'
$stagePath = Join-Path $buildRoot 'package-staging'
$packagePath = Join-Path $buildRoot 'package'
$markerName = '.pinpin-package-owner'
$markerValue = 'PinPin public Windows build v1'
$manifestName = '.pinpin-package-manifest.json'
$script:packageProcessProvider = { @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop) }
$properties = @("-p:PinPinBackendRoot=$backendRoot", "-p:PinPinFrontendRoot=$frontendRoot")

function Invoke-Dotnet([string[]]$Arguments) {
    & $dotnet @Arguments
    if ($LASTEXITCODE -ne 0) { throw "dotnet failed with exit code $LASTEXITCODE." }
}

function Get-PackageTree([string]$Path) {
    # Enumerate one level at a time, rejecting links before entering any directory.
    $pending = New-Object 'System.Collections.Generic.Queue[string]'
    $pending.Enqueue($Path)
    while ($pending.Count -gt 0) {
        $directory = $pending.Dequeue()
        $rootItem = Get-Item -LiteralPath $directory -Force
        if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Preserved linked package path: $directory"
        }
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Preserved package containing a reparse point: $($item.FullName)"
            }
            $item
            if ($item.PSIsContainer) { $pending.Enqueue($item.FullName) }
        }
    }
}

function Get-PackageRelativePath([string]$Path, [string]$Base) {
    $prefix = [IO.Path]::GetFullPath($Base).TrimEnd([char[]]"\/") + [IO.Path]::DirectorySeparatorChar
    return $Path.Substring($prefix.Length).Replace('\', '/')
}

function Assert-PackageSafe([string]$Path, [switch]$Published) {
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) { throw "Expected a package directory: $Path" }
    $items = @(Get-PackageTree $Path)
    $marker = Join-Path $Path $markerName
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or
        (Get-Content -LiteralPath $marker -Raw).Trim() -ne $markerValue) {
        throw "Preserved unowned package directory: $Path"
    }
    $userNames = @('Data', 'portable', 'userdata', 'user-data', 'gateway.dpapi', 'appearance.json',
        'wheel-settings.json', 'assets.json', 'host-errors.jsonl', 'gateway-configuration.json',
        'gateway-status.json', 'host-ready.json', 'host-stopped.json', 'credentials.json',
        'config.json', 'settings.json', 'preferences.json', '.env')
    foreach ($entry in $items) {
        $configurationFile = $entry.Extension -in @('.dpapi', '.db', '.sqlite', '.sqlite3', '.ini', '.toml', '.yaml', '.yml', '.jsonl', '.config') -or
            ($entry.Extension -eq '.json' -and $entry.Name -ne $manifestName -and
             $entry.Name -notlike '*.deps.json' -and $entry.Name -notlike '*.runtimeconfig.json')
        if ($entry.Name -in $userNames -or $configurationFile) {
            throw "Preserved possible user data: $($entry.FullName). Keep daily-use apps outside the build tree; user data is never moved or deleted."
        }
    }
    if ($Published) {
        $manifestFile = Join-Path $Path $manifestName
        if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) {
            throw "Preserved package without a generated file manifest: $Path"
        }
        $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
        if ($manifest.version -ne 1) { throw "Preserved unknown package manifest: $manifestFile" }
        $expectedFiles = @{}
        foreach ($file in $manifest.files) {
            if ($expectedFiles.ContainsKey($file.path)) { throw 'Preserved invalid duplicate manifest entry.' }
            $expectedFiles[$file.path] = $file.sha256
        }
        $actualFiles = @($items | Where-Object { -not $_.PSIsContainer -and $_.FullName -ne (Join-Path $Path $manifestName) })
        if ($actualFiles.Count -ne $expectedFiles.Count) { throw "Preserved package with added/missing files: $Path" }
        foreach ($file in $actualFiles) {
            $relative = Get-PackageRelativePath $file.FullName $Path
            if (-not $expectedFiles.ContainsKey($relative) -or
                (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $expectedFiles[$relative]) {
                throw "Preserved changed package file: $($file.FullName)"
            }
        }
        $actualDirectories = @($items | Where-Object PSIsContainer | ForEach-Object { Get-PackageRelativePath $_.FullName $Path } | Sort-Object)
        $expectedDirectories = @($manifest.directories | Sort-Object)
        if (($actualDirectories -join "`n") -cne ($expectedDirectories -join "`n")) {
            throw "Preserved package with changed directories: $Path"
        }
    }
    $prefix = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]"\/") + [IO.Path]::DirectorySeparatorChar
    $exeNames = @($items | Where-Object { -not $_.PSIsContainer -and $_.Extension -eq '.exe' } | ForEach-Object Name)
    foreach ($process in @(& $script:packageProcessProvider)) {
        if ($process.ExecutablePath) {
            if ([IO.Path]::GetFullPath($process.ExecutablePath).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Preserved active package: process $($process.ProcessId) runs $($process.ExecutablePath). Close it yourself; this script never kills processes."
            }
        } elseif ($process.Name -in $exeNames) {
            throw "Preserved package because the path of process $($process.ProcessId) ($($process.Name)) could not be inspected."
        }
    }
}

function Write-PackageManifest([string]$Path) {
    Assert-PackageSafe $Path
    $items = @(Get-PackageTree $Path)
    $files = @($items | Where-Object { -not $_.PSIsContainer -and $_.FullName -ne (Join-Path $Path $manifestName) } | ForEach-Object {
        [ordered]@{ path = (Get-PackageRelativePath $_.FullName $Path); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    })
    $directories = @($items | Where-Object PSIsContainer | ForEach-Object { Get-PackageRelativePath $_.FullName $Path })
    [ordered]@{ version = 1; files = $files; directories = $directories } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Path $manifestName) -Encoding UTF8
}

function Remove-OwnedPackage([string]$Path, [switch]$Published) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Assert-PackageSafe $Path -Published:$Published
    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Test-CleanupSafety {
    # Only this newly-created synthetic fixture is disposable; no package or SDK is used.
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('pinpin-cleanup-check-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fixture | Out-Null
    $sample = Join-Path $fixture 'sample'
    $junction = Join-Path $sample 'link'
    $script:packageProcessProvider = { @() }
    $checks = 0
    function Expect-Preserved([scriptblock]$Action) {
        $blocked = $false
        try { & $Action } catch { $blocked = $true }
        if (-not $blocked -or -not (Test-Path -LiteralPath $sample)) { throw 'Cleanup safety check failed.' }
    }
    try {
        New-Item -ItemType Directory -Path $sample | Out-Null
        Set-Content -LiteralPath (Join-Path $sample $markerName) -Value $markerValue -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $sample 'PinPin.exe') -Value 'synthetic, never executable' -Encoding ASCII
        Write-PackageManifest $sample
        Assert-PackageSafe $sample -Published
        $checks++
        foreach ($name in @('Data', 'portable')) {
            $data = New-Item -ItemType Directory -Path (Join-Path $sample $name)
            Expect-Preserved { Remove-OwnedPackage $sample }
            Remove-Item -LiteralPath $data.FullName
            $checks++
        }
        foreach ($name in @('appearance.json', 'extra-user-file.txt')) {
            $extra = Join-Path $sample $name
            Set-Content -LiteralPath $extra -Value 'synthetic'
            Expect-Preserved { Remove-OwnedPackage $sample -Published }
            Remove-Item -LiteralPath $extra
            $checks++
        }
        Add-Content -LiteralPath (Join-Path $sample 'PinPin.exe') -Value 'modified'
        Expect-Preserved { Remove-OwnedPackage $sample -Published }
        Set-Content -LiteralPath (Join-Path $sample 'PinPin.exe') -Value 'synthetic, never executable' -Encoding ASCII
        $checks++
        $empty = New-Item -ItemType Directory -Path (Join-Path $sample 'extra-empty-directory')
        Expect-Preserved { Remove-OwnedPackage $sample -Published }
        Remove-Item -LiteralPath $empty.FullName
        $checks++
        $script:packageProcessProvider = { @([pscustomobject]@{ ExecutablePath = (Join-Path $sample 'PinPin.exe'); Name = 'PinPin.exe'; ProcessId = 12345 }) }
        Expect-Preserved { Remove-OwnedPackage $sample -Published }
        $script:packageProcessProvider = { @([pscustomobject]@{ ExecutablePath = $null; Name = 'PinPin.exe'; ProcessId = 12345 }) }
        Expect-Preserved { Remove-OwnedPackage $sample -Published }
        $script:packageProcessProvider = { @() }
        $checks += 2
        $target = New-Item -ItemType Directory -Path (Join-Path $fixture 'target')
        New-Item -ItemType Junction -Path $junction -Target $target.FullName | Out-Null
        try { Expect-Preserved { Remove-OwnedPackage $sample -Published }; $checks++ }
        finally { [IO.Directory]::Delete($junction) }
        Remove-Item -LiteralPath (Join-Path $sample $manifestName)
        Expect-Preserved { Remove-OwnedPackage $sample -Published }
        $checks++
        Write-PackageManifest $sample
        Remove-OwnedPackage $sample -Published
        if (Test-Path -LiteralPath $sample) { throw 'Clean synthetic package was not removed.' }
        $checks++
        Write-Host "PASS $checks synthetic cleanup checks; process records mocked, no app launched."
    } finally {
        # The only tree here is the fixture created above, containing synthetic test files.
        # Never traverse a leftover junction during fixture cleanup.
        if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction) }
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}

if ($env:OS -ne 'Windows_NT') { throw 'Build/check on Windows with PowerShell 5.1 or later.' }
if ($VerifyCleanupSafety) { Test-CleanupSafety; return }
foreach ($project in @($appProject, $presentationProject)) {
    if (-not (Test-Path -LiteralPath $project -PathType Leaf)) { throw "Missing project: $project" }
}
$dotnet = (Get-Command $DotnetPath -CommandType Application -ErrorAction Stop).Source
$sdkVersion = & $dotnet --version
if ($LASTEXITCODE -ne 0 -or "$sdkVersion" -notmatch '^10\.') {
    throw "The active SDK must be .NET 10. Current: $sdkVersion. Install/use .NET 10 or pass -DotnetPath."
}

# Generated output stays in one tree; no timestamps, copied dependencies or persistent run logs.
foreach ($path in @((Join-Path $repoRoot '.build'), $buildRoot)) {
    if (Test-Path -LiteralPath $path) {
        if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Build output must be a local directory, not a link: $path"
        }
    } else { New-Item -ItemType Directory -Path $path | Out-Null }
}
$buildLock = $null
$testRoot = $null
try {
    Write-Host 'Keep daily-use apps outside .build/windows. Existing user data is preserved; this script never moves data or kills apps.'
    # Prevent two copies of this script from deleting or publishing each other's package.
    $buildLock = [IO.File]::Open((Join-Path $buildRoot '.build.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    if (Test-Path -LiteralPath $packagePath) { Assert-PackageSafe $packagePath -Published }
    if ($RunChecks) {
        $newTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('pinpin-checks-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $newTestRoot | Out-Null
        $testRoot = $newTestRoot
        foreach ($name in @('PinPin.Core.Tests', 'PinPin.Native.Tests', 'PinPin.App.Tests')) {
            $project = Join-Path $windowsRoot "$name/$name.csproj"
            $arguments = @('run', '--project', $project, '--configuration', 'Release') + $properties
            if ($name -eq 'PinPin.App.Tests') { $arguments += @('--', $testRoot) }
            Invoke-Dotnet $arguments
        }
    }
    Remove-OwnedPackage $stagePath
    New-Item -ItemType Directory -Path $stagePath | Out-Null
    Set-Content -LiteralPath (Join-Path $stagePath $markerName) -Value $markerValue -Encoding ASCII
    $contained = if ($SelfContained) { 'true' } else { 'false' }
    Invoke-Dotnet (@('publish', $appProject, '--configuration', 'Release', '--runtime', $Runtime,
        '--self-contained', $contained, '--output', $stagePath, '-p:PublishSingleFile=false') + $properties)
    if (-not (Test-Path -LiteralPath (Join-Path $stagePath 'PinPin.exe') -PathType Leaf)) {
        throw 'Publish returned without PinPin.exe.'
    }
    Write-PackageManifest $stagePath
    Remove-OwnedPackage $packagePath -Published
    Move-Item -LiteralPath $stagePath -Destination $packagePath
    Write-Host "Package: $packagePath"
    Write-Host "Share the entire package folder. Runtime: $Runtime; self-contained: $contained."
    if (-not $SelfContained) { Write-Host 'Users need the matching .NET 10 Desktop Runtime.' }
} finally {
    try {
        if ($null -ne $testRoot -and (Test-Path -LiteralPath $testRoot)) {
            Remove-Item -LiteralPath $testRoot -Recurse -Force
        }
    } finally {
        if ($null -ne $buildLock) {
            try { Remove-OwnedPackage $stagePath } finally { $buildLock.Dispose() }
        }
    }
}
