$script:geoHistory=@{}
function Get-GeoCheckReason($Row) {
    if(Test-GeoPendingRow $Row){return $(if($Row.CheckState -eq 'Checking'){'Идёт проверка'}else{'Ожидает проверки'})}
    if($Row.CheckState -eq 'Interrupted'){return 'Проверка прервана'}
    if($Row.SourceActive -eq $false){return 'Узел снят с публикации'}
    if(-not $Row.TCP){return 'Сервер не отвечает'}
    if(-not $Row.TLS){
        if($Row.Error -match '(?i)timeout|timed out|время ожидания'){return 'Тайм-аут HTTPS'}
        if($Row.Error -match '(?i)certificate|сертификат'){return 'Ошибка сертификата'}
        return 'Ошибка HTTPS'
    }
    if(-not $Row.HTTP){return 'Нет HTTP-ответа'}
    if($Row.HTTP -eq 403){return 'HTTP 403 · доступ запрещён'}
    if($Row.HTTP -eq 429){return 'HTTP 429 · лимит запросов'}
    if($Row.HTTP -ne 200){return ('HTTP '+$Row.HTTP+' · '+$(if($Row.HTTP -ge 500){'ошибка сервера'}else{'неожиданный ответ'}))}
    if(-not $Row.Country){return 'Не определена страна выхода'}
    return 'HTTPS отвечает'
}
function Get-GeoHistorySamples($Samples) {
    # Old history remains readable. Invalid dates must not break the whole monitor.
    $valid=@{}
    foreach($sample in @($Samples)){
        if($null -eq $sample -or -not $sample.PSObject.Properties['ok'] -or $sample.ok -isnot [bool]){continue}
        $date=[DateTimeOffset]::MinValue
        if([DateTimeOffset]::TryParse([string]$sample.at,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date)){$valid[$date.UtcTicks]=$sample}
    }
    @($valid.Keys|Sort-Object|Select-Object -Last 24|ForEach-Object {$valid[$_]})
}
function Get-GeoHistoryView($Samples) {
    $samples=@(Get-GeoHistorySamples $Samples)
    $chart=[Windows.Controls.Primitives.UniformGrid]::new();$chart.Rows=1;$chart.Height=8
    if(-not $samples.Count){
        return [pscustomobject]@{Visual=$chart;Count='Проверок пока нет';Last='Нажмите «Проверить серверы»';Hint='История локальных проверок ChatGPT пуста. Ожидание и прерванные проверки не считаются результатом.';Bars=@()}
    }
    $count=[string]@($samples|Where-Object ok).Count+' из '+$samples.Count+' успешно'
    $first=([DateTimeOffset]::Parse($samples[0].at)).ToLocalTime()
    $last=([DateTimeOffset]::Parse($samples[-1].at)).ToLocalTime()
    $lines=@('Локальные проверки ChatGPT';$count;('Период: '+$first.ToString('dd.MM.yyyy HH:mm:ss')+' — '+$last.ToString('dd.MM.yyyy HH:mm:ss'));'Один штрих — одна проверка. Новые справа. Это история проверок, а не время непрерывной работы.';'')
    $bars=@(foreach($sample in $samples){
        $date=([DateTimeOffset]::Parse($sample.at)).ToLocalTime()
        $reason=if($sample.ok){'HTTPS отвечает'}elseif($sample.PSObject.Properties['reason'] -and $sample.reason){[string]$sample.reason}elseif($sample.tcp){'Нет HTTPS-ответа'}else{'Нет TCP-ответа'}
        $hint=$date.ToString('dd.MM.yyyy HH:mm:ss')+' · '+$reason
        if($sample.ok){$hint+=' · '+$sample.ms+' мс'}
        [pscustomobject]@{height=8;color=$(if($sample.ok){'#72D9B7'}elseif($sample.tcp){'#F6C56B'}else{'#FF8E9E'});hint=$hint}
    })
    foreach($bar in $bars){
        $segment=[Windows.Controls.Border]::new();$segment.Height=8
        $segment.Background=Get-TaskBrush $bar.color;$segment.CornerRadius=[Windows.CornerRadius]::new(2)
        $segment.Margin=[Windows.Thickness]::new(0,0,2,0);$segment.ToolTip=$bar.hint
        [Windows.Automation.AutomationProperties]::SetName($segment,$bar.hint)
        [void]$chart.Children.Add($segment)
        $lines+=$bar.hint
    }
    return [pscustomobject]@{Visual=$chart;Count=$count;Last=('Последняя: '+$last.ToString('dd.MM, HH:mm'));Hint=($lines -join "`n");Bars=$bars}
}
function Initialize-GeoHistory {
    $path=Join-Path $script:taskRoot 'geohide-history.json'
    if(Test-Path -LiteralPath $path){try{
        $data=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
        foreach($prop in $data.PSObject.Properties){$script:geoHistory[$prop.Name]=@($prop.Value)}
    }catch{}}
}
function Show-GeoFilteredRows {
    if(-not $script:geoDisplayRows){return}
    $filter=$script:geoRegionFilter
    $query=$script:taskUi.GeoSearch.Text.Trim()
    $script:taskUi.GeoGrid.ItemsSource=@($script:geoDisplayRows|Where-Object{($filter -eq 'ALL' -or $_.Region -eq $filter) -and (-not $query -or $_.Address.Contains($query))}|Sort-Object @{Expression={switch($_.Region){US{0}EU{1}default{2}}}},Address)
    foreach($name in @('ALL','US','EU','RU')){
        $script:taskUi[('GeoFilter'+$name)].Background=Get-TaskBrush $(if($filter -eq $name){'#254550'}else{'#142131'})
    }
}
function Update-GeoHistory($Report) {
    $rows=@()
    foreach($row in $Report.rows){
        if(Test-GeoClosedNode $row.Region $row.Address){$row.SourceActive=$false;$row.CheckState='Retired';$row.State='RU-узел закрыт владельцем';$row.Error=$row.State}
        $pending=Test-GeoPendingRow $row
        $interrupted=$row.CheckState -eq 'Interrupted'
        $key=$row.Region+'-'+$row.Address
        $samples=@($script:geoHistory[$key]|Where-Object{$null -ne $_})
        $reason=Get-GeoCheckReason $row
        if(-not $pending -and -not $interrupted -and $row.CheckedAt -and $row.SourceActive -ne $false -and -not @($samples|Where-Object at -eq $row.CheckedAt).Count){$samples+=@([pscustomobject]@{at=$row.CheckedAt;ms=$row.LatencyMs;ok=($row.TLS -and $row.HTTP -eq 200 -and [bool]$row.Country);tcp=$row.TCP;reason=$reason})}
        $samples=@(Get-GeoHistorySamples $samples);$script:geoHistory[$key]=$samples
        $fresh=-not $pending -and -not $interrupted -and (Test-GeoObservationFresh $row) -and $row.SourceActive -ne $false
        $ok=$fresh -and $row.TLS -and $row.HTTP -eq 200 -and [bool]$row.Country
        $color=if($pending){'#A4D5F2'}elseif(-not $fresh){'#9CAEC4'}elseif($ok){'#91F2D2'}elseif($row.TCP){'#F6C56B'}else{'#FF8E9E'}
        $label=if($pending){if($row.CheckState -eq 'Checking'){'Проверяю…'}else{'В очереди…'}}elseif($interrupted){'Проверка прервана'}elseif($row.SourceActive -eq $false){'○  Удалён из списка'}elseif(-not $fresh){'○  Проверка устарела'}elseif($ok){'●  Доступен'}elseif($row.TCP){'◐  Только TCP'}else{'●  Нет ответа'}
        $history=Get-GeoHistoryView $samples
        $flag=Get-TaskImage ('flag-'+$row.Region+'.png')
        $countryFlag=Get-TaskImage ('flag-'+$row.Country+'.png')
        if(-not $countryFlag){$countryFlag=Get-TaskImage 'icon-globe.png'}
        $extra=@{LoadingVisibility=$(if($pending){'Visible'}else{'Collapsed'});GeminiLabel=$(if($pending){if($row.CheckState -eq 'Checking'){'Проверяю…'}else{'В очереди…'}}elseif(-not $fresh){'Нужна проверка'}elseif($row.PSObject.Properties['GeminiSharedHTTP2'] -and $row.GeminiSharedHTTP2){'Gemini + Google'}elseif($row.GeminiChallenge -and -not $row.GeminiReady){'Проверка недоступна'}elseif($row.GeminiChallenge){'Ограничение Google'}elseif($row.GeminiReady){'HTTPS отвечает'}else{'Недоступен'});GeminiColor=$(if($row.GeminiChallenge -and -not $row.GeminiReady -and $fresh){'#FF8E9E'}elseif($row.GeminiChallenge -and $fresh){'#F6C56B'}elseif($row.GeminiReady -and $fresh){'#91F2D2'}else{'#9CAEC4'});AvailableNow=$ok;HistoryVisual=$history.Visual;HistoryLast=$history.Last;HistoryHint=$history.Hint;ReasonLabel=$reason;ReasonHint=($reason+$(if($row.Error){"`nТехническая информация: "+$row.Error}));ChatDetail=$(if($ok){"HTTPS · HTTP 200"}else{$reason});Flag=$flag;CountryFlag=$countryFlag;StatusColor=$color;StatusLabel=$label;Bars=$history.Bars;HistoryCount=$history.Count;LatencyLabel=$(if($ok){[string]$row.LatencyMs+' мс'}else{'—'});FilesLabel=$(if($row.FilesTLS){'TLS · '+$row.FilesHTTP}else{'—'});FilesColor=$(if($row.FilesTLS){'#91F2D2'}else{'#8E9FB4'})}
        foreach($name in $extra.Keys){$row|Add-Member -MemberType NoteProperty -Name $name -Value $extra[$name] -Force}
        $choice=Test-GeoRequirements @([pscustomobject]@{Role=$row.Region;Address=$row.Address;Files=$true;Service='ChatGPT'},[pscustomobject]@{Role=$row.Region;Address=$row.Address;Files=$false;Service='Gemini'}) $Report
        # Row eligibility is independent of an import/apply operation. GeoGrid's
        # inherited IsEnabled gates busy UI and restores buttons without a new scan.
        $row|Add-Member NoteProperty CanConnect ([bool](-not $Report.running -and $choice.Ready)) -Force
        $row|Add-Member NoteProperty ConnectHint ($choice.Reason+' · Подключение запросит подтверждение Windows. Используется один узел для ChatGPT, Gemini и вложений. Google Поиск меняет маршрут только при проверенном общем IP.') -Force
        $rows+=@($row)
    }
    $script:geoDisplayRows=$rows
    foreach($region in @('US','EU','RU')){
        $all=@($rows|Where-Object Region -eq $region)
        $available=@($all|Where-Object{$_.AvailableNow})
        $pendingRegion=@($all|Where-Object {Test-GeoPendingRow $_}).Count -gt 0
        $script:taskUi[('GeoCount'+$region)].Text=if($pendingRegion){'…'}else{[string]$available.Count+' / '+$all.Count}
        if($script:taskUi[('GeoGeminiCount'+$region)]){$script:taskUi[('GeoGeminiCount'+$region)].Text=if($pendingRegion){'Gemini: проверяю…'}else{'Gemini: '+@($all|Where-Object {$_.GeminiReady -and $_.SourceActive -ne $false -and (Test-GeoObservationFresh $_)}).Count+' / '+$all.Count+' маршрутов'}}
    }
    Show-GeoFilteredRows
    if(-not $Report.running -and -not $SmokeTest -and -not $RenderPreview){Write-GeoJson (Join-Path $script:taskRoot 'geohide-history.json') $script:geoHistory}
}
