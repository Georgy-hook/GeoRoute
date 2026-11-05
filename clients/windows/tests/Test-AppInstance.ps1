#Requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\_service\AppInstance.ps1')
$root=Join-Path $env:TEMP ('GeoRouteInstance-'+[guid]::NewGuid().ToString('N'))
$first=$null;$second=$null;$repair=$null
try {
 $first=New-GeoRouteInstance -Root $root
 if(-not $first.IsOwner){throw 'First instance was rejected'}
 $second=New-GeoRouteInstance -Root $root.ToUpperInvariant()
 if($second.IsOwner){throw 'Duplicate instance was accepted'}
 if(-not $first.Event.WaitOne(0) -or $first.Event.WaitOne(0)){throw 'Activation event/reset failed'}
 $second=New-GeoRouteInstance -Root $root -Background
 if($second.IsOwner -or $first.Event.WaitOne(0)){throw 'Background duplicate changed visibility'}
 $repair=New-GeoRouteInstance -Root $root -Repair
 if(-not $repair.IsOwner){throw 'Repair scope collided with main GUI'}
 Close-GeoRouteInstance $repair
 Close-GeoRouteInstance $first
 $first=New-GeoRouteInstance -Root $root
 if(-not $first.IsOwner){throw 'Instance was not released on exit'}
 Write-Output '6 app instance checks passed: ownership, case, activation, background, repair and release.'
}finally{Close-GeoRouteInstance $second;Close-GeoRouteInstance $repair;Close-GeoRouteInstance $first}
