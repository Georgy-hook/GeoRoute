#Requires -Version 5.1
$ErrorActionPreference='Stop'
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\_service\NetworkSetup.ps1'),[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Setup script did not parse.'}
$function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Restore-Network'},$true)
. ([scriptblock]::Create($function.Extent.Text))
$script:calls=[Collections.Generic.List[string]]::new()
$serviceName='NextDNSBridge'
function Get-SavedAdapter($Record){if($Record.Guid -eq 'missing-usb'){throw 'Adapter is disconnected'};[pscustomobject]@{ifIndex=$Record.Index}}
function Get-OwnService {$true}
function Stop-Service($Name,$ErrorAction){$script:calls.Add('stop')}
function Set-DnsClientServerAddress($InterfaceIndex,$ServerAddresses,[switch]$ResetServerAddresses){$script:calls.Add('dns-'+$InterfaceIndex)}
function Clear-DnsClientCache {$script:calls.Add('cache')}
$backup=[pscustomobject]@{Adapters=@([pscustomobject]@{Guid='wifi';Index=4;Servers=@('1.1.1.1')},[pscustomobject]@{Guid='missing-usb';Index=8;Servers=@()});LegacyDriverStart=$null;Legacy=$null;Startup=@();ExclusionPaths=@()}
$rejected=$false;try{Restore-Network $backup}catch{$rejected=$true}
if(-not $rejected -or $script:calls.Count){throw 'Disconnected saved adapter changed DNS or stopped the bridge.'}
$backup.Adapters=@($backup.Adapters[0]);Restore-Network $backup
if(($script:calls -join ',') -ne 'stop,dns-4,cache'){throw 'Available adapter restore did not complete.'}
Write-Output 'Network restore preflight passed: missing USB leaves DNS and service untouched.'
