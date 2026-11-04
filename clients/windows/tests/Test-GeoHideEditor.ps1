$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
. (Join-Path $source 'GeoHideUI.ps1')
function Assert($Value,$Message){if(-not $Value){throw $Message}}
function Get-TaskBrush($Color){return $Color}
function Add-TaskLog($Message){}
function Load-TaskProfiles([switch]$Force){}
$script:applyCalls=@()
function Start-TaskAction($Mode,$ProfileId){$script:applyCalls+=@([pscustomobject]@{Mode=$Mode;ProfileId=$ProfileId})}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('geohide-editor-test-'+[guid]::NewGuid().ToString('N'))
$hosts=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$before=(Get-FileHash -LiteralPath $hosts).Hash
try{
    [IO.Directory]::CreateDirectory($temp)|Out-Null
    Copy-Item -LiteralPath (Join-Path $source 'profiles') -Destination $temp -Recurse
    foreach($name in @('profiles.json','connection-routes.json')){Copy-Item -LiteralPath (Join-Path $source $name) -Destination $temp}
    $script:taskRoot=$temp;$script:taskBusy=$false;$script:geoReport=[pscustomobject]@{rows=@()}
    $script:taskUi=@{}
    foreach($name in @('GeoUS','GeoEU','GeoAuto','GeoManual','GeoEditorStatus','GeoModeHelp','GeoApply','GeoSave','GeoUSHelp','GeoEUHelp')){
        $script:taskUi[$name]=[pscustomobject]@{Text='';IsEnabled=$true;IsChecked=$false;Content='';Foreground=''}
    }
    $script:taskUi.GeoManual.IsChecked=$true
    $script:taskUi.GeoUS.Text='192.3.233.253';$script:taskUi.GeoEU.Text='45.13.237.213'
    Save-GeoEditor
    $saved=Read-GeoSettings $temp
    Assert (-not $saved.autoSelect -and $saved.us -eq '192.3.233.253') 'Manual US input persisted'
    Assert ($script:applyCalls.Count -eq 0) 'Save without connecting never applies'
    Assert ($script:taskUi.GeoUS.IsEnabled -and $script:taskUi.GeoEU.IsEnabled) 'Manual fields are editable'
    $script:geoReport.rows=@([pscustomobject]@{Region='US';Address='192.255.159.240';EligibleUS=$true;SourceActive=$true;CheckedAt=(Get-Date).ToString('o')},[pscustomobject]@{Region='EU';Address='45.13.237.213';EligibleEU=$true;FilesTLS=$true;FilesHTTP=404;SourceActive=$true;CheckedAt=(Get-Date).ToString('o')})
    $script:taskUi.GeoUS.Text='192.255.159.240'
    Save-GeoEditor -Connect
    Assert ($script:applyCalls.Count -eq 1 -and $script:applyCalls[0].Mode -eq 'Apply') 'One manual connect uses existing elevated apply boundary'
    Assert ((Read-GeoSettings $temp).us -eq '192.255.159.240') 'New manual input saved before apply'
    $script:taskUi.GeoUS.Text='127.0.0.1'
    Save-GeoEditor -Connect
    Assert ($script:applyCalls.Count -eq 1) 'Invalid input never reaches apply'
    Assert ((Read-GeoSettings $temp).us -eq '192.255.159.240') 'Invalid input preserves saved choice'
    $script:taskUi.GeoManual.IsChecked=$false;$script:taskUi.GeoAuto.IsChecked=$true
    Update-GeoEditorState -Force
    Assert (-not $script:taskUi.GeoUS.IsEnabled -and -not $script:taskUi.GeoEU.IsEnabled) 'Automatic mode fields are clearly disabled'
    Assert ((Get-FileHash -LiteralPath $hosts).Hash -eq $before) 'Real hosts untouched'
    Write-Output 'GeoHide editor workflow passed: manual save, save-and-connect boundary, invalid input and explicit automatic/manual fields; no system change.'
}finally{
    $full=[IO.Path]::GetFullPath($temp)
    if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^geohide-editor-test-[a-f0-9]{32}$'){throw 'Unsafe test cleanup'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
