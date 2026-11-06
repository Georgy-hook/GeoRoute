#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'GeoServices.ps1')
function Get-GeoPool($Report,[ValidateSet('US','EU','RU')][string]$Region,[ValidateSet('ChatGPT','Gemini','Combined')][string]$Service='ChatGPT') {
    return @($Report.rows|Where-Object {
        $node=$_
        $fresh=$true
        if($node.PSObject.Properties['CheckedAt']){$checked=[datetime]::MinValue;$fresh=[datetime]::TryParse([string]$node.CheckedAt,[ref]$checked) -and ((Get-Date)-$checked).TotalMinutes -lt 5}
        $capable=if($Service -eq 'Gemini'){$node.GeminiReady}elseif($Service -eq 'Combined'){$node.EligibleEU -and $node.GeminiReady}else{$(switch($Region){US{$node.EligibleUS}EU{$node.EligibleEU}RU{$node.EligibleRU}})}
        $fresh -and -not ($node.CheckState -in @('Queued','Checking','Interrupted')) -and $node.Region -eq $Region -and $node.SourceActive -ne $false -and $capable
    }|Sort-Object @{Expression={if($_.GeminiReady -and -not $_.GeminiChallenge){0}elseif($_.GeminiReady){1}else{2}}},Address -Unique)
}
function Get-GeoProfileRegion($Profile) {
    if($Profile.PSObject.Properties['managedRegion']){return [string]$Profile.managedRegion}
    if($Profile.id -eq 'us-eu' -or $Profile.name -match '^(US|США).*(EU|Европ)'){return 'US+EU'}
    if($Profile.id -eq 'gemini-us'){return 'US'};if($Profile.id -eq 'gemini-eu'){return 'EU'}
    switch([string]$Profile.id){primary{return 'US'}alternate{return 'US'}eu-primary{return 'EU'}eu-alternate{return 'EU'}ru-primary{return 'RU'}}
    return ''
}
function Get-GeoProfileAvailability([string]$Root,[string]$Id,$Report) {
    $catalog=Get-Content -LiteralPath (Join-Path $Root 'profiles.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $profile=@($catalog.Profiles|Where-Object id -eq $Id|Select-Object -First 1)
    if(-not $profile.Count){return [pscustomobject]@{Ready=$false;Managed=$true;Reason='Профиль отсутствует';State='missing'}}
    $region=Get-GeoProfileRegion $profile[0]
    if(-not $region){return [pscustomobject]@{Ready=$true;Managed=$false;Reason='Пользовательский профиль · проверяется отдельно';State='custom'}}
    $path=[IO.Path]::GetFullPath((Join-Path $Root $profile[0].hostsFile))
    if(-not $path.StartsWith(([IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Profile path outside application.'}
    $requirements=@{}
    foreach($line in (Get-Content -LiteralPath $path -Encoding UTF8)){
        $parts=($line -split '#',2)[0].Trim() -split '\s+'
        if($parts.Count -lt 2){continue}
        foreach($domain in $parts[1..($parts.Count-1)]){
            $gemini=Test-GeoGeminiDomain $domain
            $files=$domain -eq 'oaiusercontent.com' -or $domain.EndsWith('.oaiusercontent.com')
            $role=if($region -eq 'US+EU'){if($files -or $gemini){'EU'}else{'US'}}else{$region}
            $key=$role+'|'+$parts[0]+'|'+$(if($gemini){'Gemini'}else{'ChatGPT'})
            if(-not $requirements.ContainsKey($key)){$requirements[$key]=[pscustomobject]@{Role=$role;Address=$parts[0];Files=$files;Service=$(if($gemini){'Gemini'}else{'ChatGPT'})}}
            if($files){$requirements[$key].Files=$true}
        }
    }
    if(-not $requirements.Count){return [pscustomobject]@{Ready=$false;Managed=$true;Reason='Профиль пуст';State='empty'}}
    return (Test-GeoRequirements @($requirements.Values) $Report)
}
function Get-GeoPairAvailability([string]$US,[string]$EU,$Report) {
    return (Test-GeoRequirements @([pscustomobject]@{Role='US';Address=$US;Files=$false},[pscustomobject]@{Role='EU';Address=$EU;Files=$true},[pscustomobject]@{Role='EU';Address=$EU;Files=$false;Service='Gemini'}) $Report)
}
function Test-GeoRequirements([object[]]$Needs,$Report) {
    $issues=@();$warnings=@()
    $shared=@($Needs|Where-Object {$_.Service -ne 'Gemini'}).Count -gt 0
    foreach($need in $Needs){
        $rows=@($Report.rows|Where-Object {$_.Region -eq $need.Role -and $_.Address -eq $need.Address}|Select-Object -First 1)
        $prefix=$need.Role+' '+$need.Address+': '
        if(-not $rows.Count){$issues+=$prefix+'нет актуальной проверки или адрес удалён из списка';continue}
        $row=$rows[0];$checked=[datetime]::MinValue
        if(-not [datetime]::TryParse([string]$row.CheckedAt,[ref]$checked) -or ((Get-Date)-$checked).TotalMinutes -gt 5){$issues+=$prefix+'проверка устарела';continue}
        if($row.SourceActive -eq $false){$issues+=$prefix+'удалён из списка GeoHide';continue}
        if($row.CheckState -in @('Queued','Checking','Interrupted')){$issues+=$prefix+'проверка ещё не завершена';continue}
        if($need.Service -eq 'Gemini'){
            if(-not $row.GeminiReady){
                $message=$prefix+$(if($row.GeminiError){$row.GeminiError}else{'Gemini: HTTPS страницы / API недоступен'})
                if($shared){$warnings+=$message}else{$issues+=$message}
            }elseif($row.GeminiChallenge){$warnings+='Gemini: ограничение Google / CAPTCHA. Если поля проверки нет, выберите другой сервер'}
            elseif($row.PSObject.Properties['GeminiVerificationTLS'] -and -not $row.GeminiVerificationTLS){$warnings+='Gemini: HTTPS отвечает, но этот узел не открывает проверку Google. Доступ к модели не подтверждён'}
            continue
        }
        $eligible=switch($need.Role){US{$row.EligibleUS}EU{$row.EligibleEU}RU{$row.EligibleRU}}
        if(-not $eligible){$issues+=$prefix+'не прошёл проверку региона / HTTPS';continue}
        if($need.Files -and (-not $row.FilesTLS -or $row.FilesHTTP -notin @(200,204,301,302,400,401,404,405))){$issues+=$prefix+'HTTPS вложений недоступен'}
    }
    return [pscustomobject]@{Ready=($issues.Count -eq 0);Managed=$true;Reason=$(if($issues.Count){$issues -join '; '}elseif($warnings.Count){$(if($shared){'ChatGPT доступен · '})+($warnings -join '; ')}else{'Все необходимые узлы проверены · можно подключить'});State=$(if($issues.Count){'unavailable'}elseif($warnings.Count){'attention'}else{'ready'})}
}

function Set-GeoRegionCatalog($Catalog,[string]$Region,[string[]]$Addresses,[string]$Origin) {
    $valid=@($Addresses|Where-Object {Test-GeoAddress $_}|Sort-Object -Unique)
    if(-not $valid.Count -or $valid.Count -gt 32){throw 'Нет достоверного списка серверов региона.'}
    if(-not $Catalog.PSObject.Properties['retired']){$Catalog|Add-Member -MemberType NoteProperty -Name retired -Value @()}
    $removed=@($Catalog.servers|Where-Object {$_.region -eq $Region -and $_.address -notin $valid})
    foreach($node in $removed){
        if(-not @($Catalog.retired|Where-Object {$_.region -eq $Region -and $_.address -eq $node.address}).Count){
            $Catalog.retired+=@([pscustomobject]@{region=$Region;address=$node.address;removedAt=(Get-Date).ToString('o')})
        }
    }
    $Catalog.retired=@($Catalog.retired|Where-Object {-not ($_.region -eq $Region -and $_.address -in $valid)}|Select-Object -Last 64)
    $Catalog.servers=@($Catalog.servers|Where-Object region -ne $Region)+@($valid|ForEach-Object{[pscustomobject]@{region=$Region;address=$_;origin=$Origin}})
}
