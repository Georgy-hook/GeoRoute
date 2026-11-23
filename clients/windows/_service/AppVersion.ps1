#Requires -Version 5.1
function Get-GeoRouteVersion([string]$Root) {
    $result=[pscustomobject]@{VersionText='Версия не указана';BuildText='Данные сборки недоступны'}
    try {
        $info=Get-Content -LiteralPath (Join-Path $Root 'app-version.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if([string]$info.version -notmatch '^\d+\.\d+\.\d+$'){return $result}
        $result.VersionText='Версия '+$info.version
        $parts=@()
        if([string]$info.revision -match '^[a-f0-9]{40}$'){$parts+=('Сборка '+$info.revision.Substring(0,8))}
        if($info.builtAtUtc){$date=[DateTimeOffset]::Parse([string]$info.builtAtUtc,[Globalization.CultureInfo]::InvariantCulture);$parts+=$date.ToLocalTime().ToString('dd.MM.yyyy HH:mm')}
        if($info.modified -eq $true){$parts+='Локальные изменения'}
        $result.BuildText=if($parts.Count){$parts -join ' · '}else{'Исходная сборка'}
    } catch { }
    return $result
}

function Initialize-GeoRouteVersion([string]$Root,$Ui) {
    $version=Get-GeoRouteVersion $Root
    $Ui.AppVersionText.Text=$version.VersionText
    $Ui.AppBuildText.Text=$version.BuildText
}
