# No WPF dependency: both the worker and the UI use the same per-run states.
function New-GeoPendingReport($Servers,[string]$RunId,[string]$Phase='Проверка серверов') {
    $rows=@(foreach($server in @($Servers|Sort-Object region,address -Unique)){
        [pscustomobject]@{Region=$server.region;Address=$server.address;SourceActive=$true;CheckState='Queued';State='В очереди';TCP=$false;TLS=$false;HTTP=$null;Country='';LatencyMs=0;FilesTLS=$false;FilesHTTP=$null;Error='';CheckedAt=$null;EligibleUS=$false;EligibleEU=$false;EligibleRU=$false;GeminiTLS=$false;GeminiHTTP=$null;GeminiAPIHTTP=$null;GeminiReady=$false;GeminiChallenge=$false;GeminiVerificationTLS=$false;GeminiVerificationHTTP=$null;GeminiSharedHTTP2=$false;GeminiRouteMs=0;GeminiCountry='';GeminiError=''}
    })
    return [pscustomobject]@{runId=$RunId;running=$true;at=(Get-Date).ToString('o');phase=$Phase;completed=0;total=$rows.Count;interface='';rows=$rows;sourceErrors=@();sources=@()}
}
function Test-GeoPendingRow($Row) {
    return [bool]($Row.CheckState -in @('Queued','Checking'))
}
function Stop-GeoReportLoading($Report) {
    if(-not $Report){return}
    $Report.running=$false
    foreach($row in $Report.rows){if(Test-GeoPendingRow $row){$row.CheckState='Interrupted';$row.State='Проверка не завершена';$row.Error='Повторите проверку серверов'}}
}
