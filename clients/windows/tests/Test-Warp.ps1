#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('georoute-warp-'+[guid]::NewGuid().ToString('N'))
function Assert($Value,$Message){if(-not $Value){throw $Message}}
try{
 [IO.Directory]::CreateDirectory($temp)|Out-Null
 $private=$temp;$statePath=Join-Path $temp 'network-state.json';$hostsPath=Join-Path $temp 'hosts'
 $encoding=[Text.Encoding]::GetEncoding(28591);$utf8=[Text.UTF8Encoding]::new($false)
 $pattern='(?ms)^# BEGIN CHATGPT-US-WINDOWS\r?\n.*?^# END CHATGPT-US-WINDOWS(?:\r?\n|$)';$stamp='# Transport: GeoRouteWARP'
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'WarpNetwork.ps1'),[ref]$tokens,[ref]$errors)
 Assert (-not $errors.Count) 'Network worker parses in Windows PowerShell'
 foreach($function in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($function.Extent.Text))}
 # Real hosts/state code, disposable files. No system networking commands execute.
 function Clear-DnsClientCache {}
 function Own-Adapter($State){return $null}
 function Own-Core($State){return $null}
 $before="127.0.0.1 localhost`r`n# my own rule`r`n1.1.1.1 custom.example`r`n"
 [IO.File]::WriteAllBytes($hostsPath,$encoding.GetBytes($before))
 $profile=@{id='test';map=@(@{domain='gemini.google.com';address='37.221.93.141'},@{domain='www.google.com';address='37.221.93.141'})}
 Save-Json (Join-Path $private 'settings.json') @{schema=1;ownerSid='S-1-5-21-1-2-3-1001';profile=$profile;extraRoutes=@()}
 Save-Json $statePath @{corePid=0;adapterGuid='';addresses=@();blockHash='';baseBytes=''}
 function Own-Adapter($State){return 1}
 function Own-Core($State){return 1}
 $null=Apply-Hosts
 Assert ([IO.File]::ReadAllText($hostsPath).Contains('37.221.93.141 www.google.com')) 'Same-IP verification host is applied'
 function Own-Adapter($State){return $null}
 function Own-Core($State){return $null}
 $null=Stop-Network
 Assert ([IO.File]::ReadAllText($hostsPath) -ceq $before) 'Disconnect restores original hosts byte for byte'
 # External edits survive both disconnect and another controller startup cleanup.
 Save-Json $statePath @{corePid=0;adapterGuid='';addresses=@();blockHash='';baseBytes=''}
 function Own-Adapter($State){return 1}
 function Own-Core($State){return 1}
 $null=Apply-Hosts
 $changed=[IO.File]::ReadAllText($hostsPath).Replace('37.221.93.141 www.google.com','143.20.64.192 www.google.com')
 [IO.File]::WriteAllText($hostsPath,$changed,$encoding)
 function Own-Adapter($State){return $null}
 function Own-Core($State){return $null}
 $null=Stop-Network;$null=Stop-Network
 Assert ([IO.File]::ReadAllText($hostsPath) -ceq $changed) 'Externally edited hosts survive repeated cleanup'
 # Configuration has neither default-route management nor DNS interception nor listener ports.
 $config=New-CoreConfig ([pscustomobject]@{name='WARP-GeoHide'}) 'Physical test'
 Assert (-not $config.tun.'auto-route' -and -not $config.tun.'strict-route' -and -not $config.tun.'auto-redirect') 'No global route/firewall handling'
 Assert (-not $config.dns.enable -and $config.tun.'dns-mode' -eq 'disabled' -and -not $config.tun.'dns-hijack'.Count) 'No DNS changes'
 Assert (-not $config.ContainsKey('port') -and -not $config.ContainsKey('socks-port') -and -not $config.ContainsKey('mixed-port')) 'No open proxy port'
 . (Join-Path $root 'WarpUI.ps1')
 [IO.File]::WriteAllText((Join-Path $temp 'GUI-settings.json'),'{"WarpPreferred":true}')
 $state=[pscustomobject]@{Installed=$true;CanControl=$true;Connected=$false;Requested=$false;State='off';ProfileName='Saved route'}
 $warpHome=Get-WarpHomeState $temp '' $state
 Assert ($warpHome.CanConnect -and -not $warpHome.On) 'Home can connect saved WARP route even without physical monitor results'
 $state.Requested=$true;$state.State='retrying'
 Assert ((Get-WarpHomeState $temp '' $state).On) 'Retrying remains switchable off'
 Assert ($null -eq (Get-WarpHomeState $temp "# BEGIN CHATGPT-US-WINDOWS`nnormal profile" $state)) 'An independently applied normal profile retains its own controls'
 function Get-WarpState {return $script:fakeWarpState}
 $script:fakeWarpState=[pscustomobject]@{Connected=$true;RouteAddresses=@('37.221.93.141')}
 $node=[pscustomobject]@{Address='37.221.93.141';Transport='Warp'}
 $script:warpObservationState=$null
 Assert (Test-WarpObservationContext $node) 'WARP result is valid while its route is active'
 $script:fakeWarpState.Connected=$false;$script:warpObservationState=$null
 Assert (-not(Test-WarpObservationContext $node)) 'Disconnect cannot reuse WARP success for a direct connection'
 $node.Transport='Physical'
 Assert (Test-WarpObservationContext $node) 'Direct result remains valid when WARP is off'
 Write-Output 'WARP: real hosts apply/cleanup, external edits across restart, narrow core configuration and home controls passed; system untouched.'
}finally{
 $full=[IO.Path]::GetFullPath($temp)
 if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^georoute-warp-[a-f0-9]{32}$'){throw 'Unsafe cleanup'}
 if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
