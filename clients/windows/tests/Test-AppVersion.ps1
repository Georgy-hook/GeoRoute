#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
. (Join-Path $root 'AppVersion.ps1')
Add-Type -AssemblyName PresentationFramework
[xml]$xaml=[IO.File]::ReadAllText((Join-Path $root 'Window.xaml'))
$reader=[Xml.XmlNodeReader]::new($xaml)
$window=[Windows.Markup.XamlReader]::Load($reader)
$ui=@{AppVersionText=$window.FindName('AppVersionText');AppBuildText=$window.FindName('AppBuildText')}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('GeoRoute-version-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture)|Out-Null
try {
    Initialize-GeoRouteVersion $fixture $ui
    if($ui.AppVersionText.Text -ne 'Версия не указана'){throw 'Missing manifest must not invent a version.'}
    $path=Join-Path $fixture 'app-version.json'
    [IO.File]::WriteAllText($path,'{"version":"9.8.7","revision":"0123456789abcdef0123456789abcdef01234567","builtAtUtc":"2026-11-23T10:00:00Z","modified":false}')
    Initialize-GeoRouteVersion $fixture $ui
    if($ui.AppVersionText.Text -ne 'Версия 9.8.7' -or $ui.AppBuildText.Text -notmatch '01234567' -or $ui.AppBuildText.Text -notmatch '23.11.2026'){throw 'Settings must display the package version and build.'}
    [IO.File]::WriteAllText($path,'{"version":"bad"}')
    Initialize-GeoRouteVersion $fixture $ui
    if($ui.AppVersionText.Text -ne 'Версия не указана'){throw 'Invalid version must reset the UI.'}
    [IO.File]::WriteAllText($path,'{invalid')
    Initialize-GeoRouteVersion $fixture $ui
    if($ui.AppBuildText.Text -ne 'Данные сборки недоступны'){throw 'Corrupt manifest must not break Settings.'}
    Write-Output 'App version: package metadata, actual WPF controls and invalid/missing fallback passed.'
} finally {
    $window.Close()
    if([IO.Path]::GetFullPath($fixture).StartsWith(([IO.Path]::GetTempPath().TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $fixture -Leaf) -match '^GeoRoute-version-[a-f0-9]{32}$'){Remove-Item -LiteralPath $fixture -Recurse -Force}
}
