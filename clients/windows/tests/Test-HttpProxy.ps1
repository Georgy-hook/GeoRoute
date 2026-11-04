#Requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\_service\HttpProxy.ps1')
$before=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings','AutoConfigURL',$null)
foreach($invalid in @('127.0.0.1:80','10.0.0.1:80','192.168.1.1:80','172.16.1.1:80','169.254.1.1:80','0.0.0.0:80','224.0.0.1:80','64.118.155.2:0','64.118.155.2:65536','64.118.155.2:22222; DIRECT','user:pass@64.118.155.2:22222','https://64.118.155.2:22222','64.118.155.999:22222')) {
 $rejected=$false;try{ConvertTo-ChatGptProxyEndpoint $invalid|Out-Null}catch{$rejected=$true}
 if(-not $rejected){throw ('Unsafe endpoint accepted: '+$invalid)}
}
$url=Get-ChatGptProxyDataUrl '64.118.155.2:22222'
$pac=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($url.Split(',')[1]))
if($pac -cne (Get-ChatGptProxyPac '64.118.155.2:22222')){throw 'PAC data URL changed the routing script.'}
$temp=[IO.Path]::GetTempFileName()
try {
 [IO.File]::WriteAllText($temp,$pac,[Text.UTF8Encoding]::new($false))
 & node.exe (Join-Path $PSScriptRoot 'test_proxy_pac.cjs') $temp
 if($LASTEXITCODE -ne 0){throw 'PAC boundary checks failed.'}
} finally {Remove-Item -LiteralPath $temp -Force}
$after=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings','AutoConfigURL',$null)
if($before -cne $after){throw 'A read-only routing test changed Windows settings.'}
Write-Output 'Proxy endpoint validation and data URL checks passed; Windows settings unchanged.'
