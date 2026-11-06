#Requires -Version 5.1
function Initialize-GeoRouteProfiles([string]$Root) {
 . (Join-Path $PSScriptRoot 'ProfileMigration.ps1')
 $defaults=Join-Path $Root 'defaults'
 # MSI owns only defaults. User profiles are outside its file ownership graph.
 foreach($source in @(if(Test-Path -LiteralPath $defaults -PathType Container){Get-ChildItem -LiteralPath $defaults -Recurse -File})){
  $relative=$source.FullName.Substring(([IO.Path]::GetFullPath($defaults).TrimEnd('\')+'\').Length)
  $target=Join-Path $Root $relative
  if(Test-Path -LiteralPath $target){continue}
  [IO.Directory]::CreateDirectory((Split-Path $target -Parent))|Out-Null
  $temporary=$target+'.seed-'+[guid]::NewGuid().ToString('N')+'.tmp'
  try {
   [IO.File]::Copy($source.FullName,$temporary,$false)
   try {[IO.File]::Move($temporary,$target)}catch [IO.IOException]{if(-not(Test-Path -LiteralPath $target)){throw}}
  } finally {if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
 }
 Update-GeoRouteBundledProfiles $Root
}
