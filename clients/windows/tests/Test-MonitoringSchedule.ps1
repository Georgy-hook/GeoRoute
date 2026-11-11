$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
. (Join-Path $source 'GeoServices.ps1')
. (Join-Path $source 'Tray.ps1')
function Assert($Value,$Message){if(-not $Value){throw $Message}}
Assert ((Get-GeoMonitoringInterval).TotalHours -eq 2) 'Shared automatic scan interval is two hours'
Assert (-not(Test-GeoMonitoringDue (Get-Date).AddMinutes(-119))) 'No early automatic check'
Assert (Test-GeoMonitoringDue (Get-Date).AddMinutes(-121)) 'Check is due after two hours'
$row=[pscustomobject]@{CheckedAt=(Get-Date).AddMinutes(-90).ToString('o');GeminiReady=$true;GeminiSharedHTTP2=$true}
Assert (Test-GeoObservationFresh $row) 'Last result remains usable between scheduled checks'
Assert (Test-GeoGoogleRoute $row) 'Gemini uses the same observation lifetime'
$row.CheckedAt=(Get-Date).AddMinutes(-129).ToString('o')
Assert (Test-GeoObservationFresh $row) 'Allow the next bounded scan to finish'
$row.CheckedAt=(Get-Date).AddMinutes(-131).ToString('o')
Assert (-not(Test-GeoObservationFresh $row)) 'Old results cannot stay usable indefinitely'
$row.CheckedAt=(Get-Date).AddMinutes(10).ToString('o')
Assert (-not(Test-GeoObservationFresh $row)) 'Future timestamps cannot prolong a cached observation'
$row.CheckedAt='invalid'
Assert (-not(Test-GeoObservationFresh $row)) 'Invalid observation date fails closed'
$script:taskUi=@{TransportStatusText=[pscustomobject]@{Text=''}}
$script:taskBridgeAt=Get-Date;$script:taskActivationEvent=$null;$script:checks=0
function Start-TaskConnection {$script:checks++;$script:taskConnectionAttempt=Get-Date}
$script:taskConnectionAttempt=(Get-Date).AddMinutes(-119)
Poll-TaskConnection
Assert ($script:checks -eq 0) 'Tray diagnostics cannot run every five minutes'
$script:taskConnectionAttempt=(Get-Date).AddMinutes(-121)
Poll-TaskConnection;Poll-TaskConnection
Assert ($script:checks -eq 1) 'Due tray check starts once and resets its cooldown'
Start-TaskConnection
Assert ($script:checks -eq 2) 'Manual checks remain available during the cooldown'
Write-Output 'Monitoring schedule passed: two-hour server/DNS checks, cooldowns, manual override and bounded observation lifetime; no network requests.'
