#Requires -Version 5.1
function New-GeoCheckDetails($Row,$Owner) {
    [xml]$xml=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'GeoCheckDetails.xaml'))
    $reader=[Xml.XmlNodeReader]::new($xml)
    try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    if($Owner){$window.Owner=$Owner}
    $area=[Windows.SystemParameters]::WorkArea
    $window.Width=[Math]::Min(780,$area.Width-24)
    $window.Height=[Math]::Min(690,$area.Height-24)
    # Keep the displayed timestamp, history and diagnosis from one observation,
    # even if a background monitor completes while this dialog is open.
    $snapshot=[ordered]@{}
    foreach($property in $Row.PSObject.Properties){$snapshot[$property.Name]=$property.Value}
    $window.DataContext=[pscustomobject]$snapshot
    $window.FindName('CloseDetails').Add_Click({param($sender,$eventArgs) $sender.Tag.Close()})
    $window.FindName('CloseDetails').Tag=$window
    return $window
}
function Show-GeoCheckDetails($Row) {
    $dialog=New-GeoCheckDetails $Row $script:taskWindow
    try{[void]$dialog.ShowDialog()}finally{$dialog.Close()}
}
function Initialize-GeoHistoryAction {
    $script:taskUi.GeoGrid.AddHandler([Windows.Controls.Button]::ClickEvent,[Windows.RoutedEventHandler]{
        param($sender,$eventArgs)
        if($eventArgs.OriginalSource -is [Windows.Controls.Button] -and $eventArgs.OriginalSource.Tag -eq 'GeoHistory'){
            $eventArgs.Handled=$true
            Show-GeoCheckDetails $eventArgs.OriginalSource.DataContext
        }
    })
}
