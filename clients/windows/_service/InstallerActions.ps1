#Requires -Version 5.1
# Only MSI uninstall invokes this fixed action; networking is never changed.
$ErrorActionPreference='Stop'
$entry=Join-Path (Split-Path $PSScriptRoot -Parent) 'GeoRoute.cmd'
$own='"'+$env:ComSpec+'" /d /s /c ""'+$entry+'" -Tray"'
$key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$name='NextDNS Connection Manager'
$value=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run',$name,'')
if($value -ieq $own){Remove-ItemProperty -LiteralPath $key -Name $name}
