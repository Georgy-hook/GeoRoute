$script:geoHistory=@{}
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
        $pending=Test-GeoPendingRow $row
        $interrupted=$row.CheckState -eq 'Interrupted'
        $key=$row.Region+'-'+$row.Address
        $samples=@($script:geoHistory[$key]|Where-Object{$null -ne $_})
        if(-not $pending -and -not $interrupted -and $row.CheckedAt -and $row.SourceActive -ne $false -and -not @($samples|Where-Object at -eq $row.CheckedAt).Count){$samples+=@([pscustomobject]@{at=$row.CheckedAt;ms=$row.LatencyMs;ok=($row.TLS -and $row.HTTP -eq 200 -and [bool]$row.Country);tcp=$row.TCP})}
        $samples=@($samples|Select-Object -Last 24);$script:geoHistory[$key]=$samples
        $fresh=-not $pending -and -not $interrupted -and $row.CheckedAt -and ((Get-Date)-[datetime]$row.CheckedAt).TotalMinutes -lt 5 -and $row.SourceActive -ne $false
        $ok=$fresh -and $row.TLS -and $row.HTTP -eq 200 -and [bool]$row.Country
        $color=if($pending){'#A4D5F2'}elseif(-not $fresh){'#9CAEC4'}elseif($ok){'#91F2D2'}elseif($row.TCP){'#F6C56B'}else{'#FF8E9E'}
        $label=if($pending){if($row.CheckState -eq 'Checking'){'Проверяю…'}else{'В очереди…'}}elseif($interrupted){'Проверка прервана'}elseif($row.SourceActive -eq $false){'○  Удалён из списка'}elseif(-not $fresh){'○  Проверка устарела'}elseif($ok){'●  Доступен'}elseif($row.TCP){'◐  Только TCP'}else{'●  Нет ответа'}
        $bars=@($samples|ForEach-Object{[pscustomobject]@{height=$(if($_.ok){[Math]::Max(6,[Math]::Min(28,$_.ms/2000*28))}else{28});color=$(if($_.ok){'#72D9B7'}elseif($_.tcp){'#F6C56B'}else{'#FF8E9E'});hint=([datetime]$_.at).ToString('HH:mm:ss')+' · '+$(if($_.ok){[string]$_.ms+' мс'}else{'нет HTTPS-ответа'})}})
        $flag=Get-TaskImage ('flag-'+$row.Region+'.png')
        $countryFlag=Get-TaskImage ('flag-'+$row.Country+'.png')
        if(-not $countryFlag){$countryFlag=Get-TaskImage 'icon-globe.png'}
        $chart=[Windows.Controls.StackPanel]::new();$chart.Orientation='Horizontal';$chart.Height=28
        foreach($bar in $bars){
            $segment=[Windows.Controls.Border]::new();$segment.Width=5;$segment.Height=[double]$bar.height
            $segment.Background=Get-TaskBrush $bar.color;$segment.CornerRadius=[Windows.CornerRadius]::new(2)
            $segment.Margin=[Windows.Thickness]::new(0,0,2,0);$segment.VerticalAlignment='Bottom';$segment.ToolTip=$bar.hint
            [void]$chart.Children.Add($segment)
        }
        $extra=@{LoadingVisibility=$(if($pending){'Visible'}else{'Collapsed'});GeminiLabel=$(if($pending){if($row.CheckState -eq 'Checking'){'Проверяю…'}else{'В очереди…'}}elseif(-not $fresh){'Нужна проверка'}elseif($row.GeminiChallenge -and -not $row.GeminiReady){'Проверка недоступна'}elseif($row.GeminiChallenge){'Ограничение Google'}elseif($row.GeminiReady){'HTTPS отвечает'}else{'Недоступен'});GeminiColor=$(if($row.GeminiChallenge -and -not $row.GeminiReady -and $fresh){'#FF8E9E'}elseif($row.GeminiChallenge -and $fresh){'#F6C56B'}elseif($row.GeminiReady -and $fresh){'#91F2D2'}else{'#9CAEC4'});AvailableNow=$ok;HistoryVisual=$chart;Flag=$flag;CountryFlag=$countryFlag;StatusColor=$color;StatusLabel=$label;Bars=$bars;HistoryCount=([string]@($samples|Where-Object ok).Count+'/'+$samples.Count+' успешно');LatencyLabel=$(if($ok){[string]$row.LatencyMs+' мс'}else{'—'});FilesLabel=$(if($row.FilesTLS){'TLS · '+$row.FilesHTTP}else{'—'});FilesColor=$(if($row.FilesTLS){'#91F2D2'}else{'#8E9FB4'})}
        foreach($name in $extra.Keys){$row|Add-Member -MemberType NoteProperty -Name $name -Value $extra[$name] -Force}
        $rows+=@($row)
    }
    $script:geoDisplayRows=$rows
    foreach($region in @('US','EU','RU')){
        $all=@($rows|Where-Object Region -eq $region)
        $available=@($all|Where-Object{$_.AvailableNow})
        $pendingRegion=@($all|Where-Object {Test-GeoPendingRow $_}).Count -gt 0
        $script:taskUi[('GeoCount'+$region)].Text=if($pendingRegion){'…'}else{[string]$available.Count+' / '+$all.Count}
        if($script:taskUi[('GeoGeminiCount'+$region)]){$script:taskUi[('GeoGeminiCount'+$region)].Text=if($pendingRegion){'Gemini: проверяю…'}else{'Gemini: '+@($all|Where-Object {$_.GeminiReady -and $_.SourceActive -ne $false -and $_.CheckedAt -and ((Get-Date)-[datetime]$_.CheckedAt).TotalMinutes -lt 5}).Count+' / '+$all.Count+' маршрутов'}}
    }
    Show-GeoFilteredRows
    if(-not $Report.running -and -not $SmokeTest -and -not $RenderPreview){Write-GeoJson (Join-Path $script:taskRoot 'geohide-history.json') $script:geoHistory}
}
