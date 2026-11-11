$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
$source=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
. (Join-Path $source 'GeoHideUI.ps1')
function Assert($Value,$Message){if(-not $Value){throw $Message}}
function Update-GeoHome {param([switch]$Force)}
$root=Join-Path ([IO.Path]::GetTempPath()) ('georoute-monitoring-settings-'+[guid]::NewGuid().ToString('N'))
function Bind-SettingsUi {
    $combo=[Windows.Controls.ComboBox]::new();$combo.DisplayMemberPath='Label';$combo.SelectedValuePath='Minutes'
    $script:taskUi=@{AutoCheckInterval=$combo;AutoCheckHelp=[pscustomobject]@{Text=''};GeoStatus=[pscustomobject]@{Text=''}}
    Initialize-GeoMonitoringSettings
}
try {
    [IO.Directory]::CreateDirectory($root)|Out-Null
    $script:taskSettingsPath=Join-Path $root 'GUI-settings.json'
    [IO.File]::WriteAllText($script:taskSettingsPath,'{"ReducedMotion":true,"CustomPreference":"kept"}')
    $SmokeTest=$false;$RenderPreview=$false;$script:geoReport=$null;$script:geoRun=$null;$script:taskConnectionRun=$null
    Bind-SettingsUi
    Assert ($script:taskUi.AutoCheckInterval.SelectedValue -eq 120) 'Existing users default to two hours'
    Assert ($script:taskUi.AutoCheckInterval.Items.Count -eq 7) 'Dropdown offers all intervals including Never'
    $script:taskUi.AutoCheckInterval.SelectedValue=360
    $saved=Get-Content $script:taskSettingsPath -Raw|ConvertFrom-Json
    Assert ($saved.AutoCheckMinutes -eq 360 -and $saved.ReducedMotion -and $saved.CustomPreference -eq 'kept') ('Changing the dropdown persists without erasing other preferences: '+($saved|ConvertTo-Json -Compress)+'; '+$script:taskUi.AutoCheckHelp.Text)
    Assert ((Get-GeoMonitoringInterval).TotalHours -eq 6) 'Choice takes effect immediately'
    Assert (-not(Test-GeoMonitoringDue (Get-Date).AddHours(-5)) -and (Test-GeoMonitoringDue (Get-Date).AddHours(-7))) 'Scheduler follows the selected interval'
    Assert (((Get-Date)-$script:geoAt).TotalSeconds -lt 10 -and ((Get-Date)-$script:taskConnectionAttempt).TotalSeconds -lt 10) 'Changing the interval restarts both cooldowns'
    Save-GeoGuiPreference $script:taskSettingsPath @{ReducedMotion=$false}
    Assert ((Read-GeoMonitoringPreference $script:taskSettingsPath) -eq 360) 'Changing animations cannot erase the monitoring choice'
    Set-GeoMonitoringMinutes 120;Bind-SettingsUi
    Assert ($script:taskUi.AutoCheckInterval.SelectedValue -eq 360) 'Choice reloads after restart'
    $script:taskUi.AutoCheckInterval.SelectedValue=0
    Assert ($null -eq (Get-GeoMonitoringInterval) -and -not(Test-GeoMonitoringDue ([datetime]::MinValue))) 'Never suppresses automatic checks, including initial timer polls'
    Assert ($script:taskUi.AutoCheckHelp.Text -like '*при запуске*') 'Never explains the startup behavior'
    Set-GeoMonitoringMinutes 120;Bind-SettingsUi
    Assert ((Get-GeoMonitoringMinutes) -eq 0 -and $script:taskUi.AutoCheckInterval.SelectedValue -eq 0) 'Never is preserved after reload'
    Copy-Item (Join-Path $source 'GeoServices.ps1') $root
    $childScript=Join-Path $root 'read-preference.ps1'
    [IO.File]::WriteAllText($childScript,'. (Join-Path $PSScriptRoot ''GeoServices.ps1''); Get-GeoMonitoringMinutes')
    $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $loaded=& $shell -NoProfile -File $childScript
    Assert ($LASTEXITCODE -eq 0 -and $loaded -eq '0') 'A fresh worker process reads the saved monitoring preference'
    $row=[pscustomobject]@{CheckedAt=(Get-Date).AddMinutes(-131).ToString('o')}
    Assert (-not(Test-GeoObservationFresh $row)) 'Disabling automation cannot make old observations valid forever'
    [IO.File]::WriteAllText($script:taskSettingsPath,'{"AutoCheckMinutes":17}')
    Assert ((Read-GeoMonitoringPreference $script:taskSettingsPath) -eq 120) 'Unsupported saved intervals fall back safely'
    [IO.File]::WriteAllText($script:taskSettingsPath,'{malformed')
    Assert ((Read-GeoMonitoringPreference $script:taskSettingsPath) -eq 120) 'Malformed settings do not break startup'
    Bind-SettingsUi
    $script:taskUi.AutoCheckInterval.SelectedValue=60
    $script:taskUi.AutoCheckInterval.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
    Assert ((Get-GeoMonitoringMinutes) -eq 120 -and $script:taskUi.AutoCheckInterval.SelectedValue -eq 120) 'Save failure restores the effective setting and dropdown'
    Assert ([IO.File]::ReadAllText($script:taskSettingsPath) -eq '{malformed') 'Save failure does not overwrite unreadable user preferences'
    Write-Output 'Monitoring preferences passed: actual WPF dropdown, immediate scheduling, persistence, Never, preservation of other preferences and save failure rollback; no network requests.'
}finally{
    $path=[IO.Path]::GetFullPath($root)
    if(-not $path.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($path) -notmatch '^georoute-monitoring-settings-[a-f0-9]{32}$'){throw 'Unexpected test path'}
    if(Test-Path $path){Remove-Item -LiteralPath $path -Recurse -Force}
}
