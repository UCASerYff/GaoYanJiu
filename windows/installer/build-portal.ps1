param(
    [Parameter(Mandatory = $true)][string]$WorkDirectory,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true)][string]$IconFile,
    [Parameter(Mandatory = $true)][string]$MarketingVersion,
    [Parameter(Mandatory = $true)][string]$BuildNumber
)

$ErrorActionPreference = 'Stop'
$version = '1.0.3912.50'
$expectedHash = '8DD696301D8E5AD8389F26B636329BBF35754B793974E82168B1F6DDA234EB07'
$uri = "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$version/microsoft.web.webview2.$version.nupkg"
New-Item -ItemType Directory -Force -Path $WorkDirectory, $OutputDirectory | Out-Null
$archive = Join-Path $WorkDirectory "Microsoft.Web.WebView2.$version.zip"
if (-not (Test-Path -LiteralPath $archive)) {
    $download = "$archive.part"
    try {
        Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 75 -OutFile $download
        if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $expectedHash) {
            throw 'The downloaded Microsoft WebView2 SDK did not match its locked SHA-256.'
        }
        Move-Item -LiteralPath $download -Destination $archive
    } finally {
        if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download -Force }
    }
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expectedHash) {
    throw "Microsoft WebView2 SDK failed its SHA-256 check. Remove $archive and rebuild."
}
$sdk = Join-Path $WorkDirectory 'sdk'
$lib = Join-Path $sdk 'lib\net462'
$managedNames = @('Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.WinForms.dll')
$native = Join-Path $sdk 'runtimes\win-x64\native\WebView2Loader.dll'
$license = Join-Path $sdk 'LICENSE.txt'
$notice = Join-Path $sdk 'NOTICE.txt'
Expand-Archive -LiteralPath $archive -DestinationPath $sdk -Force
if ($MarketingVersion -notmatch '^\d+\.\d+$' -or $BuildNumber -notmatch '^\d+$') {
    throw 'Invalid version fields for the native portal.'
}
$versionInfo = Join-Path $WorkDirectory 'PortalVersion.cs'
@(
    'using System.Reflection;',
    '[assembly: AssemblyTitle("GaoYanJiu Portal")]',
    '[assembly: AssemblyProduct("GaoYanJiu")]',
    "[assembly: AssemblyVersion(""$MarketingVersion.$BuildNumber.0"")]",
    "[assembly: AssemblyFileVersion(""$MarketingVersion.$BuildNumber.0"")]",
    "[assembly: AssemblyInformationalVersion(""$MarketingVersion+$BuildNumber"")]"
) | Set-Content -LiteralPath $versionInfo -Encoding UTF8
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The x64 .NET Framework 4.x C# compiler is required.' }
$sources = Join-Path $PSScriptRoot 'portal'
$exe = Join-Path $OutputDirectory 'GaoYanJiu-Portal.exe'
$manifest = Join-Path $sources 'Portal.manifest'
$compilerArguments = @('/nologo', '/utf8output', '/langversion:5', '/target:winexe', '/platform:x64', '/optimize+',
    "/out:$exe", "/win32icon:$IconFile", "/win32manifest:$manifest",
    '/reference:System.Windows.Forms.dll', '/reference:System.Drawing.dll', '/reference:System.Web.Extensions.dll')
$compilerArguments += @($managedNames | ForEach-Object { '/reference:' + (Join-Path $lib $_) })
$compilerArguments += (Join-Path $sources 'PortalWindow.cs'), $versionInfo
& $compiler @compilerArguments
if ($LASTEXITCODE -ne 0) { throw "WebView2 portal helper compilation failed with exit code $LASTEXITCODE." }
foreach ($name in $managedNames) { Copy-Item -LiteralPath (Join-Path $lib $name) -Destination $OutputDirectory -Force }
Copy-Item -LiteralPath $native -Destination $OutputDirectory -Force
Copy-Item -LiteralPath $license -Destination (Join-Path $OutputDirectory 'WebView2-LICENSE.txt') -Force
Copy-Item -LiteralPath $notice -Destination (Join-Path $OutputDirectory 'WebView2-NOTICE.txt') -Force
