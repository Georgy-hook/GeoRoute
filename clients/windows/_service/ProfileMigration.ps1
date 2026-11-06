#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'ProfileCreation.ps1')

function Write-GeoMigrationFile([string]$Path,[string]$Text) {
    $temporary=$Path+'.unified-'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temporary,$Text,[Text.UTF8Encoding]::new($false))
        if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temporary,$Path,[NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}
    } finally {if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}
function Update-GeoRouteBundledProfiles([string]$Root) {
    $catalogPath=Join-Path $Root 'profiles.json'
    if(-not(Test-Path -LiteralPath $catalogPath)){return}
    $catalog=Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8|ConvertFrom-Json
    if($catalog.PSObject.Properties['UnifiedGeoHideVersion'] -and $catalog.UnifiedGeoHideVersion -ge 1){return}
    $settingsPath=Join-Path $Root 'geohide-settings.json'
    $settings=if(Test-Path -LiteralPath $settingsPath){Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8|ConvertFrom-Json}else{[pscustomobject]@{}}
    $fallback=@{US='192.255.159.240';EU='31.25.239.132';RU='159.194.200.33'}
    foreach($region in @('US','EU','RU')){
        $key=$region.ToLowerInvariant()
        try{if($settings.PSObject.Properties[$key]){$fallback[$region]=Convert-GeoProfileAddress ([string]$settings.$key)}}catch{}
    }
    $updates=@();$paths=@{}
    foreach($entry in $catalog.Profiles){
        $combined=$entry.id -eq 'us-eu' -or $entry.name -match '^(US|США).*(EU|Европ)'
        if(-not $combined -and $entry.id -notin @('primary','alternate','eu-primary','eu-alternate','ru-primary')){continue}
        $relative=[string]$entry.hostsFile
        if($relative -notmatch '^profiles[\\/][a-zA-Z0-9_-]+\.hosts$'){throw 'Некорректный путь встроенного профиля.'}
        $path=[IO.Path]::GetFullPath((Join-Path $Root $relative))
        foreach($candidate in @((Split-Path $path -Parent),$path)){
            if((Test-Path -LiteralPath $candidate) -and ((Get-Item -LiteralPath $candidate).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Профиль не должен проходить через ссылку файловой системы.'}
        }
        $old=if(Test-Path -LiteralPath $path){[IO.File]::ReadAllText($path)}else{''}
        $records=@(foreach($line in ($old -split '\r?\n')){
            $parts=($line -split '#',2)[0].Trim() -split '\s+'
            if($parts.Count -lt 2){continue}
            foreach($domain in $parts[1..($parts.Count-1)]){
                if((Test-GeoGeminiDomain $domain) -or $domain -match '^(?:[a-z0-9-]+\.)*(?:chatgpt\.com|openai\.com|oaistatic\.com|oaiusercontent\.com)$'){
                    [pscustomobject]@{Address=$parts[0];Domain=$domain.ToLowerInvariant()}
                }
            }
        })
        $region=if($entry.id.StartsWith('eu-')){'EU'}elseif($entry.id -eq 'ru-primary'){'RU'}else{'US'}
        $ip=$fallback[$region]
        if($entry.id -eq 'alternate'){$ip=if($fallback.US -ne '192.3.233.253'){'192.3.233.253'}else{'192.255.159.241'}}
        if($entry.id -eq 'eu-alternate'){$ip=@(@('31.25.239.132','37.221.93.141')|Where-Object {$_ -ne $fallback.EU})[0]}
        # Repair legacy invalid metadata (such as a single character) from real hosts rows.
        foreach($candidate in @($entry.address)+@($records|ForEach-Object Address)){
            try{$ip=Convert-GeoProfileAddress ([string]$candidate);break}catch{}
        }
        $base=New-GeoServiceHosts $ip GeoHide
        # The monitor adds Google's shared frontend only after a successful probe.
        $domains=@((($base -split '\r?\n')|Where-Object {$_ -notmatch '^#' -and $_.Trim()}|ForEach-Object {($_ -split '\s+')[1]})+@($records|ForEach-Object Domain)|Where-Object {$_ -ne 'www.google.com'}|Sort-Object -Unique)
        if($combined){
            $us=$fallback.US;$eu=$fallback.EU
            foreach($pair in @(@('chatgpt.com','us'),@('files.oaiusercontent.com','eu'))){
                $row=@($records|Where-Object Domain -eq $pair[0]|Select-Object -First 1)
                if($row.Count){try{Set-Variable -Name $pair[1] -Value (Convert-GeoProfileAddress $row[0].Address) -Scope Local}catch{}}
            }
            $content=(@('# GeoHide US + EU: ChatGPT, Gemini and OpenAI attachments.')+@($domains|ForEach-Object {$(if((Test-GeoGeminiDomain $_) -or $_ -eq 'oaiusercontent.com' -or $_.EndsWith('.oaiusercontent.com')){$eu}else{$us})+' '+$_})) -join "`r`n"
            $entry.name='US + EU — ChatGPT + Gemini'
        }else{
            $content=(@('# GeoHide: ChatGPT, Gemini and OpenAI attachments.')+@($domains|ForEach-Object {$ip+' '+$_})) -join "`r`n"
            $entry|Add-Member NoteProperty address $ip -Force
            $entry.name=switch($entry.id){primary{'GeoHide US — основной'}alternate{'GeoHide US — запасной'}eu-primary{'GeoHide — основной'}eu-alternate{'GeoHide — запасной'}ru-primary{'GeoHide RU'}}
        }
        $entry|Add-Member NoteProperty domainCount $domains.Count -Force
        $entry|Add-Member NoteProperty description 'ChatGPT, Gemini и вложения OpenAI в одном профиле. Маршрут проверки Google добавляется после успешной сетевой проверки.' -Force
        $entry|Add-Member NoteProperty service 'GeoHide' -Force
        $updates+=@([pscustomobject]@{Path=$path;Text=$content+"`r`n"})
        $paths[$path]=$true
    }
    $removed=@('gemini-us','gemini-eu','25-10-12-00-08-1c6816ce')
    $catalog.Profiles=@($catalog.Profiles|Where-Object {$_.id -notin $removed})
    $catalog|Add-Member NoteProperty UnifiedGeoHideVersion 1 -Force
    $backup=Join-Path $Root ('backups\unified-geohide-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
    [IO.Directory]::CreateDirectory($backup)|Out-Null
    Copy-Item -LiteralPath $catalogPath -Destination (Join-Path $backup 'profiles.json')
    foreach($path in $paths.Keys){if(Test-Path -LiteralPath $path){Copy-Item -LiteralPath $path -Destination (Join-Path $backup ([IO.Path]::GetFileName($path)))}}
    foreach($update in $updates){Write-GeoMigrationFile $update.Path $update.Text}
    if($settings.PSObject.Properties['preferredProfileId'] -and $settings.preferredProfileId -in $removed){
        Copy-Item -LiteralPath $settingsPath -Destination (Join-Path $backup 'geohide-settings.json')
        $settings.preferredProfileId=if($settings.preferredProfileId -eq 'gemini-us'){'primary'}else{'eu-primary'}
        Write-GeoMigrationFile $settingsPath ($settings|ConvertTo-Json -Depth 15)
    }
    # Commit the schema marker last; interrupted migrations can be retried. No hosts/DNS changes.
    Write-GeoMigrationFile $catalogPath ($catalog|ConvertTo-Json -Depth 15)
}
