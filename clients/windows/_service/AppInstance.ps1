#Requires -Version 5.1
function Close-GeoRouteInstance($Instance) {
 if(-not $Instance){return}
 if($Instance.Mutex){
  if($Instance.IsOwner){try{$Instance.Mutex.ReleaseMutex()}catch [ApplicationException]{}}
  $Instance.Mutex.Dispose();$Instance.Mutex=$null
 }
 if($Instance.Event){$Instance.Event.Dispose();$Instance.Event=$null}
 if($Instance.InstallerMutex){$Instance.InstallerMutex.Dispose();$Instance.InstallerMutex=$null}
}
function New-GeoRouteInstance([string]$Root,[switch]$Repair,[switch]$Background,[string]$ActivationName) {
 $state=[pscustomobject]@{IsOwner=$true;Mutex=$null;Event=$null;InstallerMutex=$null}
 # Setup/Uninstall can ask the user to close GeoRoute without killing PowerShell.
 $state.InstallerMutex=[Threading.Mutex]::new($false,'Local\GeoRoute.Setup.Application')
 if($ActivationName){$state.Event=[Threading.EventWaitHandle]::OpenExisting($ActivationName);return $state}
 # Retain compatibility when an older installed EXE hosts this script.
 if('NextDNS.Desktop.DesktopInstance' -as [type]){return $state}
 $sha=[Security.Cryptography.SHA256]::Create()
 try {$hash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Root).ToLowerInvariant()))).Replace('-','').Substring(0,24)}finally{$sha.Dispose()}
 $name='Local\NextDNS.Manager.'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value+'.'+$hash+$(if($Repair){'.Repair'}else{'.Main'})
 $created=$false
 try {
  $state.Event=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::AutoReset,($name+'.Activate'))
  $state.Mutex=[Threading.Mutex]::new($true,$name,[ref]$created)
  $state.IsOwner=$created
  if(-not $created){if(-not $Background){$state.Event.Set()|Out-Null};Close-GeoRouteInstance $state}
  return $state
 }catch{Close-GeoRouteInstance $state;throw}
}
