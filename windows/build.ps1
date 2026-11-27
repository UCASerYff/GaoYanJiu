param(
    [string]$Python = "python",
    [string]$DistributionDirectory = "",
    [switch]$SkipDependencyInstall
)

$ErrorActionPreference = "Stop"
$outputPath = if ($DistributionDirectory) { [IO.Path]::GetFullPath($DistributionDirectory) } else { Join-Path $PSScriptRoot 'dist' }
Set-Location -LiteralPath $PSScriptRoot
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONUTF8 = "1"
$env:PYTHONPATH = Join-Path $PSScriptRoot 'src'
$env:PYINSTALLER_CONFIG_DIR = Join-Path $PSScriptRoot 'build\pyinstaller-cache'

function Assert-LastExit($step) {
    if ($LASTEXITCODE -ne 0) { throw "$step failed with exit code $LASTEXITCODE" }
}

& $Python -c 'import platform, struct, sys; assert sys.platform == "win32" and platform.machine() == "AMD64" and struct.calcsize("P") == 8 and sys.version_info[:2] == (3, 12), "A native Windows x64 Python 3.12 is required"'
Assert-LastExit 'Windows x64 check'
if (-not $SkipDependencyInstall) {
    & $Python -m pip install --disable-pip-version-check -r requirements-dev.txt
    Assert-LastExit 'pip install'
}
& $Python -m pytest -q
Assert-LastExit 'pytest'

$version = & $Python -c 'from gaoyanjiu import __version__; print(__version__)'
Assert-LastExit 'version'
$buildNumber = & $Python -c 'from gaoyanjiu import __build__; print(__build__)'
Assert-LastExit 'build number'
$buildDir = (New-Item -ItemType Directory -Force -Path 'build').FullName
$distDir = (New-Item -ItemType Directory -Force -Path $outputPath).FullName
$assets = Join-Path $PSScriptRoot 'src\gaoyanjiu\assets'
$macResources = Join-Path (Split-Path -Parent $PSScriptRoot) 'Resources'
$iconPng = Join-Path $macResources 'AcademicAchievementManagerIcon.png'
$icon = Join-Path $buildDir 'GaoYanJiu.ico'
$versionInfo = Join-Path $buildDir 'version-info.txt'
$licenseFile = Join-Path $buildDir 'ThirdPartyNotices.txt'

& "$PSScriptRoot\installer\create-icon.ps1" -Source $iconPng -OutputPath $icon
& $Python "$PSScriptRoot\installer\build-metadata.py" $version $buildNumber $versionInfo $licenseFile
Assert-LastExit 'version information and runtime notices'
$portalDir = Join-Path $buildDir 'portal'
& "$PSScriptRoot\installer\build-portal.ps1" -WorkDirectory (Join-Path $buildDir 'portal-sdk') `
    -OutputDirectory $portalDir -IconFile $icon -MarketingVersion $version -BuildNumber $buildNumber
$portalNotice = Get-Content -LiteralPath (Join-Path $portalDir 'WebView2-LICENSE.txt') -Raw
$portalThirdParty = Get-Content -LiteralPath (Join-Path $portalDir 'WebView2-NOTICE.txt') -Raw
Add-Content -LiteralPath $licenseFile -Value "`n`nMicrosoft Edge WebView2 SDK`n===========================`n`n$portalNotice`n`n$portalThirdParty" -Encoding utf8

$resourcePaths = @(
    $assets, $iconPng, (Join-Path $macResources 'extractor.js'),
    (Join-Path $macResources 'RewardCity\FloatingRockV354.png'),
    (Join-Path $macResources 'RewardCity\FloatingSkyV354.png'),
    (Join-Path $macResources 'RewardCity\grass-3d-texture.png'),
    (Join-Path $macResources 'RewardCity\FloatingIslandV354-source.txt')
)
$common = @('--noconfirm', '--clean', '--onefile', '--paths', 'src', '--distpath', $distDir,
            '--icon', $icon, '--version-file', $versionInfo)
foreach ($path in $resourcePaths) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing application asset: $path" }
    $common += '--add-data', "$path;gaoyanjiu_assets"
}
$common += '--add-data', "$portalDir;gaoyanjiu_assets/portal"
& $Python -m PyInstaller @common --name GaoYanJiu-cli --console --workpath build/cli --specpath build/cli launch.py
Assert-LastExit 'PyInstaller CLI'
& $Python -m PyInstaller @common --name GaoYanJiu --windowed --workpath build/gui --specpath build/gui launch.py
Assert-LastExit 'PyInstaller GUI'

& "$PSScriptRoot\installer\build-msi.ps1" -Python $Python -WorkDirectory (Join-Path $buildDir 'installer') `
    -DistributionDirectory $distDir -MarketingVersion $version -BuildNumber $buildNumber `
    -PayloadDirectory $distDir -IconFile $icon -NoticeFile $licenseFile
