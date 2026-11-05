#Requires -Version 5.1
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '..\_service\NextDNS.Launcher.cs'
$probe=@'
namespace NextDNS.Desktop {
 public static class LauncherProbe {
  public static string Arguments(string path,string[] args) {
   return (string)typeof(Program).GetMethod("Arguments",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Static).Invoke(null,new object[]{path,args});
  }
 }
}
'@
Add-Type -TypeDefinition ([IO.File]::ReadAllText($source)+[Environment]::NewLine+$probe) -ReferencedAssemblies @('System.dll','System.Core.dll','System.Windows.Forms.dll')
$root=Join-Path $env:TEMP ('GeoRouteArgs-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$stub=Join-Path $root 'argument receiver.ps1'
[IO.File]::WriteAllText($stub,'param([switch]$SmokeTest,[string]$PreviewPath) [ordered]@{Smoke=[bool]$SmokeTest;Value=$PreviewPath}|ConvertTo-Json -Compress',[Text.UTF8Encoding]::new($true))
try {
 foreach($value in @('C:\path with spaces\file.png','quote"and\trailing\',('semi;dollar$'+"'"+'brackets[]'))){
  $arguments=[NextDNS.Desktop.LauncherProbe]::Arguments($stub,[string[]]@('-SmokeTest','-PreviewPath',$value))
  $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'),$arguments)
  $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true
  $child=[Diagnostics.Process]::Start($start)
  $result=$child.StandardOutput.ReadToEnd() | ConvertFrom-Json
  $child.WaitForExit()
  if($child.ExitCode -ne 0 -or -not $result.Smoke -or $result.Value -cne $value){throw 'Launcher argument did not round-trip as data'}
  $child.Dispose()
 }
 foreach($arguments in @([string[]]@('-Command','anything'),[string[]]@('-PreviewPath'))){
  $rejected=$false;try{[NextDNS.Desktop.LauncherProbe]::Arguments($stub,$arguments)|Out-Null}catch{$rejected=$true}
  if(-not $rejected){throw 'Unsupported launcher arguments were accepted'}
 }
 if(-not [NextDNS.Desktop.DesktopInstance]::Acquire($root,$false,$false)){throw 'Cannot acquire test instance'}
 $event=[Threading.EventWaitHandle]::OpenExisting([NextDNS.Desktop.DesktopInstance]::ActivationName)
 try {$event.Set()|Out-Null;if(-not [NextDNS.Desktop.DesktopInstance]::ConsumeActivation() -or [NextDNS.Desktop.DesktopInstance]::ConsumeActivation()){throw 'Activation event did not reset'}}finally{$event.Dispose()}
 Write-Output '6 launcher protocol checks passed: argument data, rejection and activation IPC.'
}finally{
 [NextDNS.Desktop.DesktopInstance]::Dispose()
 $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
 if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^GeoRouteArgs-[a-f0-9]{32}$'){throw 'Unexpected test path'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
