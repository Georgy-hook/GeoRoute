#Requires -Version 5.1
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\_service\Tray.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Tray script did not parse'}
foreach($name in @('Get-TaskStartupCommand','Sync-TaskStartupEntry')){
 $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
 . ([scriptblock]::Create($function.Extent.Text))
}
$script:taskRoot=Join-Path $env:TEMP 'GeoRouteStartupTest\_service'
$script:taskStartupKey='test-only';$script:taskStartupName='test-only'
function Get-ManagerLauncher($Root){Join-Path (Split-Path $Root -Parent) 'GeoRoute.cmd'}
function Get-TaskStartupValue {$script:oldValue}
function New-ItemProperty {param($Path,$Name,$Value,$PropertyType,[switch]$Force) $script:written=$Value}
$expected='"'+$env:ComSpec+'" /d /s /c ""'+(Get-ManagerLauncher $script:taskRoot)+'" -Tray"'
if((Get-TaskStartupCommand) -cne $expected){throw 'CMD startup quoting failed'}
foreach($path in @((Join-Path (Split-Path $script:taskRoot -Parent) 'GeoRoute.exe'),(Join-Path $script:taskRoot 'bin\NextDNS.exe'))){
 $script:oldValue='"'+$path+'" -Tray';$script:written=$null;Sync-TaskStartupEntry
 if($script:written -cne $expected){throw 'Own legacy startup was not migrated'}
}
foreach($value in @('','"C:\Other\GeoRoute.exe" -Tray',$expected)){
 $script:oldValue=$value;$script:written=$null;Sync-TaskStartupEntry
 if($null -ne $script:written){throw 'Unrelated or disabled startup was changed'}
}
Write-Output '6 startup migration checks passed; user registry unchanged.'
