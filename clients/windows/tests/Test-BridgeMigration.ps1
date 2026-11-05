#Requires -Version 5.1
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\_service\NetworkSetup.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Setup script did not parse'}
$function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-OwnService'},$true)
. ([scriptblock]::Create($function.Extent.Text))
$serviceCommand='"C:\Program Files\NextDNS Bridge\python\python.exe" -I -u "C:\Program Files\NextDNS Bridge\bridge.py" --service --profile-file "C:\Program Files\NextDNS Bridge\profile.txt" --data-dir "C:\ProgramData\NextDNSBridge"'
$legacyServiceCommand='"C:\Program Files\NextDNS Bridge\NextDNSBridge.exe"'
function Get-CimInstance {param($ClassName,$Filter) $script:fakeService}
foreach($path in @($serviceCommand,$legacyServiceCommand)){
 $script:fakeService=[pscustomobject]@{PathName=$path}
 if(-not(Get-OwnService)){throw 'Known service was not accepted'}
}
foreach($path in @('"C:\Other\NextDNSBridge.exe"',($serviceCommand+' --port 5355'),($legacyServiceCommand+' --other'))){
 $script:fakeService=[pscustomobject]@{PathName=$path}
 $rejected=$false;try{Get-OwnService | Out-Null}catch{$rejected=$true}
 if(-not $rejected){throw 'Unexpected service command was accepted'}
}
$script:fakeService=$null
if($null -ne (Get-OwnService)){throw 'Missing service was not handled'}
Write-Output '6 Bridge migration ownership cases passed; no services or DNS changed.'
