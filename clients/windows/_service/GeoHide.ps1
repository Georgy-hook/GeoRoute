#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'GeoAvailability.ps1')
. (Join-Path $PSScriptRoot 'ProfileMigration.ps1')
function Write-GeoJson($Path,$Value) {
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($false))
    if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temp,$Path,[NullString]::Value)}else{[IO.File]::Move($temp,$Path)}
}
function Test-GeoAddress([string]$Address) {
    if($Address -notmatch '^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$'){return $false}
    $ip=$null
    if(-not [Net.IPAddress]::TryParse($Address,[ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork'){return $false}
    $b=$ip.GetAddressBytes()
    return -not ($b[0] -in @(0,10,127) -or $b[0] -ge 224 -or ($b[0]-eq 169 -and $b[1]-eq 254) -or ($b[0]-eq 172 -and $b[1]-ge 16 -and $b[1]-le 31) -or ($b[0]-eq 192 -and $b[1]-eq 168) -or ($b[0]-eq 100 -and $b[1]-ge 64 -and $b[1]-le 127))
}
function Read-GeoSettings([string]$Root) {
    $path=Join-Path $Root 'geohide-settings.json'
    if(Test-Path -LiteralPath $path){$v=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json;if(-not $v.PSObject.Properties['ru']){$v|Add-Member -MemberType NoteProperty -Name ru -Value '159.194.200.33'};return $v}
    return [pscustomobject]@{version=1;autoSelect=$true;us='192.255.159.241';eu='143.20.64.192';ru='159.194.200.33';manualServers=@()}
}
function Get-GeoSelection($Settings,$Report) {
    $selected=[ordered]@{ready=$false}
    foreach($region in @('US','EU','RU')){
        $pool=@(Get-GeoPool $Report $region)
        if($region -eq 'EU'){$combined=@(Get-GeoPool $Report EU Combined);if($combined.Count){$pool=$combined}}
        # Prefer an endpoint without a Google challenge. Manual mode retains its saved pair.
        $unchallenged=@($pool|Where-Object {$_.GeminiReady -and -not $_.GeminiChallenge})
        if($unchallenged.Count){$pool=$unchallenged}
        $key=$region.ToLowerInvariant();$current=[string]$Settings.$key
        $selected[$key]=if(@($pool|Where-Object Address -eq $current).Count){$current}elseif($pool.Count){$pool[0].Address}else{$current}
        $selected[$key+'Ready']=$pool.Count -gt 0
    }
    $selected.ready=$selected.usReady -and $selected.euReady
    return [pscustomobject]$selected
}
function Save-GeoProfile([string]$Root,$Settings,$Report) {
    if(-not (Test-GeoAddress $Settings.us) -or -not (Test-GeoAddress $Settings.eu)){throw 'Укажите публичные IPv4 для US и EU.'}
    Update-GeoRouteBundledProfiles $Root
    $catalogPath=Join-Path $Root 'profiles.json'
    $catalog=Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8|ConvertFrom-Json
    $profile=@($catalog.Profiles|Where-Object id -eq 'us-eu')[0]
    if(-not $profile){$matches=@($catalog.Profiles|Where-Object {$_.name -match '^(US|США).*(EU|Европ)'});if($matches.Count -eq 1){$profile=$matches[0]}}
    if(-not $profile){throw 'Профиль US + EU отсутствует.'}
    $path=Join-Path $Root $profile.hostsFile
    $lines=@(Get-Content -LiteralPath $path -Encoding UTF8)
    $new=@('# GeoHide US + EU; addresses managed by the monitoring page.')
    $existing=@(foreach($line in $lines){$p=($line -split '#',2)[0].Trim() -split '\s+';if($p.Count -ge 2){$p[1..($p.Count-1)]}})
    $lines+=@(Get-GeoGeminiDomains|Where-Object {$_ -notin $existing}|ForEach-Object {$Settings.eu+' '+$_})
    $googleEU=@($Report.rows|Where-Object {$_.Region -eq 'EU' -and $_.Address -eq $Settings.eu -and (Test-GeoGoogleRoute $_)}).Count -gt 0
    foreach($line in $lines){
        $parts=($line -split '#',2)[0].Trim() -split '\s+'
        if($parts.Count -lt 2){continue}
        foreach($domain in $parts[1..($parts.Count-1)]){
            # A shared, certificate-validated HTTP2 route can work without a new www TLS handshake.
            if($domain -eq 'www.google.com' -and -not $googleEU){continue}
            $address=if((Test-GeoGeminiDomain $domain) -or $domain -eq 'oaiusercontent.com' -or $domain.EndsWith('.oaiusercontent.com')){$Settings.eu}else{$Settings.us}
            $new+=($address+' '+$domain)
        }
    }
    $content=($new -join "`r`n")+"`r`n"
    $old=[IO.File]::ReadAllText($path)
    if($old -ne $content){
        $backup=Join-Path $Root ('backups\geohide-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
        [IO.Directory]::CreateDirectory($backup)|Out-Null
        Copy-Item -LiteralPath $path -Destination (Join-Path $backup 'us-eu.hosts')
        Copy-Item -LiteralPath $catalogPath -Destination (Join-Path $backup 'profiles.json')
        $temp=$path+'.tmp'
        [IO.File]::WriteAllText($temp,$content,[Text.UTF8Encoding]::new($false))
        [IO.File]::Replace($temp,$path,[NullString]::Value)
        $profile.name='US + EU — ChatGPT + Gemini'
        $profile|Add-Member -MemberType NoteProperty -Name domainCount -Value ($new.Count-1) -Force
        $profile.description='Gemini и файлы через EU. GeoHide: US '+$Settings.us+'; все известные адреса oaiusercontent.com через EU '+$Settings.eu+'. Меняется подготовленный профиль; примените его кнопкой. Скачивание конкретной GIF проверяется отдельно.'
        $profile.verifiedAt=$null
        Write-GeoJson $catalogPath $catalog
    }
    $pools=@{}
    foreach($region in @('US','EU','RU')){
        $pool=@(Get-GeoPool $Report $region|ForEach-Object Address)
        $current=[string]$Settings.($region.ToLowerInvariant())
        $pools[$region]=@($pool|Where-Object {$_ -eq $current})+@($pool|Where-Object {$_ -ne $current})
    }
    if(-not @($catalog.Profiles|Where-Object id -eq 'ru-primary').Count){
        $ru=if($pools.RU.Count){$pools.RU[0]}else{'159.194.200.33'}
        $ruFile=Join-Path $Root 'profiles\ru-primary.hosts'
        $ruText=[regex]::Replace($content,'(?m)^[0-9.]+(?=\s+)',[string]$ru)
        [IO.File]::WriteAllText($ruFile,$ruText,[Text.UTF8Encoding]::new($false))
        $catalog.Profiles+=@([pscustomobject]@{id='ru-primary';name='Россия — GeoHide';region='RU';countryCode='RU';hostsFile='profiles/ru-primary.hosts';address=$ru;description='Узел GeoHide RU. Доступность проверяется перед выбором.';verifiedAt=$null;domainCount=($new.Count-1);managedRegion='RU'})
    }
    foreach($entry in $catalog.Profiles){
        if($entry.id -notin @('primary','alternate','eu-primary','eu-alternate','ru-primary')){continue}
        $region=if($entry.id.StartsWith('eu-')){'EU'}elseif($entry.id.StartsWith('ru-')){'RU'}else{'US'}
        $pool=@($pools[$region])
        if(-not $pool.Count){continue}
        $index=if($entry.id -in @('alternate','eu-alternate')){1}else{0}
        if($pool.Count -le $index){continue}
        $ip=$pool[$index]
        if(-not(Test-GeoAddress $ip)){throw 'Проверка вернула некорректный адрес GeoHide.'}
        $legacyPath=[IO.Path]::GetFullPath((Join-Path $Root $entry.hostsFile))
        if(-not $legacyPath.StartsWith(([IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Profile path is outside the application.'}
        if(-not (Test-Path -LiteralPath $legacyPath)){continue}
        $legacy=[IO.File]::ReadAllText($legacyPath)
        $updated=[regex]::Replace($legacy,'(?m)^[0-9.]+(?=\s+)',[string]$ip)
        $updated=[regex]::Replace($updated,'(?m)^\S+\s+www\.google\.com\s*\r?\n?','')
        $google=@($Report.rows|Where-Object {$_.Region -eq $region -and $_.Address -eq $ip -and (Test-GeoGoogleRoute $_)}).Count -gt 0
        if($google){$updated=$updated.TrimEnd()+"`r`n"+$ip+" www.google.com`r`n"}
        if($updated -ne $legacy){
            $legacyBackup=$legacyPath+'.geohide-backup'
            [IO.File]::WriteAllText($legacyBackup,$legacy,[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText(($legacyPath+'.tmp'),$updated,[Text.UTF8Encoding]::new($false))
            [IO.File]::Replace(($legacyPath+'.tmp'),$legacyPath,[NullString]::Value)
        }
        $entry|Add-Member -MemberType NoteProperty -Name address -Value $ip -Force
        $entry.verifiedAt=$null
        $entryCount=@($updated -split '\r?\n'|Where-Object {$_.Trim() -and $_ -notmatch '^\s*#'}).Count
        $entry|Add-Member NoteProperty domainCount $entryCount -Force
        $entry.description='ChatGPT, Gemini и вложения OpenAI. GeoHide '+$ip+'.'+$(if($google){' Gemini и проверка Google идут через один IP; также меняется маршрут Google Поиска. В Chrome сначала откройте Gemini.'})+' Адрес управляется мониторингом.'
    }
    Write-GeoJson $catalogPath $catalog
    $routes=Get-Content -LiteralPath (Join-Path $Root 'connection-routes.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $routes.routes=@($routes.routes|Where-Object {$_.domain -ne 'www.google.com' -or $googleEU})
    foreach($domain in @(Get-GeoGeminiDomains)){
        if($domain -eq 'www.google.com' -and -not $googleEU){continue}
        if(-not @($routes.routes|Where-Object domain -eq $domain).Count){$routes.routes+=@([pscustomobject]@{domain=$domain;label='Gemini';addresses=@($Settings.eu)})}
    }
    foreach($route in $routes.routes){$route.addresses=@($(if((Test-GeoGeminiDomain $route.domain) -or $route.domain -eq 'oaiusercontent.com'){$Settings.eu}else{$Settings.us}))}
    Write-GeoJson (Join-Path $Root 'connection-routes.json') $routes
    Write-GeoJson (Join-Path $Root 'geohide-settings.json') $Settings
}

function Get-GeoCombinedId([string]$Root) {
    $c=Get-Content -LiteralPath (Join-Path $Root 'profiles.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $p=@($c.Profiles|Where-Object id -eq 'us-eu')
    if(-not $p.Count){$p=@($c.Profiles|Where-Object {$_.name -match '^(US|США).*(EU|Европ)'})}
    if($p.Count -ne 1){throw 'Не найден единственный профиль US + EU.'}
    return [string]$p[0].id
}
function Get-GeoApplicationState([string]$Root,[string]$HostsPath=(Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'),[string]$ProfileId='') {
    $id=if($ProfileId){$ProfileId}else{Get-GeoCombinedId $Root}
    $catalog=Get-Content -LiteralPath (Join-Path $Root 'profiles.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $profile=@($catalog.Profiles|Where-Object id -eq $id)[0]
    if(-not $profile){return $false}
    $profilePath=[IO.Path]::GetFullPath((Join-Path $Root $profile.hostsFile))
    if(-not $profilePath.StartsWith(([IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Profile path outside application'}
    if(-not(Test-Path -LiteralPath $profilePath -PathType Leaf)){return $false}
    $desired=Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8
    $actual=Get-Content -LiteralPath $HostsPath -Raw -ErrorAction Stop
    $block=[regex]::Match($actual,'(?ms)^# BEGIN CHATGPT-US-WINDOWS\r?\n(.*?)^# END CHATGPT-US-WINDOWS')
    if(-not $block.Success){return $false}
    $maps=@(foreach($text in @($desired,$block.Groups[1].Value)){
        $rows=@(foreach($line in ($text -split '\r?\n')){
            $parts=($line -split '#',2)[0].Trim() -split '\s+'
            if($parts.Count -ge 2){foreach($domain in $parts[1..($parts.Count-1)]){$parts[0]+' '+$domain.ToLowerInvariant()}}
        })
        ,(@($rows|Sort-Object -Unique) -join "`n")
    })
    return ($maps[0] -ceq $maps[1])
}
