#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$SmokeTest,
    [switch]$Repair,
    [switch]$Tray,
    [switch]$RenderPreview,
    [string]$PreviewPath,
    [ValidateRange(900,2000)][int]$PreviewWidth = 1160,
    [ValidateRange(560,1500)][int]$PreviewHeight = 910,
    [string]$HealthSnapshotPath,
    [ValidatePattern('^Local\\NextDNS\.Manager\.S-\d+(?:-\d+)+\.[A-F0-9]{24}\.(?:Main|Repair)\.Activate$')][string]$ActivationEvent
)
$ErrorActionPreference = 'Stop'
if(-not('GeoRouteDpi' -as [type])){
 Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class GeoRouteDpi { [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value); public static void Enable(){try{SetThreadDpiAwarenessContext(new IntPtr(-4));}catch(EntryPointNotFoundException){}} }'
}
[GeoRouteDpi]::Enable()
$script:taskRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $script:taskRoot 'AppInstance.ps1')
$script:taskInstance=$null
$script:taskActivationEvent=$null
if(-not $SmokeTest -and -not $RenderPreview){
 $script:taskInstance=New-GeoRouteInstance -Root $script:taskRoot -Repair:$Repair -Background:$Tray -ActivationName $ActivationEvent
 if(-not $script:taskInstance.IsOwner){return}
 $script:taskActivationEvent=$script:taskInstance.Event
}
if($Repair){try{ & (Join-Path $PSScriptRoot 'RepairCenter.ps1') -SmokeTest:$SmokeTest }finally{Close-GeoRouteInstance $script:taskInstance};return}
$script:taskShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:taskUi = @{}
$script:taskBusy = $false
$script:taskRun = $null
$script:taskWindow = $null
$script:taskTimer = $null
$script:taskSettingsPath = Join-Path $script:taskRoot 'GUI-settings.json'
$script:taskLastHostsRead = [datetime]::MinValue
$script:taskLastSnapshot = ''
$script:taskReducedMotion = $false
$script:taskExpectedNames = @()
$script:taskClosing = $false
$script:taskProfiles = @()
$script:taskProfileControls = @{}
$script:taskActiveProfileId = ''
$script:taskCatalogStamp = ''
$script:taskImport = $null
$script:taskSelectedProfileId = ''
$script:taskPage = 'Overview'
$script:taskEvents = [Collections.Generic.List[object]]::new()
$script:taskLogFilter = 'All'
$script:taskHealthRun = $null
$script:taskHealthAt = $null
$script:taskAppLaunchTarget = ''
$script:taskCleanupRun = $null
. (Join-Path $PSScriptRoot 'Connection.ps1')
. (Join-Path $PSScriptRoot 'ProfileCreation.ps1')
. (Join-Path $PSScriptRoot 'Tray.ps1')
. (Join-Path $PSScriptRoot 'GeoHideUI.ps1')

function Get-TaskBrush([string]$Color) {
    return [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

function Register-TaskDarkTitleBar($Window) {
    $Window.Add_SourceInitialized({
        param($sender,$eventArgs)
        try {
            $taskHandle = [Windows.Interop.WindowInteropHelper]::new($sender).Handle
            [NextDnsWindowChrome]::EnableDarkTitleBar($taskHandle)
        }
        catch { }
    })
}

function Register-TaskDialogKeys($Window) {
    $Window.Add_PreviewKeyDown({
        param($sender,$eventArgs)
        if($eventArgs.Key -eq [Windows.Input.Key]::Escape) {
            $eventArgs.Handled = $true
            try { $sender.DialogResult = $false } catch { $sender.Close() }
        }
    })
}

function Get-TaskImage([string]$Name) {
    $taskPath = Join-Path $script:taskRoot ('assets\' + $Name)
    $taskUiPath = Join-Path $script:taskRoot ('assets\ui\' + $Name)
    if (Test-Path -LiteralPath $taskUiPath) { $taskPath = $taskUiPath }
    if (-not (Test-Path -LiteralPath $taskPath)) { return $null }
    $taskImage = [Windows.Media.Imaging.BitmapImage]::new()
    $taskImage.BeginInit()
    $taskImage.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $taskImage.UriSource = [uri]$taskPath
    $taskImage.EndInit()
    $taskImage.Freeze()
    return $taskImage
}

function Get-TaskRecordsLabel([int]$Count) {
    $taskRemainder = $Count % 100
    $taskWord = if ($taskRemainder -ge 11 -and $taskRemainder -le 14) { 'записей' } elseif ($Count % 10 -eq 1) { 'запись' } elseif ($Count % 10 -ge 2 -and $Count % 10 -le 4) { 'записи' } else { 'записей' }
    return ($Count.ToString() + ' ' + $taskWord)
}

function Get-TaskMap([string]$Text) {
    $taskMap = [Collections.Generic.List[string]]::new()
    foreach ($taskLine in ($Text -split '\r?\n')) {
        $taskActive = ($taskLine -split '#',2)[0].Trim()
        if (-not $taskActive) { continue }
        $taskParts = @($taskActive -split '\s+')
        $taskAddress = $null
        if ($taskParts.Count -lt 2 -or -not [Net.IPAddress]::TryParse($taskParts[0],[ref]$taskAddress)) { throw 'В hosts найдена строка без корректного IP-адреса и домена.' }
        foreach ($taskName in ($taskParts | Select-Object -Skip 1)) {
            if ($taskName -notmatch '^[a-zA-Z0-9.-]+$') { throw 'В hosts найдено некорректное имя домена.' }
            $taskMap.Add($taskAddress.ToString() + ' ' + $taskName.ToLowerInvariant())
        }
    }
    return @($taskMap | Sort-Object)
}

function Add-TaskButtonMotion($Button) {
    $Button.RenderTransform = [Windows.Media.TranslateTransform]::new()
    $Button.Add_MouseEnter({
        param($sender,$eventArgs)
        if (-not $script:taskReducedMotion -and $sender.IsEnabled) {
            $taskAnimation = [Windows.Media.Animation.DoubleAnimation]::new(-2,[Windows.Duration]::new([timespan]::FromMilliseconds(160)))
            $taskAnimation.EasingFunction = [Windows.Media.Animation.QuadraticEase]::new()
            $sender.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty,$taskAnimation)
        }
    })
    $Button.Add_MouseLeave({
        param($sender,$eventArgs)
        if (-not $script:taskReducedMotion) {
            $taskAnimation = [Windows.Media.Animation.DoubleAnimation]::new(0,[Windows.Duration]::new([timespan]::FromMilliseconds(180)))
            $taskAnimation.EasingFunction = [Windows.Media.Animation.QuadraticEase]::new()
            $sender.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty,$taskAnimation)
        }
    })
}

function Load-TaskProfiles([switch]$Force) {
    $taskCatalogPath = Join-Path $script:taskRoot 'profiles.json'
    $taskStamp = if (Test-Path -LiteralPath $taskCatalogPath) { [IO.File]::GetLastWriteTimeUtc($taskCatalogPath).ToString('o') } else { 'legacy' }
    if (-not $Force -and $taskStamp -eq $script:taskCatalogStamp) { return }
    $taskCatalog = if ($taskStamp -ne 'legacy') { [IO.File]::ReadAllText($taskCatalogPath,[Text.Encoding]::UTF8) | ConvertFrom-Json } else {
        [pscustomobject]@{Profiles=@(
            [pscustomobject]@{id='primary';name='США · основной';region='США';countryCode='US';hostsFile='ChatGPT-US-primary.hosts';description='Основной US-сервер';verifiedAt=$null},
            [pscustomobject]@{id='alternate';name='США · запасной';region='США';countryCode='US';hostsFile='ChatGPT-US-alternate.hosts';description='Запасной US-сервер';verifiedAt=$null}
        )}
    }
    $taskProfiles = @()
    foreach ($taskProfile in @($taskCatalog.Profiles)) {
        if (-not $taskProfile.id -or -not $taskProfile.name -or -not $taskProfile.hostsFile) { throw 'Каталог профилей содержит неполную запись.' }
        $taskFile = [IO.Path]::GetFullPath((Join-Path $script:taskRoot $taskProfile.hostsFile))
        $taskServicePrefix = [IO.Path]::GetFullPath($script:taskRoot).TrimEnd('\') + '\'
        if (-not $taskFile.StartsWith($taskServicePrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Служебный файл профиля должен находиться в папке приложения.' }
        $taskMap = @(Get-TaskMap ([IO.File]::ReadAllText($taskFile)))
        $taskAddresses = @($taskMap | ForEach-Object { ($_ -split ' ')[0] } | Select-Object -Unique)
        $taskProfiles += [pscustomobject]@{Id=[string]$taskProfile.id;Name=[string]$taskProfile.name;CountryCode=[string]$taskProfile.countryCode;Region=[string]$taskProfile.region;Description=[string]$taskProfile.description;VerifiedAt=[string]$taskProfile.verifiedAt;Map=$taskMap;MapKey=($taskMap -join "`n");Addresses=$taskAddresses;Count=$taskMap.Count}
    }
    if ($taskProfiles.Count -eq 0) { throw 'Каталог профилей пуст. Добавьте сервер из файла .hosts.' }
    $script:taskProfiles = $taskProfiles
    $script:taskCatalogStamp = $taskStamp
    $script:taskUi.ProfilesPanel.Children.Clear()
    $script:taskProfileControls = @{}
    foreach ($taskProfile in $script:taskProfiles) {
        $taskCard = [Windows.Controls.Border]::new()
        $taskCard.Height = 190
        $taskCard.Margin = [Windows.Thickness]::new(0,0,12,12)
        $taskCard.Padding = [Windows.Thickness]::new(15,12,15,12)
        $taskCard.CornerRadius = [Windows.CornerRadius]::new(20)
        $taskCard.BorderThickness = [Windows.Thickness]::new(1)
        $taskCard.BorderBrush = Get-TaskBrush '#28384E'
        $taskCard.Background = Get-TaskBrush '#131E2C'
        $taskCard.ToolTip = $taskProfile.Description
        $taskGrid = [Windows.Controls.Grid]::new()
        foreach ($taskHeight in @(40,29,48,40)) { $taskRow = [Windows.Controls.RowDefinition]::new(); $taskRow.Height = [Windows.GridLength]::new($taskHeight); $taskGrid.RowDefinitions.Add($taskRow) }
        $taskHeading = [Windows.Controls.Grid]::new()
        $taskColumn = [Windows.Controls.ColumnDefinition]::new(); $taskColumn.Width = [Windows.GridLength]::new(70); $taskHeading.ColumnDefinitions.Add($taskColumn)
        $taskColumn = [Windows.Controls.ColumnDefinition]::new(); $taskHeading.ColumnDefinitions.Add($taskColumn)
        $taskFlag = [Windows.Controls.Image]::new(); $taskFlag.Width = 64; $taskFlag.Height = 44; $taskFlag.HorizontalAlignment = 'Left'; $taskFlag.Stretch = 'Uniform'
        [Windows.Media.RenderOptions]::SetBitmapScalingMode($taskFlag,[Windows.Media.BitmapScalingMode]::HighQuality)
        $taskFlag.SnapsToDevicePixels = $true
        $taskFlag.Source = Get-TaskImage ('flag-' + $taskProfile.CountryCode + '.png')
        if (-not $taskFlag.Source) { $taskFlag.Source = Get-TaskImage 'icon-globe.png' }
        [Windows.Automation.AutomationProperties]::SetName($taskFlag, $taskProfile.Region)
        [void]$taskHeading.Children.Add($taskFlag)
        $taskNames = [Windows.Controls.StackPanel]::new(); $taskNames.VerticalAlignment = 'Center'; [Windows.Controls.Grid]::SetColumn($taskNames,1)
        $taskTitle = [Windows.Controls.TextBlock]::new(); $taskTitle.Text = $taskProfile.Name; $taskTitle.FontSize = 15; $taskTitle.FontWeight = 'SemiBold'; $taskTitle.TextTrimming = 'CharacterEllipsis'; $taskTitle.ToolTip = $taskProfile.Name
        $taskActive = [Windows.Controls.TextBlock]::new(); $taskActive.Text = 'ВЫБРАН В HOSTS'; $taskActive.FontSize = 8; $taskActive.FontWeight = 'Bold'; $taskActive.Foreground = Get-TaskBrush '#91F2D2'; $taskActive.Margin = [Windows.Thickness]::new(0,4,0,0); $taskActive.Visibility = 'Collapsed'
        [void]$taskNames.Children.Add($taskTitle); [void]$taskNames.Children.Add($taskActive); [void]$taskHeading.Children.Add($taskNames); [void]$taskGrid.Children.Add($taskHeading)
        $taskAddressLabel = [Windows.Controls.TextBlock]::new(); $taskAddressLabel.FontFamily = [Windows.Media.FontFamily]::new('Consolas'); $taskAddressLabel.FontSize = 12; $taskAddressLabel.Foreground = Get-TaskBrush '#91AAC3'; $taskAddressLabel.VerticalAlignment = 'Center'
        $taskAddressLabel.Text = if ($taskProfile.Addresses.Count -eq 1) { $taskProfile.Addresses[0] } else { 'Карта из ' + $taskProfile.Addresses.Count + ' IP-адресов' }
        $taskAddressLabel.ToolTip = $taskProfile.Addresses -join ', '
        [Windows.Controls.Grid]::SetRow($taskAddressLabel,1); [void]$taskGrid.Children.Add($taskAddressLabel)
        $taskAvailability = [Windows.Controls.TextBlock]::new(); $taskAvailability.FontSize=11; $taskAvailability.TextWrapping='Wrap'; $taskAvailability.VerticalAlignment='Center'; [Windows.Controls.Grid]::SetRow($taskAvailability,2); [void]$taskGrid.Children.Add($taskAvailability)
        $taskButton = [Windows.Controls.Button]::new(); $taskButton.Content = 'Выбрать'; $taskButton.Tag = $taskProfile.Id; $taskButton.Style = $script:taskWindow.FindResource('ActionButton'); $taskButton.FontSize = 12; $taskButton.Padding = [Windows.Thickness]::new(12,7,12,7); $taskButton.IsEnabled = -not $script:taskBusy
        [Windows.Automation.AutomationProperties]::SetName($taskButton,('Выбрать профиль ' + $taskProfile.Name))
        $taskButton.ToolTip = (Get-TaskRecordsLabel $taskProfile.Count) + '. ' + $taskProfile.Description
        $taskButton.Add_Click({ param($sender,$eventArgs) Select-TaskProfile ([string]$sender.Tag) })
        Add-TaskButtonMotion $taskButton
        [Windows.Controls.Grid]::SetRow($taskButton,3); [void]$taskGrid.Children.Add($taskButton)
        $taskCard.Child = $taskGrid
        [void]$script:taskUi.ProfilesPanel.Children.Add($taskCard)
        $script:taskProfileControls[$taskProfile.Id] = @{Card=$taskCard;Button=$taskButton;Active=$taskActive;Status=$taskAvailability}
    }
    Update-GeoProfileCards
    $script:taskUi.ProfileCountText.Text = 'Профилей: ' + $script:taskProfiles.Count.ToString() + ' · можно добавить свой .hosts'
}

function Add-TaskLog([string]$Message, [datetime]$At = [datetime]::MinValue, [ValidateSet('','Info','Actions','Problems')][string]$Kind = '') {
    if (-not $Message) { return }
    $Message = $Message -replace '(https?://[^\s?]+)\?[^\s]+','$1?[параметры скрыты]' -replace '(?i)(authorization|cookie|set-cookie|access_token|refresh_token|api[_-]?key)\s*[:=]\s*[^\r\n]+','$1: [скрыто]'
    $taskKind = if($Kind){$Kind} elseif ($Message -match 'Ошибка|не удалось|не заверш|отмен|требует внимания') { 'Problems' } elseif ($Message -match 'Подключ|Включ|Отключ|Очищ|Обнов|Добав|Импорт|запрос|Перезап|Примен') { 'Actions' } else { 'Info' }
    $script:taskEvents.Add([pscustomobject]@{At=$(if($At -eq [datetime]::MinValue){Get-Date}else{$At});Message=$Message.TrimEnd();Kind=$taskKind})
    if ($script:taskEvents.Count -gt 800) { $script:taskEvents.RemoveAt(0) }
    Update-TaskLogView
}

function Update-TaskLogView {
    $taskQuery = if ($script:taskUi.LogSearchBox) { $script:taskUi.LogSearchBox.Text.Trim() } else { '' }
    $script:taskUi.LogBox.Items.Clear()
    foreach ($taskEntry in $script:taskEvents) {
        if ($script:taskLogFilter -ne 'All' -and $taskEntry.Kind -ne $script:taskLogFilter) { continue }
        if ($taskQuery -and $taskEntry.Message.IndexOf($taskQuery,[StringComparison]::CurrentCultureIgnoreCase) -lt 0) { continue }
        $taskRow = [Windows.Controls.Grid]::new()
        $taskRow.MinHeight = 26
        $taskColumn = [Windows.Controls.ColumnDefinition]::new(); $taskColumn.Width = [Windows.GridLength]::new(70); $taskRow.ColumnDefinitions.Add($taskColumn)
        $taskColumn = [Windows.Controls.ColumnDefinition]::new(); $taskRow.ColumnDefinitions.Add($taskColumn)
        $taskTime = [Windows.Controls.TextBlock]::new(); $taskTime.Text = $taskEntry.At.ToString('HH:mm:ss'); $taskTime.FontFamily = [Windows.Media.FontFamily]::new('Consolas'); $taskTime.FontSize = 12; $taskTime.Foreground = Get-TaskBrush '#8AA3BE'; $taskTime.VerticalAlignment = 'Top'
        $taskText = [Windows.Controls.TextBlock]::new(); $taskText.Text = $taskEntry.Message; $taskText.TextWrapping = 'Wrap'; $taskText.FontSize = 12; $taskText.Foreground = Get-TaskBrush $(if($taskEntry.Kind -eq 'Problems'){'#F2C990'}elseif($taskEntry.Kind -eq 'Actions'){'#B1DCCE'}else{'#B2C7DE'})
        [Windows.Controls.Grid]::SetColumn($taskText,1); [void]$taskRow.Children.Add($taskTime); [void]$taskRow.Children.Add($taskText); [void]$script:taskUi.LogBox.Items.Add($taskRow)
    }
    if ($script:taskUi.AutoScrollCheck.IsChecked -eq $true -and $script:taskUi.LogBox.Items.Count -gt 0) { $script:taskUi.LogBox.ScrollIntoView($script:taskUi.LogBox.Items[$script:taskUi.LogBox.Items.Count - 1]) }
    foreach ($taskPair in @{FilterAllButton='All';FilterErrorsButton='Problems';FilterActionsButton='Actions'}.GetEnumerator()) {
        $script:taskUi[$taskPair.Key].Background = Get-TaskBrush $(if($script:taskLogFilter -eq $taskPair.Value){'#28465A'}else{'Transparent'})
        $script:taskUi[$taskPair.Key].Foreground = Get-TaskBrush $(if($script:taskLogFilter -eq $taskPair.Value){'#C5F4E6'}else{'#9FB3CC'})
        $taskCount = if($taskPair.Value -eq 'All'){$script:taskEvents.Count}else{@($script:taskEvents | Where-Object Kind -eq $taskPair.Value).Count}
        $script:taskUi[$taskPair.Key].Content = $(switch($taskPair.Value){'All'{'Все'}'Problems'{'Проблемы'}'Actions'{'Действия'}}) + ' ' + $taskCount
    }
}

function Load-TaskHistory {
    $taskDirectory = Join-Path $script:taskRoot 'run-results'
    if(-not (Test-Path -LiteralPath $taskDirectory)) { return }
    if(((Get-Item -LiteralPath $taskDirectory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return }
    $taskFiles = @(Get-ChildItem -LiteralPath $taskDirectory -File | Where-Object { $_.Name -cmatch '^(?:gui(?:-health)?-\d{8}-\d{6}-[a-fA-F0-9]{8}|health-\d{8}-\d{6}-[a-fA-F0-9]{8}(?:\.result)?)\.json$' -and $_.Length -lt 256KB -and ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 } | Sort-Object LastWriteTime -Descending | Select-Object -First 24 | Sort-Object LastWriteTime)
    foreach($taskFile in $taskFiles) {
        try {
            $taskReport = [IO.File]::ReadAllText($taskFile.FullName,[Text.Encoding]::UTF8) | ConvertFrom-Json
            $taskAt = if($taskReport.At){[datetime]$taskReport.At}else{$taskFile.LastWriteTime}
            $taskMessage = if($taskReport.Status -eq 'error'){'Ошибка: ' + $taskReport.Error}elseif($taskReport.health){'Диагностика: ' + $taskReport.health.summary}else{[string]$taskReport.Message}
            $taskHistoryKind = if($taskReport.Status -eq 'error' -or ($taskReport.health -and $taskReport.health.status -in @('limited','offline','unknown'))){'Problems'}else{''}
            if($taskMessage) { Add-TaskLog ('История · ' + $taskReport.Mode + ' · ' + $taskMessage) -At $taskAt -Kind $taskHistoryKind }
        } catch { }
    }
}

function Select-TaskProfile([string]$ProfileId) {
    if($ProfileId){$availability=Get-GeoProfileAvailability $script:taskRoot $ProfileId $script:geoReport;if(-not $availability.Ready){$script:taskUi.SelectedProfileDetail.Text=$availability.Reason;Update-GeoProfileCards;return}}
    if ($ProfileId) { $script:taskSelectedProfileId = $ProfileId }
    if($ProfileId -and -not $SmokeTest -and -not $RenderPreview){
        $prefs=Read-GeoSettings $script:taskRoot
        if(-not $prefs.PSObject.Properties['preferredProfileId'] -or $prefs.preferredProfileId -ne $ProfileId){$prefs|Add-Member -MemberType NoteProperty -Name preferredProfileId -Value $ProfileId -Force;Write-GeoJson (Join-Path $script:taskRoot 'geohide-settings.json') $prefs}
    }
    foreach ($taskPair in $script:taskProfileControls.GetEnumerator()) {
        $taskSelected = ($taskPair.Key -eq $script:taskSelectedProfileId)
        $taskPair.Value.Card.BorderBrush = Get-TaskBrush $(if($taskSelected){'#8CC6C5'}elseif($taskPair.Key -eq $script:taskActiveProfileId){'#416B65'}else{'#2D425B'})
        $taskPair.Value.Button.Content = if($taskSelected){'Выбрано'}else{'Выбрать'}
        $taskPair.Value.Button.Background = Get-TaskBrush $(if($taskSelected){'#2C4E5E'}else{'#1A2D43'})
        $taskPair.Value.Button.Foreground = Get-TaskBrush '#DFEEF8'
    }
    $taskSelectedProfile = @($script:taskProfiles | Where-Object Id -eq $script:taskSelectedProfileId | Select-Object -First 1)
    if ($taskSelectedProfile.Count) {
        $script:taskUi.SelectedProfileText.Text = $taskSelectedProfile[0].Name
        $script:taskUi.SelectedProfileDetail.Text = (Get-TaskRecordsLabel $taskSelectedProfile[0].Count) + $(if($script:taskSelectedProfileId -eq $script:taskActiveProfileId){' · уже в hosts'}else{' · применить для подключения'})
        $script:taskUi.ApplyProfileButton.Content = if($script:taskSelectedProfileId -eq $script:taskActiveProfileId){'Применить снова'}else{'Подключить'}
    }
}

function Set-TaskPage([string]$Page) {
    $script:taskPage=$Page
    $pages=@{Home='HomePage';Overview='OverviewPage';Servers='ServersPage';Geo='GeoPage';Journal='JournalPage';Settings='SettingsPage'}
    foreach($key in $pages.Keys){$script:taskUi[$pages[$key]].Visibility=if($Page -eq $key){'Visible'}else{'Collapsed'}}
    $titles=@{Home='Подключение';Overview='Помощь';Servers='Серверы';Geo='Мониторинг';Journal='Журнал';Settings='Настройки'}
    $subtitles=@{Home='GeoRoute';Overview='Понятные действия при проблемах с подключением';Servers='Выберите доступный маршрут';Geo='Доступность узлов RU, US и EU';Journal='История действий и результаты проверок';Settings='Запуск, внешний вид и дополнительные возможности'}
    $script:taskUi.PageTitle.Text=$titles[$Page];$script:taskUi.PageSubtitle.Text=$subtitles[$Page]
    $nav=@{HomeNavButton='Home';OverviewNavButton='Overview';ServersNavButton='Servers';MonitorNavButton='Geo';JournalNavButton='Journal';SettingsNavButton='Settings'}
    foreach($name in $nav.Keys){$selected=$Page -eq $nav[$name];$script:taskUi[$name].Background=Get-TaskBrush $(if($selected){'#254550'}else{'Transparent'})}
    if(-not $script:taskReducedMotion -and -not $SmokeTest -and -not $RenderPreview){$fade=[Windows.Media.Animation.DoubleAnimation]::new(0.88,1,[Windows.Duration]::new([timespan]::FromMilliseconds(160)));$script:taskUi[$pages[$Page]].BeginAnimation([Windows.UIElement]::OpacityProperty,$fade)}
    if($Page -eq 'Home'){Update-GeoHome -Force}
}

function Read-TaskHosts {
    $taskHosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $taskText = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($taskHosts))
    $taskMatches = [regex]::Matches($taskText, '(?ms)^# BEGIN CHATGPT-US-WINDOWS\r?\n.*?^# END CHATGPT-US-WINDOWS(?:\r?\n|$)')
    if ($taskMatches.Count -eq 0 -and $taskText -notmatch '# (BEGIN|END) CHATGPT-US-WINDOWS') {
        return [pscustomobject]@{Kind='Off';Address='';Count=0;ProfileId='';Details='ChatGPT использует общие настройки DNS Windows.'}
    }
    if ($taskMatches.Count -ne 1) { throw 'Управляемый блок hosts повреждён или дублируется.' }
    $taskMap = @(Get-TaskMap $taskMatches[0].Value)
    if ($taskMap.Count -eq 0) { throw 'Управляемый блок hosts пуст.' }
    $taskNames = @($taskMap | ForEach-Object { ($_ -split ' ')[1] })
    if (@($taskNames | Select-Object -Unique).Count -ne $taskNames.Count) { throw 'В управляемом блоке hosts есть повторяющиеся домены.' }
    $taskDistinct = @($taskMap | ForEach-Object { ($_ -split ' ')[0] } | Select-Object -Unique)
    $taskOutside = [regex]::Replace($taskText, '(?ms)^# BEGIN CHATGPT-US-WINDOWS\r?\n.*?^# END CHATGPT-US-WINDOWS(?:\r?\n|$)', '')
    foreach ($taskLine in ($taskOutside -split '\r?\n')) {
        $taskActive = ($taskLine -split '#',2)[0].Trim()
        if ($taskActive) {
            foreach ($taskName in (($taskActive -split '\s+') | Select-Object -Skip 1)) {
                if ($taskName.ToLowerInvariant() -in $taskNames) { throw ('Найдена ещё одна запись hosts для ' + $taskName + '.') }
            }
        }
    }
    $taskMapKey = $taskMap -join "`n"
    $taskMatchedProfile = @($script:taskProfiles | Where-Object { $_.MapKey -ceq $taskMapKey } | Select-Object -First 1)
    $taskAddressText = if ($taskDistinct.Count -eq 1) { $taskDistinct[0] } else { 'Карта из ' + $taskDistinct.Count + ' IP-адресов' }
    if ($taskMatchedProfile.Count -eq 1) {
        return [pscustomobject]@{Kind='On';Address=$taskAddressText;Count=$taskMap.Count;ProfileId=$taskMatchedProfile[0].Id;Name=$taskMatchedProfile[0].Name;Details=('Управляемый системный hosts · ' + (Get-TaskRecordsLabel $taskMap.Count) + '.')}
    }
    return [pscustomobject]@{Kind='Unknown';Address=$taskAddressText;Count=$taskMap.Count;ProfileId='';Name='Профиль вне каталога';Details='В hosts есть управляемый блок, которого нет в списке серверов. Проверьте настройки.'}
}

function Update-TaskStatus([switch]$LogChange) {
    $script:taskLastHostsRead = Get-Date
    foreach ($taskControl in $script:taskProfileControls.Values) {
        $taskControl.Active.Visibility = 'Collapsed'
        $taskControl.Card.BorderBrush = Get-TaskBrush '#28384E'
        $taskControl.Button.Content = 'Подключить'
        $taskControl.Button.Background = Get-TaskBrush '#1B2B3E'
        $taskControl.Button.Foreground = Get-TaskBrush '#F0F5FC'
    }
    $script:taskActiveProfileId = ''
    $script:taskUi.ActiveFlag.Source = Get-TaskImage 'icon-globe.png'
    try {
        $taskCurrent = Read-TaskHosts
        $taskSnapshot = $taskCurrent.Kind + $taskCurrent.Address + $taskCurrent.ProfileId + $taskCurrent.Count
        $script:taskActiveProfileId = $taskCurrent.ProfileId
        $script:taskUi.StatusDescription.Text = $taskCurrent.Details
        $script:taskUi.StatusPill.Background = Get-TaskBrush '#1D443D'
        $script:taskUi.StatusBadge.Foreground = Get-TaskBrush '#91F2D2'
        $script:taskUi.StatusDot.Fill = Get-TaskBrush '#91F2D2'
        if ($taskCurrent.Kind -in @('On','Unknown')) {
            $script:taskUi.StatusBadge.Text = 'HOSTS ВКЛЮЧЕНЫ'
            $script:taskUi.StatusTitle.Text = $taskCurrent.Name
            $script:taskUi.AddressText.Text = $taskCurrent.Address
            $script:taskUi.EntriesText.Text = Get-TaskRecordsLabel $taskCurrent.Count
            if ($taskCurrent.ProfileId -and $script:taskProfileControls.ContainsKey($taskCurrent.ProfileId)) {
                $taskControls = $script:taskProfileControls[$taskCurrent.ProfileId]
                $taskControls.Active.Visibility = 'Visible'
                $taskControls.Card.BorderBrush = Get-TaskBrush '#568D83'
                $taskControls.Button.Content = 'Применить снова'
                $taskControls.Button.Background = Get-TaskBrush '#91F2D2'
                $taskControls.Button.Foreground = Get-TaskBrush '#0C2823'
                $taskActiveProfile = @($script:taskProfiles | Where-Object Id -eq $taskCurrent.ProfileId | Select-Object -First 1)
                $script:taskUi.ActiveFlag.Source = Get-TaskImage ('flag-' + $taskActiveProfile[0].CountryCode + '.png')
                if(-not $script:taskUi.ActiveFlag.Source) { $script:taskUi.ActiveFlag.Source = Get-TaskImage 'icon-globe.png' }
            }
            if ($taskCurrent.Kind -eq 'Unknown') {
                $script:taskUi.StatusBadge.Text = 'ВНЕ КАТАЛОГА'
                $script:taskUi.StatusPill.Background = Get-TaskBrush '#443522'
                $script:taskUi.StatusBadge.Foreground = Get-TaskBrush '#F4CD8C'
                $script:taskUi.StatusDot.Fill = Get-TaskBrush '#F4CD8C'
            }
        }
        else {
            $script:taskUi.StatusBadge.Text = 'СИСТЕМНЫЙ DNS'
            $script:taskUi.StatusTitle.Text = 'Управляемые hosts отключены'
            $script:taskUi.AddressText.Text = 'DNS Windows'
            $script:taskUi.EntriesText.Text = 'Управляемого блока нет'
            $script:taskUi.StatusPill.Background = Get-TaskBrush '#25364A'
            $script:taskUi.StatusBadge.Foreground = Get-TaskBrush '#B6C7DE'
            $script:taskUi.StatusDot.Fill = Get-TaskBrush '#B6C7DE'
        }
    }
    catch {
        $taskCurrent = [pscustomobject]@{Kind='Warning';ProfileId=''}
        $taskSnapshot = 'Warning' + $_.Exception.Message
        $script:taskUi.StatusTitle.Text = 'Настройка требует проверки'
        $script:taskUi.StatusDescription.Text = $_.Exception.Message
        $script:taskUi.AddressText.Text = 'Проверьте журнал'
        $script:taskUi.EntriesText.Text = ''
        $script:taskUi.StatusBadge.Text = 'НУЖНА ПРОВЕРКА'
        $script:taskUi.StatusBadge.Foreground = Get-TaskBrush '#F4CD8C'
        $script:taskUi.StatusDot.Fill = Get-TaskBrush '#F4CD8C'
        $script:taskUi.StatusPill.Background = Get-TaskBrush '#443522'
    }
    try {
        $taskProxy = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        $taskHttpState=Get-HttpProxyState $script:taskRoot
        $script:taskUi.ProxyText.Text = if($taskHttpState.Enabled){'Прокси ChatGPT: US'}elseif($taskProxy.ProxyEnable -eq 1){'Другой прокси Windows включён'}else{'Прокси ChatGPT выключен'}
    }
    catch { $script:taskUi.ProxyText.Text = 'Статус прокси недоступен' }
    $script:taskUi.LastReadText.Text = 'hosts · ' + (Get-Date -Format 'HH:mm:ss')
    if ($LogChange -and $taskSnapshot -ne $script:taskLastSnapshot) {
        Add-TaskLog ($script:taskUi.StatusTitle.Text + '. ' + $script:taskUi.StatusDescription.Text) -Kind $(if($taskCurrent.Kind -in @('Unknown','Warning')){'Problems'}else{'Info'})
    }
    $script:taskLastSnapshot = $taskSnapshot
    if (-not $script:taskSelectedProfileId) { $script:taskSelectedProfileId = if($script:taskActiveProfileId){$script:taskActiveProfileId}else{$script:taskProfiles[0].Id} }
    Select-TaskProfile $script:taskSelectedProfileId
    return $taskCurrent
}

function Set-TaskBusy([bool]$Value) {
    $script:taskBusy = $Value
    foreach ($taskName in @('ImportButton','CheckButton','CacheButton','RestoreButton','ApplyProfileButton','ClearLogButton')) { $script:taskUi[$taskName].IsEnabled = -not $Value }
    foreach ($taskControl in $script:taskProfileControls.Values) { $taskControl.Button.IsEnabled = -not $Value }
    Update-GeoProfileCards
    $taskAnyBusy = $Value -or $script:taskHealthRun -or $script:taskCleanupRun
    $script:taskUi.ActivityBar.IsIndeterminate = ($taskAnyBusy -and -not $script:taskReducedMotion)
    $script:taskUi.ActivityBar.Value = if ($taskAnyBusy) { 40 } else { 0 }
}

function Start-TaskHeroMotion {
    $taskHero = $script:taskUi.HeroImage
    if ($taskHero.RenderTransform -isnot [Windows.Media.TranslateTransform]) { $taskHero.RenderTransform = [Windows.Media.TranslateTransform]::new() }
    $taskHero.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $null)
    $taskHero.RenderTransform.Y = 0
    if ($script:taskReducedMotion -or -not $taskHero.Source) { return }
    $taskFloat = [Windows.Media.Animation.DoubleAnimation]::new(0,-2.5,[Windows.Duration]::new([timespan]::FromSeconds(3)))
    $taskFloat.AutoReverse = $true
    $taskFloat.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    $taskFloat.EasingFunction = [Windows.Media.Animation.SineEase]::new()
    $taskFloat.EasingFunction.EasingMode = 'EaseInOut'
    $taskHero.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty,$taskFloat)
}

function Set-TaskMotion {
    $script:taskReducedMotion = (($script:taskUi.ReducedMotion.IsChecked -eq $true) -or -not [Windows.SystemParameters]::ClientAreaAnimation)
    Start-TaskHeroMotion
    $script:taskUi.ActivityBar.IsIndeterminate = (($script:taskBusy -or $script:taskHealthRun -or $script:taskCleanupRun) -and -not $script:taskReducedMotion)
    foreach ($taskName in @('ImportButton','CheckButton','CacheButton','RestoreButton','CopyLogButton','OpenLogButton')) {
        $taskButton = $script:taskUi[$taskName]
        if ($taskButton.RenderTransform -is [Windows.Media.TranslateTransform]) {
            $taskButton.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $null)
            $taskButton.RenderTransform.Y = 0
        }
    }
    foreach ($taskControls in $script:taskProfileControls.Values) {
        $taskControls.Button.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $null)
        $taskControls.Button.RenderTransform.Y = 0
    }
    if ($script:taskReducedMotion) {
        foreach ($taskName in @('HeroCard','ServersPanel','ToolsPanel','JournalCard')) {
            $taskElement = $script:taskUi[$taskName]
            $taskElement.BeginAnimation([Windows.UIElement]::OpacityProperty,$null)
            $taskElement.Opacity = 1
            if ($taskElement.RenderTransform -is [Windows.Media.TranslateTransform]) {
                $taskElement.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty,$null)
                $taskElement.RenderTransform.Y = 0
            }
        }
        if ($script:taskImport -and $script:taskImport.Window) {
            $taskDialogBody = $script:taskImport.Window.Content
            $taskDialogBody.BeginAnimation([Windows.UIElement]::OpacityProperty,$null)
            $taskDialogBody.Opacity = 1
            if ($taskDialogBody.RenderTransform -is [Windows.Media.TranslateTransform]) {
                $taskDialogBody.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty,$null)
                $taskDialogBody.RenderTransform.Y = 0
            }
        }
    }
    if (-not $SmokeTest -and -not $RenderPreview) {
        try { [pscustomobject]@{ReducedMotion=($script:taskUi.ReducedMotion.IsChecked -eq $true)} | ConvertTo-Json | Set-Content -LiteralPath $script:taskSettingsPath -Encoding UTF8 }
        catch { Add-TaskLog 'Не удалось сохранить настройку анимаций. Она действует до закрытия окна.' }
    }
}

function Read-TaskWorkerLog {
    if (-not $script:taskRun -or -not (Test-Path -LiteralPath $script:taskRun.LogPath)) { return }
    try {
        $taskText = [IO.File]::ReadAllText($script:taskRun.LogPath, [Text.Encoding]::UTF8)
        if ($taskText.Length -gt $script:taskRun.LogOffset) {
            $taskNewText = $taskText.Substring($script:taskRun.LogOffset)
            $script:taskRun.LogOffset = $taskText.Length
            foreach ($taskLine in ($taskNewText -split '\r?\n')) { if ($taskLine.Trim()) { Add-TaskLog $taskLine } }
        }
    }
    catch { }
}

function Complete-TaskAction {
    Read-TaskWorkerLog
    $taskRun = $script:taskRun
    $script:taskRun = $null
    Set-TaskBusy $false
    try {
        if (-not (Test-Path -LiteralPath $taskRun.ResultPath)) { throw 'Действие завершилось без отчёта. Изменение не подтверждено; проверьте настройки перед повтором.' }
        $taskResult = [IO.File]::ReadAllText($taskRun.ResultPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($taskResult.Status -ne 'ok') { throw ([string]$taskResult.Error) }
        $taskCaption = if ($taskRun.Mode -eq 'Check') { 'Настройки проверены' } else { [string]$taskResult.Message }
        $script:taskUi.ActionTitle.Text = $taskCaption
        $script:taskUi.ActionTitle.Foreground = Get-TaskBrush '#91F2D2'
        Add-TaskLog $taskCaption
        if ($taskResult.VerifiedCount -gt 0) { Add-TaskLog ('Проверены записи: ' + $taskResult.VerifiedCount + ' из ' + $taskResult.ExpectedCount + '. Это проверка настройки, а не загрузки файлов.') }
        if ($taskRun.Mode -eq 'Import') {
            Load-TaskProfiles -Force
            $script:taskUi.ActivityDetail.Text = 'Сервер добавлен в список. Нажмите «Подключить» на его карточке.'
            Add-TaskLog 'Импорт завершён. Чтобы изменить подключение, выберите новый профиль в списке серверов.'
        }
        elseif ($taskRun.Mode -eq 'Check') {
            $script:taskUi.ActivityDetail.Text = 'Проверены DNS-адреса и прокси. Загрузку файла проверьте в ChatGPT.'
        }
        else {
            $script:taskUi.ActivityDetail.Text = 'DNS Windows обновлён. Если GIF зависла, откройте «GIF / вложения не работают» для перезапуска Chrome.'
            Add-TaskLog 'Очистка DNS Windows не закрывает соединения Chrome и не удаляет кеш файлов браузера. Перезапуск доступен в помощи с вложениями.'
        }
    }
    catch {
        $taskError = $_.Exception.Message
        $taskError = $taskError -replace 'Вернись в меню и выбери пункт 3\.', 'Нажмите «Включить» у нужного сервера.' -replace 'Попробуй пункт 1, затем пункт 3\.', 'Очистите DNS-кеш, затем примените нужный сервер снова.' -replace 'Выбери пункт 3, чтобы восстановить настройку\.', 'Примените нужный сервер снова.'
        $script:taskUi.ActionTitle.Text = 'Действие требует внимания'
        $script:taskUi.ActionTitle.Foreground = Get-TaskBrush '#F4CD8C'
        $script:taskUi.ActivityDetail.Text = 'Подробности в журнале. Текущее состояние hosts обновлено.'
        Add-TaskLog ('Ошибка: ' + $taskError)
        if($script:geoApplyRequested -and $taskRun.Mode -eq 'Apply'){$script:geoNotice='Применение не подтверждено: '+$taskError}
        if ($taskRun.Mode -eq 'ClearCache') { Add-TaskLog 'Очистка кеша и проверка — отдельные этапы. Ошибка проверки не означает, что кеш остался прежним.' }
    }
    finally {
        if ($taskRun.Process) { $taskRun.Process.Dispose() }
        [void](Update-TaskStatus -LogChange)
        if($script:geoApplyRequested -and $taskRun.Mode -eq 'Apply'){$script:geoApplyRequested=$false;Update-GeoEditorState -Force}
        if($taskRun.Mode -ne 'Import') { Start-TaskHealth 'Check' }
        Start-TaskConnection
    }
}

function Start-TaskAction([string]$Mode, [string]$ProfileId = '', [hashtable]$ImportData = $null) {
    if ($script:taskBusy -or $SmokeTest -or $RenderPreview) { return }
    if (-not $ProfileId) { $ProfileId = if ($script:taskActiveProfileId) { $script:taskActiveProfileId } else { $script:taskProfiles[0].Id } }
    if($Mode -eq 'Apply'){$availability=Get-GeoProfileAvailability $script:taskRoot $ProfileId $script:geoReport;if(-not $availability.Ready){$script:taskUi.GeoEditorStatus.Text=$availability.Reason;Add-TaskLog ('Подключение заблокировано: '+$availability.Reason);return}}
    $taskProfile = @($script:taskProfiles | Where-Object { $_.Id -eq $ProfileId } | Select-Object -First 1)
    $taskProfileName = if ($taskProfile.Count) { $taskProfile[0].Name } else { $ProfileId }
    $taskCaptions = @{Check='Проверяю настройки';ClearCache='Очищаю DNS-кеш и проверяю адреса';Restore='Отключаю управляемые hosts';Apply=('Подключаю ' + $taskProfileName);Import='Добавляю новый сервер'}
    Set-TaskBusy $true
    $script:taskUi.ActionTitle.Text = $taskCaptions[$Mode] + '…'
    $script:taskUi.ActionTitle.Foreground = Get-TaskBrush '#B9CEE3'
    $script:taskUi.ActivityDetail.Text = 'Выполняется действие. Журнал обновляется автоматически.'
    Add-TaskLog ($taskCaptions[$Mode] + '…')
    try {
        $taskRunDirectory = Join-Path $script:taskRoot 'run-results'
        New-Item -ItemType Directory -Path $taskRunDirectory -Force | Out-Null
        if (((Get-Item -LiteralPath $taskRunDirectory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Папка журналов не должна быть ссылкой. Действие не запущено.' }
        $taskRunId = 'gui-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
        $taskResultPath = Join-Path $taskRunDirectory ($taskRunId + '.json')
        $taskLogPath = Join-Path $taskRunDirectory ($taskRunId + '.log')
        $taskRequestPath = Join-Path $taskRunDirectory ($taskRunId + '.request.json')
        $taskRequest = @{Mode=$Mode;ProfileId=$ProfileId;ResultPath=$taskResultPath;LogPath=$taskLogPath;ExpectedUserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
        if ($Mode -eq 'Import') { foreach ($taskKey in @('SourcePath','Name','CountryCode','Region','InputKind','Address','Service')) { $taskRequest[$taskKey] = $ImportData[$taskKey] } }
        $taskRequest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $taskRequestPath -Encoding UTF8
        $taskArguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + (Join-Path $script:taskRoot 'GuiWorker.ps1') + '"'),'-RequestPath',('"' + $taskRequestPath + '"'))
        $taskStart = @{FilePath=$script:taskShell;ArgumentList=$taskArguments;WindowStyle='Hidden';PassThru=$true;ErrorAction='Stop'}
        $taskPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        if ($Mode -in @('Apply','Restore') -and -not $taskPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            $taskStart.Verb = 'RunAs'
            $script:taskUi.ActivityDetail.Text = 'Подтвердите запрос администратора в окне Windows.'
            Add-TaskLog 'Windows запросит права администратора для изменения hosts.'
        }
        $taskProcess = Start-Process @taskStart
        $script:taskRun = [pscustomobject]@{Mode=$Mode;ProfileId=$ProfileId;Process=$taskProcess;RequestPath=$taskRequestPath;ResultPath=$taskResultPath;LogPath=$taskLogPath;LogOffset=0;StartedAt=(Get-Date)}
    }
    catch {
        $taskError = $_.Exception.Message
        $taskException = $_.Exception
        $taskCancelled = $taskError -match 'cancel|отмен|1223'
        while ($taskException) {
            if ($taskException -is [ComponentModel.Win32Exception] -and $taskException.NativeErrorCode -eq 1223) { $taskCancelled = $true }
            $taskException = $taskException.InnerException
        }
        if ($taskCancelled) { $taskError = 'Запрос администратора отменён. Действие не запущено.' }
        $script:taskUi.ActionTitle.Text = if ($taskCancelled) { 'Действие отменено' } else { 'Не удалось запустить действие' }
        $script:taskUi.ActionTitle.Foreground = Get-TaskBrush '#F4CD8C'
        $script:taskUi.ActivityDetail.Text = 'Можно повторить действие, когда будете готовы.'
        Add-TaskLog $taskError
        Set-TaskBusy $false
        [void](Update-TaskStatus)
    }
}

function Format-TaskBytes([long]$Bytes) {
    if($Bytes -ge 1MB){return ('{0:N1} МБ' -f ($Bytes / 1MB))}
    if($Bytes -ge 1KB){return ('{0:N1} КБ' -f ($Bytes / 1KB))}
    return ($Bytes.ToString() + ' Б')
}

function Start-TaskHealth([string]$Mode = 'Check') {
    if($SmokeTest -or $RenderPreview) { return }
    if($Mode -eq 'Check' -and $script:taskHealthRun) { return }
    if($Mode -eq 'ClearLogs' -and $script:taskCleanupRun) { return }
    try {
        $taskRunDirectory = Join-Path $script:taskRoot 'run-results'
        New-Item -ItemType Directory -Path $taskRunDirectory -Force | Out-Null
        if (((Get-Item -LiteralPath $taskRunDirectory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Папка журналов не должна быть ссылкой.' }
        $taskRunId = 'gui-health-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
        $taskRequestPath = Join-Path $taskRunDirectory ($taskRunId + '.request.json')
        $taskResultPath = Join-Path $taskRunDirectory ($taskRunId + '.json')
        $taskLogPath = Join-Path $taskRunDirectory ($taskRunId + '.log')
        $taskPreserve = @($taskRequestPath,$taskResultPath,$taskLogPath)
        foreach($taskActiveRun in @($script:taskRun,$script:taskHealthRun,$script:taskCleanupRun)) {
            if($taskActiveRun) { $taskPreserve += @($taskActiveRun.RequestPath,$taskActiveRun.ResultPath,$taskActiveRun.LogPath) }
        }
        @{Engine='Health';Mode=$Mode;ResultPath=$taskResultPath;LogPath=$taskLogPath;PreservePaths=$taskPreserve} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $taskRequestPath -Encoding UTF8
        $taskArguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + (Join-Path $script:taskRoot 'GuiWorker.ps1') + '"'),'-RequestPath',('"' + $taskRequestPath + '"'))
        $taskProcess = Start-Process -FilePath $script:taskShell -ArgumentList $taskArguments -WindowStyle Hidden -PassThru -ErrorAction Stop
        $taskNewRun = [pscustomobject]@{Mode=$Mode;Process=$taskProcess;RequestPath=$taskRequestPath;ResultPath=$taskResultPath;LogPath=$taskLogPath;StartedAt=(Get-Date)}
        if($Mode -eq 'Check') { $script:taskHealthRun = $taskNewRun; $script:taskUi.HealthAtText.Text = 'Проверяю DNS / TLS / HTTP…'; Add-TaskLog 'Фоновая диагностика: ChatGPT, маршрут, DNS-кеш и журналы.' }
        else { $script:taskCleanupRun = $taskNewRun; Add-TaskLog 'Удаляю завершённые файлы журналов менеджера. Активные и недавние файлы сохраняются.' }
        Set-TaskBusy $script:taskBusy
    }
    catch { Add-TaskLog ('Не удалось запустить диагностику: ' + $_.Exception.Message); $script:taskUi.HealthAtText.Text = 'Проверка недоступна' }
}

function Update-TaskHealthResult($Result) {
    if($Result.status -ne 'ok') { throw ([string]$Result.error) }
    $script:taskHealthAt = if($Result.at){[datetime]$Result.at}else{Get-Date}
    $taskState = [string]$Result.health.status
    $taskColor = switch($taskState){'online'{'#98EFD5'}'limited'{'#F1D19B'}'offline'{'#F4AEA7'}default{'#B4C3D7'}}
    $taskBackground = switch($taskState){'online'{'#244C43'}'limited'{'#4A3D2A'}'offline'{'#4B3034'}default{'#2B3D51'}}
    $script:taskUi.HealthPill.Background = Get-TaskBrush $taskBackground
    $script:taskUi.HealthBadge.Foreground = Get-TaskBrush $taskColor
    $script:taskUi.HealthBadge.Text = switch($taskState){'online'{'МАРШРУТ ДОСТУПЕН'}'limited'{'ЕСТЬ ОГРАНИЧЕНИЯ'}'offline'{'ПРОВЕРКА НЕ ПРОШЛА'}default{'НЕТ ПОЛНОГО РЕЗУЛЬТАТА'}}
    $script:taskUi.HealthTitle.Text = switch($taskState){'online'{'Сетевой маршрут отвечает'}'limited'{'Нужна проверка в ChatGPT'}'offline'{'Не удалось подтвердить маршрут'}default{'Диагностика требует внимания'}}
    $script:taskUi.HealthDescription.Text = [string]$Result.health.summary
    if(@($Result.probes | Where-Object error -eq 'cloudflare_challenge').Count -gt 0) { $script:taskUi.HealthDescription.Text = 'TLS доступен. Внешняя проверка получила Cloudflare 403; доступ из приложения пока не подтверждён.' }
    $script:taskUi.HealthAtText.Text = 'Проверено ' + $script:taskHealthAt.ToString('dd.MM HH:mm:ss')
    $script:taskUi.AppHealthText.Text = $(if($Result.app.running){'Запущен'}else{'Не запущен'}) + $(if($Result.app.version){' · версия ' + $Result.app.version}else{' · версия: нет данных'})
    $script:taskAppLaunchTarget = [string]$Result.app.launchTarget
    $script:taskUi.OpenAppButton.IsEnabled = [bool]$script:taskAppLaunchTarget
    $taskProbeStrings = @()
    $taskProbeDetails = @()
    foreach($taskProbe in @($Result.probes)) {
        $taskProbeStrings += $taskProbe.name + ': ' + $(if($taskProbe.tlsValid){'HTTPS ✓'}elseif($taskProbe.status -eq 'error'){'нет соединения'}else{'не подтверждено'})
        $taskProbeDetails += $taskProbe.name + ' · ' + $taskProbe.host + [Environment]::NewLine + $taskProbe.detail
        Add-TaskLog ($taskProbe.name + ': DNS ' + ($taskProbe.dnsIPs -join ', ') + ' · TLS ' + $(if($taskProbe.tlsValid){'подтверждён'}else{'не подтверждён'}) + ' · ' + $(if($taskProbe.httpStatus){'HTTP ' + $taskProbe.httpStatus}else{$taskProbe.status}) + ' · ' + $taskProbe.latencyMs + ' мс. ' + $taskProbe.detail) -Kind $(if($taskProbe.status -in @('warning','error','unknown')){'Problems'}else{'Info'})
    }
    $script:taskUi.RouteHealthText.Text = ($taskProbeStrings -join ' · ')
    $script:taskUi.RouteHealthText.ToolTip = ($taskProbeDetails -join ([Environment]::NewLine + [Environment]::NewLine))
    $script:taskUi.RouteTimeText.Text = ([int]$Result.health.elapsedMs).ToString() + ' мс'
    $taskCacheTime = if($Result.cache.lastClearedAt){try{([datetime]$Result.cache.lastClearedAt).ToString('dd.MM HH:mm')}catch{'нет данных'}}else{'нет данных'}
    $taskEntryCount = if($null -eq $Result.cache.windowsDnsRelatedEntries){'нет данных'}else{$Result.cache.windowsDnsRelatedEntries.ToString()}
    $script:taskUi.CacheHealthText.Text = 'DNS Windows: ' + $taskEntryCount + ' записей · очистка: ' + $taskCacheTime
    if($Result.cache.folders) {
        $taskCacheSummaries = @()
        $taskFolderDetails = @()
        foreach($taskContext in @('application','browser')) {
            $taskFolders = @($Result.cache.folders | Where-Object { $_.context -eq $taskContext -and $null -ne $_.bytes })
            $taskTotal = ($taskFolders | Measure-Object -Property bytes -Sum).Sum
            $taskComplete = @($Result.cache.folders | Where-Object { $_.context -eq $taskContext -and ($_.complete -ne $true -or $null -eq $_.bytes) }).Count -eq 0
            $taskCacheSummaries += $(if($taskContext -eq 'application'){'ChatGPT: '}else{'браузер: '}) + $(if($taskFolders.Count){$(if(-not $taskComplete){'≥ '}else{''}) + (Format-TaskBytes ([long]$taskTotal))}else{'нет данных'})
        }
        foreach($taskFolder in @($Result.cache.folders)) { $taskFolderDetails += $taskFolder.name + ' · ' + $taskFolder.context + ': ' + $(if($null -eq $taskFolder.bytes){'нет данных'}else{$(if(-not $taskFolder.complete){'≥ '}else{''}) + (Format-TaskBytes ([long]$taskFolder.bytes))}) + [Environment]::NewLine + $taskFolder.detail }
        $script:taskUi.CacheHealthText.Text += [Environment]::NewLine + 'Кеш ' + ($taskCacheSummaries -join ' · ')
        $script:taskUi.CacheHealthText.ToolTip = $taskFolderDetails -join ([Environment]::NewLine + [Environment]::NewLine)
    }
    $script:taskUi.LogsSizeText.Text = $Result.logs.fileCount.ToString() + ' файлов · ' + (Format-TaskBytes ([long]$Result.logs.bytes))
    $script:taskUi.ClearLogButton.ToolTip = 'Файлы менеджера: ' + $Result.logs.fileCount + ' · ' + (Format-TaskBytes ([long]$Result.logs.bytes)) + '. Активные файлы и резервные копии сохраняются.'
    Add-TaskLog ('Диагностика завершена: ' + $script:taskUi.HealthBadge.Text.ToLowerInvariant() + '. Вход и загрузка вложений не проверены.') -Kind $(if($taskState -in @('limited','offline','unknown')){'Problems'}else{'Info'})
    Set-TaskConnectionView
}

function Poll-TaskHealth {
    foreach($taskSlot in @('taskHealthRun','taskCleanupRun')) {
        $taskRun = Get-Variable -Name $taskSlot -Scope Script -ValueOnly
        if(-not $taskRun -or -not $taskRun.Process.HasExited) { continue }
        try {
            if(-not (Test-Path -LiteralPath $taskRun.ResultPath)) {
                if(Test-Path -LiteralPath $taskRun.LogPath) { Add-TaskLog ([IO.File]::ReadAllText($taskRun.LogPath)) }
                throw 'Не получен отчёт диагностики. Посмотрите подробности в журнале.'
            }
            $taskResult = [IO.File]::ReadAllText($taskRun.ResultPath,[Text.Encoding]::UTF8) | ConvertFrom-Json
            if($taskRun.Mode -eq 'Check') { Update-TaskHealthResult $taskResult }
            else {
                if($taskResult.status -ne 'ok') { throw ([string]$taskResult.error) }
                Add-TaskLog ('Журналы очищены: ' + $taskResult.maintenance.deletedCount + ' файлов, ' + (Format-TaskBytes ([long]$taskResult.maintenance.deletedBytes)) + '. Сохранено активных и недавних: ' + $taskResult.maintenance.skippedCount + '.')
                $script:taskUi.LogsSizeText.Text = $taskResult.logs.fileCount.ToString() + ' файлов · ' + (Format-TaskBytes ([long]$taskResult.logs.bytes))
            }
        }
        catch { Add-TaskLog ('Ошибка диагностики: ' + $_.Exception.Message); if($taskRun.Mode -eq 'Check'){$script:taskUi.HealthAtText.Text='Не удалось завершить проверку'} }
        finally { $taskRun.Process.Dispose(); Set-Variable -Name $taskSlot -Scope Script -Value $null; Set-TaskBusy $script:taskBusy }
    }
    if($script:taskHealthAt -and -not $script:taskHealthRun) {
        $taskAge = [int]((Get-Date) - $script:taskHealthAt).TotalSeconds
        $script:taskUi.HealthAtText.Text = 'Проверено ' + $(if($taskAge -lt 60){$taskAge.ToString() + ' сек назад'}else{([int]($taskAge / 60)).ToString() + ' мин назад'})
    }
}

function Open-TaskApp {
    if(-not $script:taskAppLaunchTarget) { Add-TaskLog 'Не найден зарегистрированный способ запуска ChatGPT.'; return }
    try { Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList $script:taskAppLaunchTarget | Out-Null; Add-TaskLog 'Отправлен запрос на открытие ChatGPT.' }
    catch { Add-TaskLog ('Не удалось открыть ChatGPT: ' + $_.Exception.Message) }
}

function Show-TaskLogMenu {
    $taskMenu = [Windows.Controls.ContextMenu]::new(); $taskMenu.Background = Get-TaskBrush '#182C40'; $taskMenu.Foreground = Get-TaskBrush '#E2EFFA'
    $taskLocalItem = [Windows.Controls.MenuItem]::new(); $taskLocalItem.Header = 'Очистить журнал этого сеанса'; $taskLocalItem.Add_Click({$script:taskEvents.Clear(); Update-TaskLogView; $script:taskUi.ActivityDetail.Text='Журнал сеанса очищен.'}); [void]$taskMenu.Items.Add($taskLocalItem)
    $taskFilesItem = [Windows.Controls.MenuItem]::new(); $taskFilesItem.Header = 'Очистить историю журналов менеджера…'; $taskFilesItem.Add_Click({Show-TaskLogClearDialog}); [void]$taskMenu.Items.Add($taskFilesItem)
    $taskMenu.PlacementTarget = $script:taskUi.ClearLogButton; $taskMenu.Placement = 'Bottom'; $taskMenu.IsOpen = $true
}

function Show-TaskLogClearDialog {
    if($script:taskBusy -or $script:taskCleanupRun) { return }
    $taskProtected = @()
    foreach($taskActiveRun in @($script:taskRun,$script:taskHealthRun,$script:taskCleanupRun)) { if($taskActiveRun){$taskProtected += @($taskActiveRun.RequestPath,$taskActiveRun.ResultPath,$taskActiveRun.LogPath)} }
    $taskOwnPattern = '^(?:gui(?:-health)?-\d{8}-\d{6}-[a-fA-F0-9]{8}(?:\.(?:request|result))?|health-\d{8}-\d{6}-[a-fA-F0-9]{8}(?:\.result)?|health-probe-[a-fA-F0-9]{32}-(?:chat|file|filecentral|filewest|cloud)\.result)\.(?:json|log)$'
    $taskFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:taskRoot 'run-results') -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -cmatch $taskOwnPattern -and $_.FullName -notin $taskProtected -and ((Get-Date)-$_.LastWriteTime).TotalSeconds -ge 120 -and ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 })
    $taskBytes = [long](($taskFiles | Measure-Object Length -Sum).Sum)
    $taskDialog = [Windows.Window]::new(); $taskDialog.Title='Очистить историю — NextDNS'; $taskDialog.Width=560; $taskDialog.Height=330; $taskDialog.ResizeMode='NoResize'; $taskDialog.WindowStartupLocation='CenterOwner'; $taskDialog.Owner=$script:taskWindow; $taskDialog.Background=Get-TaskBrush '#122032'; $taskDialog.Foreground=Get-TaskBrush '#E4EFFA'; $taskDialog.FontFamily=[Windows.Media.FontFamily]::new('Segoe UI'); $taskDialog.ShowInTaskbar=$false
    Register-TaskDarkTitleBar $taskDialog
    Register-TaskDialogKeys $taskDialog
    $taskBody=[Windows.Controls.StackPanel]::new(); $taskBody.Margin=[Windows.Thickness]::new(26); $taskDialog.Content=$taskBody
    $taskTitle=[Windows.Controls.TextBlock]::new(); $taskTitle.Text='Очистить историю журналов?'; $taskTitle.FontSize=23; $taskTitle.FontWeight='SemiBold'; [void]$taskBody.Children.Add($taskTitle)
    $taskCountText=[Windows.Controls.TextBlock]::new(); $taskCountText.Text='Завершённых файлов старше 2 минут: ' + $taskFiles.Count + ' · ' + (Format-TaskBytes $taskBytes); $taskCountText.Margin=[Windows.Thickness]::new(0,17,0,0); $taskCountText.Foreground=Get-TaskBrush '#ACE3D0'; $taskCountText.FontSize=13; [void]$taskBody.Children.Add($taskCountText)
    $taskDescription=[Windows.Controls.TextBlock]::new(); $taskDescription.Text='Будут очищены история в окне и завершённые журналы этого менеджера в run-results. Активные и недавние файлы сохранятся и могут снова появиться в истории. Резервные копии и данные ChatGPT сохраняются.'; $taskDescription.TextWrapping='Wrap'; $taskDescription.FontSize=13; $taskDescription.Foreground=Get-TaskBrush '#A0B6D0'; $taskDescription.Margin=[Windows.Thickness]::new(0,12,0,0); [void]$taskBody.Children.Add($taskDescription)
    $taskButtons=[Windows.Controls.StackPanel]::new(); $taskButtons.Orientation='Horizontal'; $taskButtons.HorizontalAlignment='Right'; $taskButtons.Margin=[Windows.Thickness]::new(0,24,0,0)
    $taskCancel=[Windows.Controls.Button]::new(); $taskCancel.Content='Отмена'; $taskCancel.Style=$script:taskWindow.FindResource('ActionButton'); $taskCancel.IsCancel=$true; $taskCancel.Margin=[Windows.Thickness]::new(0,0,12,0); $taskCancel.MinWidth=100
    $taskClear=[Windows.Controls.Button]::new(); $taskClear.Content='Очистить историю'; $taskClear.Style=$script:taskWindow.FindResource('ActionButton'); $taskClear.Background=Get-TaskBrush '#98EFD5'; $taskClear.Foreground=Get-TaskBrush '#12342B'; $taskClear.MinWidth=150
    $taskClear.Add_Click({param($sender,$eventArgs) [Windows.Window]::GetWindow($sender).DialogResult=$true})
    [void]$taskButtons.Children.Add($taskCancel); [void]$taskButtons.Children.Add($taskClear); [void]$taskBody.Children.Add($taskButtons)
    if($taskDialog.ShowDialog() -eq $true) { $script:taskEvents.Clear(); Update-TaskLogView; Start-TaskHealth 'ClearLogs' }
}

function Export-TaskPreview([string]$Path) {
    if (-not $Path) { $Path = Join-Path $script:taskRoot 'GUI-preview.png' }
    $taskWidth = $PreviewWidth
    $taskHeight = $PreviewHeight
    $taskContent = $script:taskWindow.Content
    $taskContent.Width = $taskWidth
    $taskContent.Height = $taskHeight
    $taskContent.Measure([Windows.Size]::new($taskWidth,$taskHeight))
    $taskContent.Arrange([Windows.Rect]::new(0,0,$taskWidth,$taskHeight))
    $taskContent.UpdateLayout()
    $taskBitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new($taskWidth,$taskHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $taskBitmap.Render($taskContent)
    $taskEncoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $taskEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($taskBitmap))
    $taskStream = [IO.File]::Open($Path,[IO.FileMode]::Create)
    try { $taskEncoder.Save($taskStream) } finally { $taskStream.Dispose() }
    Write-Output ('Preview saved: ' + $Path)
}

function New-TaskProfileHelp($Owner) {
    [xml]$helpXaml=[IO.File]::ReadAllText((Join-Path $script:taskRoot 'ProfileHelp.xaml'))
    $reader=[Xml.XmlNodeReader]::new($helpXaml)
    try{$help=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    if($Owner -and $Owner.IsLoaded){$help.Owner=$Owner}
    $help.Height=[Math]::Min(730,[Windows.SystemParameters]::WorkArea.Height-40)
    $help.Width=[Math]::Min(650,[Windows.SystemParameters]::WorkArea.Width-40)
    Register-TaskDarkTitleBar $help
    Register-TaskDialogKeys $help
    $close=$help.FindName('CloseProfileHelpButton')
    $close.Style=$script:taskWindow.FindResource('ActionButton')
    $close.Add_Click({param($sender,$eventArgs) [Windows.Window]::GetWindow($sender).DialogResult=$true})
    return $help
}
function Show-TaskProfileHelp($Owner=$script:taskWindow) {
    $help=New-TaskProfileHelp $Owner
    [void]$help.ShowDialog()
}

function Set-TaskProfileInputMode {
    $byIP=$script:taskImport.Ui.CreateByIP.IsChecked -eq $true
    $script:taskImport.Ui.AddressPanel.Visibility=if($byIP){'Visible'}else{'Collapsed'}
    $script:taskImport.Ui.FilePanel.Visibility=if($byIP){'Collapsed'}else{'Visible'}
    $script:taskImport.Ui.ProfileNameLabel.Text=if($byIP){'Название · необязательно'}else{'Название профиля'}
    $script:taskImport.Ui.ProfileNameHelp.Text=if($byIP){'Оставьте пустым — назовём по сервису и стране.'}else{'Укажите название, которое будет видно на карточке.'}
    $script:taskImport.Ui.ImportErrorText.Text=''
}
function Get-TaskProfileInput {
    $ui=$script:taskImport.Ui
    $country=$ui.CountryBox.SelectedItem
    if(-not $country){throw 'Выберите страну или регион.'}
    $data=@{CountryCode=[string]$country.Tag;Region=[string]$country.Content;Name=$ui.ProfileNameBox.Text.Trim();SourcePath='';Address='';Service='ChatGPT';InputKind='File'}
    if($ui.CreateByIP.IsChecked -eq $true){
        if(-not $ui.ServerAddressBox.Text.Trim()){throw 'Введите IP-адрес сервера.'}
        $data.Address=Convert-GeoProfileAddress $ui.ServerAddressBox.Text.Trim()
        if(-not $ui.ServiceBox.SelectedItem){throw 'Выберите сервис: ChatGPT или Gemini.'}
        $data.Service=[string]$ui.ServiceBox.SelectedItem.Tag
        if($data.Service -notin @('ChatGPT','Gemini')){throw 'Выберите сервис: ChatGPT или Gemini.'}
        $data.InputKind='Address'
        if(-not $data.Name){$data.Name=$data.Service+' — '+$data.Region}
    }else{
        if(-not $script:taskImport.SourcePath){throw 'Сначала выберите файл .hosts.'}
        if(-not $data.Name){throw 'Укажите понятное название профиля.'}
        $data.SourcePath=$script:taskImport.SourcePath
    }
    return $data
}

function Show-TaskImportDialog {
    if ($script:taskBusy) { return }
    [xml]$taskDialogXaml = [IO.File]::ReadAllText((Join-Path $script:taskRoot 'ImportDialog.xaml'))
    $taskDialogReader = [Xml.XmlNodeReader]::new($taskDialogXaml)
    try { $taskDialog = [Windows.Markup.XamlReader]::Load($taskDialogReader) } finally { $taskDialogReader.Close() }
    $taskDialog.Owner = $script:taskWindow
    $taskDialog.Height=[Math]::Min(730,[Windows.SystemParameters]::WorkArea.Height-32)
    Register-TaskDarkTitleBar $taskDialog
    Register-TaskDialogKeys $taskDialog
    $script:taskImport = @{Window=$taskDialog;Ui=@{};SourcePath='';Data=$null}
    foreach ($taskNode in $taskDialogXaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
        $taskName = $taskNode.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
        if ($taskName) { $script:taskImport.Ui[$taskName] = $taskDialog.FindName($taskName) }
    }
    $script:taskImport.Ui.DialogImportIcon.Source = Get-TaskImage 'icon-import.png'
    foreach ($taskName in @('BrowseFileButton','ConfirmImportButton','CancelImportButton')) { $script:taskImport.Ui[$taskName].Style = $script:taskWindow.FindResource('ActionButton') }
    foreach($name in @('CreateByIP','CreateFromFile')){$script:taskImport.Ui[$name].Style=$script:taskWindow.FindResource('GeoModeStyle');$script:taskImport.Ui[$name].Add_Checked({Set-TaskProfileInputMode})}
    Set-TaskProfileInputMode
    $script:taskImport.Ui.CancelImportButton.IsCancel = $true
    $script:taskImport.Ui.ConfirmImportButton.Background = Get-TaskBrush '#91F2D2'
    $script:taskImport.Ui.ConfirmImportButton.Foreground = Get-TaskBrush '#0C2823'
    $script:taskImport.Ui.ImportHelpButton.Style=$script:taskWindow.FindResource('QuietButton')
    $script:taskImport.Ui.ImportHelpButton.Add_Click({Show-TaskProfileHelp $script:taskImport.Window})
    $script:taskImport.Ui.BrowseFileButton.Add_Click({
        $taskPicker = [Microsoft.Win32.OpenFileDialog]::new()
        $taskPicker.Title = 'Выберите файл настройки hosts'
        $taskPicker.Filter = 'Профиль GeoRoute (*.hosts)|*.hosts'
        $taskPicker.CheckFileExists = $true
        $taskPicker.Multiselect = $false
        if ($taskPicker.ShowDialog($script:taskImport.Window)) {
            try {
                $taskFileInfo = [IO.FileInfo]::new($taskPicker.FileName)
                if ($taskFileInfo.Extension -ine '.hosts' -or $taskFileInfo.Length -gt 1MB) { throw 'Выберите файл .hosts размером не больше 1 МиБ.' }
                $taskMap = @(Get-TaskMap ([IO.File]::ReadAllText($taskPicker.FileName)))
                if ($taskMap.Count -eq 0) { throw 'В файле не найдены адреса и домены.' }
                $script:taskImport.SourcePath = $taskPicker.FileName
                $script:taskImport.Ui.SelectedFileText.Text = $taskFileInfo.Name
                $script:taskImport.Ui.SelectedFileText.ToolTip = $taskFileInfo.FullName
                $script:taskImport.Ui.FileStatsText.Text = (Get-TaskRecordsLabel $taskMap.Count) + ' · проверка при импорте'
                if (-not $script:taskImport.Ui.ProfileNameBox.Text.Trim()) { $script:taskImport.Ui.ProfileNameBox.Text = [IO.Path]::GetFileNameWithoutExtension($taskFileInfo.Name) }
                $script:taskImport.Ui.ImportErrorText.Text = ''
            }
            catch { $script:taskImport.SourcePath = ''; $script:taskImport.Ui.ImportErrorText.Text = $_.Exception.Message }
        }
    })
    $script:taskImport.Ui.CancelImportButton.Add_Click({ $script:taskImport.Window.DialogResult = $false })
    $script:taskImport.Ui.ConfirmImportButton.Add_Click({
        try{$script:taskImport.Data=Get-TaskProfileInput;$script:taskImport.Window.DialogResult=$true}
        catch{$script:taskImport.Ui.ImportErrorText.Text=$_.Exception.Message}
    })
    if (-not $script:taskReducedMotion) { $taskDialog.Content.Opacity = 0 }
    $taskDialog.Content.RenderTransform = [Windows.Media.TranslateTransform]::new()
    $taskDialog.Add_ContentRendered({
        $script:taskImport.Ui.ServerAddressBox.Focus() | Out-Null
        $script:taskImport.Window.Content.Opacity = 1
        if (-not $script:taskReducedMotion) {
            $taskDialogBody = $script:taskImport.Window.Content
            $taskDialogFade = [Windows.Media.Animation.DoubleAnimation]::new(0,1,[Windows.Duration]::new([timespan]::FromMilliseconds(260)))
            $taskDialogSlide = [Windows.Media.Animation.DoubleAnimation]::new(6,0,[Windows.Duration]::new([timespan]::FromMilliseconds(260)))
            $taskDialogSlide.EasingFunction = [Windows.Media.Animation.QuadraticEase]::new()
            $taskDialogSlide.EasingFunction.EasingMode = 'EaseOut'
            $taskDialogBody.BeginAnimation([Windows.UIElement]::OpacityProperty,$taskDialogFade)
            $taskDialogBody.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty,$taskDialogSlide)
        }
    })
    $taskAccepted = $taskDialog.ShowDialog()
    $taskData = $script:taskImport.Data
    $script:taskImport = $null
    if ($taskAccepted -eq $true -and $taskData) { Start-TaskAction 'Import' '' $taskData }
}

try {
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Для графического интерфейса требуется Windows PowerShell с параметром -STA. Используйте ярлык NextDNS.' }
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
    if(-not ('NextDnsWindowChrome' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NextDnsWindowChrome {
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
    public static void EnableDarkTitleBar(IntPtr hwnd) {
        int enabled = 1;
        if (DwmSetWindowAttribute(hwnd, 20, ref enabled, 4) != 0)
            DwmSetWindowAttribute(hwnd, 19, ref enabled, 4);
    }
}
'@
    }
    [xml]$taskXaml = [IO.File]::ReadAllText((Join-Path $script:taskRoot 'Window.xaml'))
    $taskReader = [Xml.XmlNodeReader]::new($taskXaml)
    try { $script:taskWindow = [Windows.Markup.XamlReader]::Load($taskReader) } finally { $taskReader.Close() }
    Register-TaskDarkTitleBar $script:taskWindow
    foreach ($taskNode in $taskXaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
        $taskName = $taskNode.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
        if ($taskName) { $script:taskUi[$taskName] = $script:taskWindow.FindName($taskName) }
    }
    foreach ($taskAsset in @{AppIcon='app-icon.png';ImportIcon='icon-import.png';CheckIcon='icon-cache.png';CacheIcon='icon-check.png';PowerIcon='icon-power.png';LogIcon='icon-log.png';GlobeIcon='icon-globe.png'}.GetEnumerator()) {
        $script:taskUi[$taskAsset.Key].Source = Get-TaskImage $taskAsset.Value
    }
    foreach($taskNavAsset in @{Overview='icon-overview.png';Servers='icon-servers.png';Home='nav-connect-v1.png';Monitor='nav-monitor-v1.png';Journal='nav-journal-v1.png';Settings='nav-settings-v1.png'}.GetEnumerator()) {
        $taskNavImage = $script:taskUi[($taskNavAsset.Key + 'NavIcon')]
        $taskNavImage.Source = Get-TaskImage $taskNavAsset.Value
        if($taskNavImage.Source) { $script:taskUi[($taskNavAsset.Key + 'NavFallback')].Visibility='Collapsed' }
    }
    foreach($asset in @{GeoHeaderArt='network-orbit-v1.png';JournalHeaderArt='nav-journal-v1.png';SettingsHeaderArt='nav-settings-v1.png'}.GetEnumerator()){$script:taskUi[$asset.Key].Source=Get-TaskImage $asset.Value}
    $taskWindowIcon = Get-TaskImage 'app.ico'
    if ($taskWindowIcon) { $script:taskWindow.Icon = $taskWindowIcon }
    $taskArt = Join-Path $script:taskRoot 'assets\app-icon.png'
    $taskHeroCutout = Join-Path $script:taskRoot 'assets\connection-hero-cutout.png'
    if(Test-Path -LiteralPath $taskHeroCutout) { $taskArt = $taskHeroCutout }
    $taskHeroCutoutUi = Join-Path $script:taskRoot 'assets\ui\connection-hero-cutout.png'
    if(Test-Path -LiteralPath $taskHeroCutoutUi) { $taskArt = $taskHeroCutoutUi }
    if (Test-Path -LiteralPath $taskArt) {
        $taskImage = [Windows.Media.Imaging.BitmapImage]::new()
        $taskImage.BeginInit()
        $taskImage.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $taskImage.UriSource = [uri]$taskArt
        $taskImage.EndInit()
        $taskImage.Freeze()
        $script:taskUi.HeroImage.Source = $taskImage
        $script:taskUi.ArtFallback.Visibility = 'Collapsed'
        $script:taskUi.ArtFallbackGlyph.Visibility = 'Collapsed'
    }
    $script:taskReducedMotion = -not [Windows.SystemParameters]::ClientAreaAnimation
    if (Test-Path -LiteralPath $script:taskSettingsPath) {
        try { $taskSettings = [IO.File]::ReadAllText($script:taskSettingsPath) | ConvertFrom-Json; $script:taskReducedMotion = [bool]$taskSettings.ReducedMotion } catch { }
    }
    $script:taskUi.ReducedMotion.IsChecked = $script:taskReducedMotion
    $script:taskReducedMotion = ($script:taskReducedMotion -or -not [Windows.SystemParameters]::ClientAreaAnimation)
    Load-TaskProfiles -Force
    Initialize-GeoMonitor
    Load-TaskHistory
    $initialGeoSettings=Read-GeoSettings $script:taskRoot
    if($initialGeoSettings.PSObject.Properties['preferredProfileId'] -and @($script:taskProfiles|Where-Object Id -eq $initialGeoSettings.preferredProfileId).Count){$script:taskSelectedProfileId=$initialGeoSettings.preferredProfileId}
    [void](Update-TaskStatus -LogChange)
    Set-TaskPage 'Home'
    if($HealthSnapshotPath -and (Test-Path -LiteralPath $HealthSnapshotPath)) { Update-TaskHealthResult ([IO.File]::ReadAllText($HealthSnapshotPath,[Text.Encoding]::UTF8) | ConvertFrom-Json) }
    Add-TaskLog 'Готово к работе. Проверка настроек не проверяет загрузку файлов в ChatGPT.'

    if ($SmokeTest -or $RenderPreview) {
        $script:taskWindow.Content.Measure([Windows.Size]::new(1160,910))
        $script:taskWindow.Content.Arrange([Windows.Rect]::new(0,0,1160,910))
        $script:taskWindow.Content.UpdateLayout()
        [xml]$taskImportXaml = [IO.File]::ReadAllText((Join-Path $script:taskRoot 'ImportDialog.xaml'))
        $taskImportReader = [Xml.XmlNodeReader]::new($taskImportXaml)
        try { $taskImportWindow = [Windows.Markup.XamlReader]::Load($taskImportReader) } finally { $taskImportReader.Close() }
        foreach($name in @('CreateByIP','CreateFromFile')){$taskImportWindow.FindName($name).Style=$script:taskWindow.FindResource('GeoModeStyle')}
        $taskImportWindow.FindName('DialogImportIcon').Source = Get-TaskImage 'icon-import.png'
        foreach ($taskName in @('BrowseFileButton','ConfirmImportButton','CancelImportButton')) { $taskImportWindow.FindName($taskName).Style = $script:taskWindow.FindResource('ActionButton') }
        $taskImportWindow.FindName('ImportHelpButton').Style=$script:taskWindow.FindResource('QuietButton')
        $taskImportWindow.FindName('ConfirmImportButton').Background = Get-TaskBrush '#91F2D2'
        $taskImportWindow.FindName('ConfirmImportButton').Foreground = Get-TaskBrush '#0C2823'
        $taskImportWindow.Content.Measure([Windows.Size]::new(640,660))
        $taskImportWindow.Content.Arrange([Windows.Rect]::new(0,0,640,660))
        $taskImportWindow.Content.UpdateLayout()
        if ($RenderPreview) {
            Export-TaskPreview $PreviewPath
            $taskServerPreviewPath = if ($PreviewPath) { [IO.Path]::Combine([IO.Path]::GetDirectoryName($PreviewPath),([IO.Path]::GetFileNameWithoutExtension($PreviewPath) + '-servers.png')) } else { Join-Path $script:taskRoot 'GUI-preview-servers.png' }
            Set-TaskPage 'Servers'
            Export-TaskPreview $taskServerPreviewPath
            foreach($previewPage in @('Journal','Settings')){Set-TaskPage $previewPage;Export-TaskPreview ($taskServerPreviewPath.Replace('-servers.png',('-'+$previewPage.ToLowerInvariant()+'.png')))}
            Set-TaskPage 'Geo'
            $geoPreviewPath = [IO.Path]::Combine([IO.Path]::GetDirectoryName($taskServerPreviewPath),([IO.Path]::GetFileNameWithoutExtension($taskServerPreviewPath) + '-geohide.png'))
            Export-TaskPreview $geoPreviewPath
            $previewReport=$script:geoReport
            $previewCatalog=Get-Content -LiteralPath (Join-Path $script:taskRoot 'geohide-servers.json') -Raw -Encoding UTF8|ConvertFrom-Json
            Set-GeoMonitorBusy $true
            Update-GeoRows (New-GeoPendingReport $previewCatalog.servers 'preview')
            Export-TaskPreview ($geoPreviewPath.Replace('.png','-loading.png'))
            Set-GeoMonitorBusy $false
            if($previewReport){Update-GeoRows $previewReport}else{$script:geoReport=$null}
            $script:taskWindow.FindName('GeoPage').ScrollToBottom()
            $savedAuto=$script:taskUi.GeoAuto.IsChecked
            $script:taskUi.GeoManual.IsChecked=$true
            Update-GeoEditorState -Force
            Export-TaskPreview ($geoPreviewPath.Replace('.png','-manual.png'))
            $script:taskUi.GeoAuto.IsChecked=$savedAuto
            $script:taskUi.GeoManual.IsChecked=-not $savedAuto
            Update-GeoEditorState -Force
            Set-TaskPage 'Overview'
            $taskImportPreviewPath = if ($PreviewPath) { [IO.Path]::Combine([IO.Path]::GetDirectoryName($PreviewPath),([IO.Path]::GetFileNameWithoutExtension($PreviewPath) + '-import.png')) } else { Join-Path $script:taskRoot 'GUI-preview-import.png' }
            $taskImportBitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(640,660,96,96,[Windows.Media.PixelFormats]::Pbgra32)
            $taskImportBitmap.Render($taskImportWindow.Content)
            $taskImportEncoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
            $taskImportEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($taskImportBitmap))
            $taskImportStream = [IO.File]::Open($taskImportPreviewPath,[IO.FileMode]::Create)
            try { $taskImportEncoder.Save($taskImportStream) } finally { $taskImportStream.Dispose() }
            Write-Output ('Import preview saved: ' + $taskImportPreviewPath)
        }
        foreach($checkPage in @('Journal','Settings')){Set-TaskPage $checkPage;$script:taskWindow.Content.UpdateLayout()}
        $help=New-TaskProfileHelp $script:taskWindow
        $help.Content.Measure([Windows.Size]::new(630,690))
        $help.Content.Arrange([Windows.Rect]::new(0,0,630,690))
        $help.Content.UpdateLayout()
        if($RenderPreview){
            $helpBitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(630,690,96,96,[Windows.Media.PixelFormats]::Pbgra32)
            $helpBitmap.Render($help.Content)
            $helpEncoder=[Windows.Media.Imaging.PngBitmapEncoder]::new()
            $helpEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($helpBitmap))
            $helpPath=[IO.Path]::ChangeExtension($taskImportPreviewPath,$null).TrimEnd('.')+'-help.png'
            $helpStream=[IO.File]::Open($helpPath,[IO.FileMode]::Create)
            try{$helpEncoder.Save($helpStream)}finally{$helpStream.Dispose()}
            Write-Output ('Profile help preview saved: '+$helpPath)
        }
        $help.Close()
        $taskImportWindow.Close()
        Write-Output ('Smoke test OK: main, import and profile help WPF/XAML loaded; ' + $script:taskUi.Count + ' named controls; ' + $script:taskProfiles.Count + ' profiles; no backend action started.')
        $script:taskWindow.Close()
        exit 0
    }

    $script:taskUi.ProfileHelpButton.Add_Click({Show-TaskProfileHelp})
    $script:taskUi.ImportButton.Add_Click({ Show-TaskImportDialog })
    $script:taskUi.CheckButton.Add_Click({ Start-TaskAction 'ClearCache' })
    $script:taskUi.CacheButton.Add_Click({ Start-TaskAction 'Check' })
    $script:taskUi.RestoreButton.Add_Click({ Start-TaskAction 'Restore' })
    $script:taskUi.ApplyProfileButton.Add_Click({ Start-TaskAction 'Apply' $script:taskSelectedProfileId })
    $script:taskUi.HomeNavButton.Add_Click({Set-TaskPage 'Home'})
    $script:taskUi.HomeToggle.Add_Click({Invoke-GeoHomeToggle})
    $script:taskUi.JournalNavButton.Add_Click({Set-TaskPage 'Journal'})
    $script:taskUi.SettingsNavButton.Add_Click({Set-TaskPage 'Settings'})
    $script:taskUi.OverviewNavButton.Add_Click({ Set-TaskPage 'Overview' })
    $script:taskUi.ServersNavButton.Add_Click({ Set-TaskPage 'Servers' })
    $script:taskUi.ChangeServerButton.Add_Click({ Set-TaskPage 'Servers' })
    $script:taskUi.OpenAppButton.Add_Click({ Open-TaskApp })
    $script:taskUi.RepairButton.Add_Click({Open-TaskRepair})
    $script:taskUi.HttpProxyButton.Add_Click({Open-TaskHttpProxy})
    $script:taskUi.ClearLogButton.Add_Click({ Show-TaskLogMenu })
    $script:taskUi.FilterAllButton.Add_Click({ $script:taskLogFilter='All'; Update-TaskLogView })
    $script:taskUi.FilterErrorsButton.Add_Click({ $script:taskLogFilter='Problems'; Update-TaskLogView })
    $script:taskUi.FilterActionsButton.Add_Click({ $script:taskLogFilter='Actions'; Update-TaskLogView })
    $script:taskUi.LogSearchBox.Add_TextChanged({ Update-TaskLogView })
    $script:taskUi.ReducedMotion.Add_Checked({ Set-TaskMotion })
    $script:taskUi.ReducedMotion.Add_Unchecked({ Set-TaskMotion })
    $script:taskUi.CopyLogButton.Add_Click({
        try { [Windows.Clipboard]::SetText((@($script:taskEvents | ForEach-Object { $_.At.ToString('HH:mm:ss') + '  ' + $_.Message }) -join [Environment]::NewLine)); $script:taskUi.ActivityDetail.Text = 'Журнал скопирован в буфер обмена.' }
        catch { $script:taskUi.ActivityDetail.Text = 'Буфер обмена занят. Попробуйте ещё раз.' }
    })
    $script:taskUi.OpenLogButton.Add_Click({
        try {
            $taskLogDirectory = Join-Path $script:taskRoot 'run-results'
            if (-not (Test-Path -LiteralPath $taskLogDirectory)) { New-Item -ItemType Directory -Path $taskLogDirectory | Out-Null }
            Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('"' + $taskLogDirectory + '"') | Out-Null
        }
        catch { Add-TaskLog ('Не удалось открыть папку: ' + $_.Exception.Message) }
    })
    foreach ($taskName in @('ImportButton','CheckButton','CacheButton','RestoreButton','CopyLogButton','OpenLogButton','ApplyProfileButton','ClearLogButton','ChangeServerButton','OpenAppButton')) { Add-TaskButtonMotion $script:taskUi[$taskName] }
    $script:taskTimer = [Windows.Threading.DispatcherTimer]::new()
    $script:taskTimer.Interval = [timespan]::FromMilliseconds(200)
    $script:taskTimer.Add_Tick({
        Poll-GeoMonitor
        Poll-TaskHealth
        Poll-TaskConnection
        Update-GeoHome
        $taskCurrentMotion = (($script:taskUi.ReducedMotion.IsChecked -eq $true) -or -not [Windows.SystemParameters]::ClientAreaAnimation)
        if ($taskCurrentMotion -ne $script:taskReducedMotion) { Set-TaskMotion }
        if ($script:taskRun) {
            Read-TaskWorkerLog
            try {
                if ($script:taskRun.Process.HasExited) { Complete-TaskAction }
                else {
                    $taskElapsed = (Get-Date) - $script:taskRun.StartedAt
                    $script:taskUi.ActivityDetail.Text = 'Выполняется действие · ' + ('{0:mm\:ss}' -f $taskElapsed) + ' · журнал обновляется автоматически'
                }
            }
            catch {
                Add-TaskLog ('Не удалось получить состояние процесса: ' + $_.Exception.Message)
                $script:taskUi.ActivityDetail.Text = 'Ожидаю отчёт. Состояние процесса временно недоступно.'
            }
        }
        elseif (((Get-Date) - $script:taskLastHostsRead).TotalSeconds -ge 5) {
            try { Load-TaskProfiles; [void](Update-TaskStatus -LogChange) }
            catch { Add-TaskLog ('Не удалось обновить список серверов: ' + $_.Exception.Message); $script:taskLastHostsRead = Get-Date }
        }
    })
    $script:taskWindow.Add_Loaded({
        Start-TaskHeroMotion
        if (-not $script:taskReducedMotion) {
            foreach ($taskName in @('HeroCard','ServersPanel','ToolsPanel','JournalCard')) {
                $taskElement = $script:taskUi[$taskName]
                $taskElement.RenderTransform = [Windows.Media.TranslateTransform]::new()
                $taskFade = [Windows.Media.Animation.DoubleAnimation]::new(0,1,[Windows.Duration]::new([timespan]::FromMilliseconds(380)))
                $taskSlide = [Windows.Media.Animation.DoubleAnimation]::new(9,0,[Windows.Duration]::new([timespan]::FromMilliseconds(380)))
                $taskSlide.EasingFunction = [Windows.Media.Animation.CubicEase]::new()
                $taskElement.BeginAnimation([Windows.UIElement]::OpacityProperty,$taskFade)
                $taskElement.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty,$taskSlide)
            }
        }
        $script:taskTimer.Start()
        Start-GeoMonitor -Refresh
        Start-TaskHealth 'Check'
        Start-TaskConnection
        if($Tray){Hide-TaskManager}
    })
    $taskWorkArea = [Windows.SystemParameters]::WorkArea
    $script:taskWindow.Width = [Math]::Min(1220,[Math]::Max(980,$taskWorkArea.Width - 24))
    $script:taskWindow.Height = [Math]::Min(950,[Math]::Max(680,$taskWorkArea.Height - 24))
    $script:taskWindow.Add_Closing({
        param($sender,$eventArgs)
        if(-not $script:taskExitRequested -and $script:taskTray) {
            $eventArgs.Cancel=$true;Hide-TaskManager;return
        }
        if ($script:taskBusy) {
            $eventArgs.Cancel = $true
            $script:taskExitRequested=$false
            Show-TaskManager
            $script:taskUi.ActivityDetail.Text = 'Дождитесь завершения действия, затем закройте окно.'
            Add-TaskLog 'Окно останется открытым до завершения текущего действия.'
        }
        else { $script:taskClosing = $true; $script:taskTimer.Stop();Stop-GeoMonitor;Close-TaskTray }
    })
    $script:taskWindow.Add_Closed({$script:taskApplication.Shutdown()})
    Initialize-TaskTray
    $script:taskApplication=[Windows.Application]::new()
    $script:taskApplication.ShutdownMode='OnExplicitShutdown'
    [void]$script:taskApplication.Run($script:taskWindow)
}
catch {
    $taskFailureText = $_.Exception.Message
    Close-TaskTray
    try { [IO.File]::AppendAllText((Join-Path $script:taskRoot 'GUI-error.log'),((Get-Date).ToString('o') + '  ' + $_.ToString() + [Environment]::NewLine),[Text.UTF8Encoding]::new($true)) } catch { }
    if ($SmokeTest -or $RenderPreview) { Write-Error $taskFailureText; exit 1 }
    try {
        Add-Type -AssemblyName PresentationFramework
        [void][Windows.MessageBox]::Show(('Не удалось открыть GeoRoute.' + [Environment]::NewLine + [Environment]::NewLine + $taskFailureText),'GeoRoute',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Error)
    }
    catch { }
    exit 1
}
finally {Close-GeoRouteInstance $script:taskInstance}
