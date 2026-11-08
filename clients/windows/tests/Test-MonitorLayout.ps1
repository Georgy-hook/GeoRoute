#Requires -Version 5.1
param([string]$ScreenshotDirectory)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
$source=Join-Path (Split-Path $PSScriptRoot -Parent) '_service'
. (Join-Path $source 'GeoHideUI.ps1')
[xml]$xml=Get-Content (Join-Path $source 'Window.xaml') -Raw -Encoding UTF8
$reader=[Xml.XmlNodeReader]::new($xml)
try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
$script:taskUi=@{}
foreach($node in $xml.SelectNodes('//*[@*[local-name()="Name"]]')){$name=$node.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml');if($name){$script:taskUi[$name]=$window.FindName($name)}}
foreach($page in @('HomePage','OverviewPage','ServersPage','JournalPage','SettingsPage')){$window.FindName($page).Visibility='Collapsed'}
$script:taskUi.GeoPage.Visibility='Visible'
$script:taskUi.GeoGrid.ItemsSource=@(1..30|ForEach-Object {[pscustomobject]@{Address=('143.20.64.'+$_);Region='EU';StatusLabel='HTTPS отвечает';State='Проверено';StatusColor='#91F2D2';LoadingVisibility='Collapsed';GeminiLabel='HTTPS отвечает';GeminiColor='#91F2D2';Country='EU';LatencyLabel='1 200 мс';FilesLabel='TLS · 404';FilesColor='#91F2D2';HistoryCount='24 проверки';TCP=$true;TLS=$true;HTTP=200;Error='Длинное пояснение сетевой проверки должно оставаться в своей колонке и быть доступным во всплывающей подсказке.'}})
Initialize-GeoMonitorLayout
function Assert($Value,$Message){if(-not $Value){throw $Message}}
function Find-Visual($Root,[type]$Type) {
 if($Root -is $Type){return $Root}
 for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Root);$i++){
  $found=Find-Visual ([Windows.Media.VisualTreeHelper]::GetChild($Root,$i)) $Type
  if($found){return $found}
 }
}
function Layout([int]$Width,[int]$Height,[bool]$Expanded=$false,[bool]$Loading=$false){
 $root=$window.Content
 $root.Width=$Width;$root.Height=$Height
 $script:taskUi.GeoDetails.IsExpanded=$Expanded
 $script:taskUi.GeoProgressPanel.Visibility=if($Loading){'Visible'}else{'Collapsed'}
 $script:taskUi.GeoProgressText.Text='Проверяю EU · 4 из 15'
 $script:taskUi.GeoStatus.Text='Проверка серверов через физическое подключение · US + EU недоступен: нужны проверки ChatGPT, Gemini и вложений'
 for($pass=0;$pass -lt 3;$pass++){
  $root.Measure([Windows.Size]::new($Width,$Height));$root.Arrange([Windows.Rect]::new(0,0,$Width,$Height));$root.UpdateLayout();Update-GeoMonitorLayout
  $root.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
 }
 $page=$script:taskUi.GeoPage;$table=$script:taskUi.GeoGrid
 $bounds=$table.TransformToAncestor($page).TransformBounds([Windows.Rect]::new(0,0,$table.ActualWidth,$table.ActualHeight))
 Assert ($table.ActualHeight -ge 100) 'Table must retain a usable viewport'
 Assert ($bounds.Bottom -le $page.ActualHeight+1) 'Table extends below the page'
 Assert ($bounds.Right -le $page.ActualWidth+1) 'Table extends beyond the page width'
 if($Expanded){
  $body=$script:taskUi.GeoDetailsScroll
  Assert ($body.ActualHeight -le $body.MaxHeight+1) 'Expanded settings must stay inside their scroll viewport'
  Assert ($script:taskUi.GeoDetails.TransformToAncestor($page).Transform([Windows.Point]::new(0,$script:taskUi.GeoDetails.ActualHeight)).Y -le $page.ActualHeight+1) 'Expanded settings clip the page footer'
 }
 $columns=($table.Columns|Measure-Object ActualWidth -Sum).Sum
 if($Width -ge 1920){Assert ($columns -le $table.ActualWidth+1 -and $columns -ge $table.ActualWidth-40) ('Wide-screen columns must fit and fill the table: columns='+$columns+'; table='+$table.ActualWidth+'; widths='+(@($table.Columns|ForEach-Object {$_.Header+':'+$_.ActualWidth}) -join ', '))}
 if($ScreenshotDirectory){
  [IO.Directory]::CreateDirectory($ScreenshotDirectory)|Out-Null
  $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($Width,$Height,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($root)
  $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
  $path=Join-Path $ScreenshotDirectory ('monitor-'+$Width+'x'+$Height+$(if($Expanded){'-settings'}elseif($Loading){'-loading'}else{''})+'.png')
  $stream=[IO.File]::Create($path);try{$encoder.Save($stream)}finally{$stream.Dispose()}
 }
 return [pscustomobject]@{Width=$Width;Height=$Height;TableWidth=[int]$table.ActualWidth;TableHeight=[int]$table.ActualHeight;VisibleRows=[Math]::Floor(($table.ActualHeight-$table.ColumnHeaderHeight)/$table.RowHeight);ColumnsWidth=[int]$columns;Expanded=$Expanded;Loading=$Loading}
}
try{
 $small=Layout 980 640
 $table=$script:taskUi.GeoGrid
 $scroll=Find-Visual $table ([Windows.Controls.ScrollViewer])
 $bar=$scroll.Template.FindName('PART_HorizontalScrollBar',$scroll)
 Assert ($bar -and $bar.ActualWidth -gt $table.ActualWidth/2 -and $bar.ActualHeight -le 20) ('Horizontal scrollbar must span the movable columns: bar='+$bar.ActualWidth+'x'+$bar.ActualHeight+'; table='+$table.ActualWidth)
 $custom=[Windows.Controls.Primitives.ScrollBar]::new();$custom.Orientation='Horizontal'
 $custom.Style=$window.FindResource([Windows.Controls.Primitives.ScrollBar]);$custom.Maximum=100;$custom.ViewportSize=25
 $custom.Measure([Windows.Size]::new(500,20));$custom.Arrange([Windows.Rect]::new(0,0,500,12));$custom.UpdateLayout()
 $track=$custom.Template.FindName('PART_Track',$custom)
 Assert ($custom.ActualWidth -eq 500 -and $track.Orientation -eq 'Horizontal' -and -not $track.IsDirectionReversed) 'Custom horizontal scrollbar must use its full width and correct direction'
 $row=$table.ItemContainerGenerator.ContainerFromIndex(0)
 $cells=Find-Visual $row ([Windows.Controls.Primitives.DataGridCellsPresenter])
 $cell=$cells.ItemContainerGenerator.ContainerFromIndex(0)
 $before=$cell.TransformToAncestor($table).Transform([Windows.Point]::new(0,0)).X
 $scroll.ScrollToHorizontalOffset(9999)
 $table.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle);$table.UpdateLayout()
 Assert ($scroll.HorizontalOffset -gt 0) 'Narrow table must allow access to right-hand columns'
 $after=$cell.TransformToAncestor($table).Transform([Windows.Point]::new(0,0)).X
 Assert ([Math]::Abs($before-$after) -le 1) 'Server IP must remain fixed while scrolling horizontally'
 $scroll.ScrollToHorizontalOffset(0)
 $normal=Layout 1220 910
 $fullHD=Layout 1920 1040
 $large=Layout 2560 1400
 Assert ($large.TableHeight -gt $normal.TableHeight+400) 'Maximized table must grow with the available height'
 Assert ($large.TableWidth -gt $normal.TableWidth+1000) 'Maximized table must grow with the available width'
 Assert ($large.VisibleRows -ge 15) ('Large-screen viewport should expose the current 15-server list: '+($large|ConvertTo-Json -Compress))
 $last=$script:taskUi.GeoGrid.ItemContainerGenerator.ContainerFromIndex(14)
 Assert ($last -and $last.TransformToAncestor($script:taskUi.GeoGrid).Transform([Windows.Point]::new(0,$last.ActualHeight)).Y -le $script:taskUi.GeoGrid.ActualHeight+1) 'The fifteenth actual row must be fully visible on the large screen'
 $editor=Layout 980 640 $true
 $editorLoading=Layout 980 640 $true $true
 $loading=Layout 1220 910 $false $true
 $restore=Layout 1220 910
 Assert ([Math]::Abs($restore.TableHeight-$normal.TableHeight) -le 1) 'Restoring a window must restore the table viewport'
 @($small,$normal,$fullHD,$large,$editor,$editorLoading,$loading)|ConvertTo-Json -Compress
 Write-Output 'Monitor layout passed: small/restored/maximized viewports, star columns, scrollable settings and loading state.'
}finally{$window.Close()}
