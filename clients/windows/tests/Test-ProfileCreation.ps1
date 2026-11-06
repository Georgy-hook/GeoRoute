$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
. (Join-Path $source 'ProfileCreation.ps1')
function Assert($Value,$Message){if(-not $Value){throw $Message}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('georoute-create-'+[guid]::NewGuid().ToString('N'))
$hosts=Join-Path $env:SystemRoot 'System32/drivers/etc/hosts'
$before=(Get-FileHash -LiteralPath $hosts).Hash
$shell=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
try{
    [IO.Directory]::CreateDirectory($temp)|Out-Null
    foreach($name in @('Profiles.ps1','ProfileCreation.ps1','GeoServices.ps1','GuiWorker.ps1','profiles.json')){Copy-Item -LiteralPath (Join-Path $source $name) -Destination $temp}
    Copy-Item -LiteralPath (Join-Path $source 'profiles') -Destination $temp -Recurse
    Add-Type -AssemblyName PresentationFramework
    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'NextDNS-GUI.ps1'),[ref]$tokens,[ref]$parseErrors)
    foreach($functionName in @('Get-TaskProfileInput','Set-TaskProfileInputMode')){
        $functionAst=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $functionName},$true)
        Invoke-Expression $functionAst.Extent.Text
    }
    [xml]$xaml=Get-Content -LiteralPath (Join-Path $source 'ImportDialog.xaml') -Raw -Encoding UTF8
    $reader=[Xml.XmlNodeReader]::new($xaml)
    try{$dialog=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    $ui=@{};foreach($node in $xaml.SelectNodes('//*[@*[local-name()="Name"]]')){$name=$node.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml');$ui[$name]=$dialog.FindName($name)}
    $script:taskImport=@{Ui=$ui;SourcePath=''}
    $ui.ServerAddressBox.Text=' 37.221.93.128 '
    $ui.CountryBox.SelectedItem=@($ui.CountryBox.Items|Where-Object Tag -eq 'DE')[0]
    $formData=Get-TaskProfileInput
    Assert ($formData.InputKind -eq 'Address' -and $formData.Service -eq 'GeoHide' -and $formData.Address -eq '37.221.93.128' -and $formData.Name -eq 'GeoHide — Германия') 'Actual dialog creates one profile for both services without a service selector'
    $ui.CreateFromFile.IsChecked=$true;Set-TaskProfileInputMode
    Assert ($ui.FilePanel.Visibility -eq 'Visible' -and $ui.AddressPanel.Visibility -eq 'Collapsed') 'File mode replaces address fields'
    $ui.CreateByIP.IsChecked=$true;Set-TaskProfileInputMode
    Assert ($ui.AddressPanel.Visibility -eq 'Visible' -and $ui.ServerAddressBox.Text -eq ' 37.221.93.128 ') 'Switching modes preserves typed input'
    $dialog.Close()
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    function Save-ThroughWorker($Tag,$Address,$Service,$InputKind='Address',$SourcePath=''){
        $result=Join-Path $temp ($Tag+'.result.json')
        $request=Join-Path $temp ($Tag+'.request.json')
        $data=@{Mode='Import';ProfileId='';InputKind=$InputKind;Address=$Address;Service=$Service;SourcePath=$SourcePath;Name='';CountryCode='DE';Region='Германия';ExpectedUserSid=$sid;ResultPath=$result;LogPath=(Join-Path $temp ($Tag+'.log'))}
        if($InputKind -eq 'File'){$data.Name='From file'}
        [IO.File]::WriteAllText($request,($data|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $temp 'GuiWorker.ps1') -RequestPath $request | Out-Null
        Assert (Test-Path -LiteralPath $result) 'Worker returns a structured result'
        return (Get-Content -LiteralPath $result -Raw -Encoding UTF8|ConvertFrom-Json)
    }
    $gemini=Save-ThroughWorker 'geohide' ' 37.221.93.128 ' 'GeoHide'
    Assert ($gemini.Status -eq 'ok') 'Address creation works through the actual GUI worker/backend boundary'
    $catalog=Get-Content -LiteralPath (Join-Path $temp 'profiles.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $entry=@($catalog.Profiles|Where-Object id -eq $gemini.ProfileId)[0]
    Assert ($entry.name -eq 'GeoHide — Германия' -and $entry.countryCode -eq 'DE' -and $entry.service -eq 'GeoHide') 'Name, flag and combined service are saved'
    $text=Get-Content -LiteralPath (Join-Path $temp $entry.hostsFile) -Raw -Encoding UTF8
    Assert ($text -match '37.221.93.128 gemini.google.com' -and $text -match '37.221.93.128 chatgpt.com' -and $text -match '37.221.93.128 www.google.com') 'One profile uses the same server for both services and Google verification'
    $chat=Save-ThroughWorker 'chat' '143.20.64.192' 'ChatGPT'
    Assert ($chat.Status -eq 'ok') 'ChatGPT profile is saved'
    $catalog=Get-Content -LiteralPath (Join-Path $temp 'profiles.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $entry=@($catalog.Profiles|Where-Object id -eq $chat.ProfileId)[0]
    $text=Get-Content -LiteralPath (Join-Path $temp $entry.hostsFile) -Raw -Encoding UTF8
    Assert ($text -match '143.20.64.192 chatgpt.com' -and $text -match '143.20.64.192 files.oaiusercontent.com' -and $text -match '143.20.64.192 sdmntprwestcentralus.oaiusercontent.com') 'ChatGPT includes known attachment hosts'
    Assert ($text -notmatch 'gemini.google.com') 'Service choice does not route the other service'
    $catalogHash=(Get-FileHash -LiteralPath (Join-Path $temp 'profiles.json')).Hash
    $i=0
    foreach($invalid in @('127.0.0.1','10.0.0.1','https://37.221.93.128','37.221.93.128:443','not-an-ip','')){
        $i++;$result=Save-ThroughWorker ('bad'+$i) $invalid 'Gemini'
        Assert ($result.Status -eq 'error') ('Invalid address rejected: '+$invalid)
        Assert ((Get-FileHash -LiteralPath (Join-Path $temp 'profiles.json')).Hash -eq $catalogHash) 'Rejected input never changes the profile catalog'
    }
    $ipv6=New-GeoServiceHosts '2606:4700:4700::1111' 'Gemini'
    Assert ($ipv6 -match '2606:4700:4700::1111 gemini.google.com') 'Public IPv6 uses the same supported address format'
    $file=Join-Path $temp 'manual.hosts'
    [IO.File]::WriteAllText($file,'37.221.93.128 gemini.google.com')
    Assert ((Save-ThroughWorker 'file' '' 'ChatGPT' 'File' $file).Status -eq 'ok') 'Existing file import is preserved'
    Assert ((Get-FileHash -LiteralPath $hosts).Hash -eq $before) 'Saving either kind of profile never edits system hosts'
    Write-Output 'Profile creation passed: real worker persistence, generated service domains, automatic names, validation, IPv6, unchanged system hosts and file import.'
}finally{
    $full=[IO.Path]::GetFullPath($temp)
    if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^georoute-create-[a-f0-9]{32}$'){throw 'Unsafe cleanup'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
