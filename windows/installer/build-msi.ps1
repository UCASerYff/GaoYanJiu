param(
    [Parameter(Mandatory = $true)][string]$Python,
    [Parameter(Mandatory = $true)][string]$WorkDirectory,
    [Parameter(Mandatory = $true)][string]$DistributionDirectory,
    [Parameter(Mandatory = $true)][string]$PayloadDirectory,
    [Parameter(Mandatory = $true)][string]$MarketingVersion,
    [Parameter(Mandatory = $true)][string]$BuildNumber,
    [Parameter(Mandatory = $true)][string]$IconFile,
    [Parameter(Mandatory = $true)][string]$NoticeFile
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $WorkDirectory | Out-Null
$archive = Join-Path $WorkDirectory 'wix314-binaries.zip'
if (-not (Test-Path -LiteralPath $archive)) {
    $download = "$archive.part"
    try {
        Invoke-WebRequest -Uri 'https://github.com/wixtoolset/wix3/releases/download/wix3141rtm/wix314-binaries.zip' `
            -UseBasicParsing -OutFile $download
        Move-Item -LiteralPath $download -Destination $archive
    } finally {
        if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download -Force }
    }
}
$expected = '6AC824E1642D6F7277D0ED7EA09411A508F6116BA6FAE0AA5F2C7DAA2FF43D31'
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expected) {
    throw "WiX 3.14.1 failed its SHA-256 check. Remove $archive and rebuild."
}
$wix = Join-Path $WorkDirectory 'wix3141'
if (-not (Test-Path -LiteralPath (Join-Path $wix 'light.exe'))) {
    Expand-Archive -LiteralPath $archive -DestinationPath $wix -Force
}

$version = "$MarketingVersion.$BuildNumber"
$productId = & $Python -c 'import sys, uuid; print(uuid.uuid5(uuid.NAMESPACE_URL, "com.academic-achievement.manager/windows-x64/" + sys.argv[1]))' $version
if ($LASTEXITCODE -ne 0) { throw 'Could not derive the MSI product identifier' }
$source = Join-Path $PSScriptRoot 'GaoYanJiu.wxs'
$object = Join-Path $WorkDirectory 'GaoYanJiu.wixobj'
$fileName = "GaoYanJiu-Windows-$MarketingVersion-x64.msi"
$package = Join-Path $DistributionDirectory $fileName

& (Join-Path $wix 'candle.exe') -nologo -arch x64 -out $object "-dPayloadDir=$PayloadDirectory" "-dIconFile=$IconFile" `
    "-dNoticeFile=$NoticeFile" "-dDisplayVersion=$MarketingVersion" "-dProductVersion=$version" "-dProductCode=$productId" $source
if ($LASTEXITCODE -ne 0) { throw "WiX candle failed with exit code $LASTEXITCODE" }
& (Join-Path $wix 'light.exe') -nologo -cultures:zh-cn -ext (Join-Path $wix 'WixUIExtension.dll') -spdb -out $package $object
if ($LASTEXITCODE -ne 0) { throw "WiX light failed with exit code $LASTEXITCODE" }

$checksum = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$package.sha256" -Value "$checksum  $fileName" -Encoding ascii
Get-Item -LiteralPath $package, "$package.sha256" | Select-Object FullName, Length
