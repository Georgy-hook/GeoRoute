#Requires -Version 5.1
param([switch]$SmokeTest,[string]$PreviewPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'HttpProxy.ps1')
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
[xml]$xaml=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'HttpProxyDialog.xaml') -Raw -Encoding UTF8
$reader=[Xml.XmlNodeReader]::new($xaml)
try {$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
$ui=@{};foreach($node in $xaml.SelectNodes('//*[@*[local-name()="Name"]]')){$name=$node.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml');$ui[$name]=$window.FindName($name)}
$ui.Flag.Source=[Windows.Media.Imaging.BitmapFrame]::Create([uri](Join-Path $PSScriptRoot 'assets\ui\flag-US.png'))
$script:proxyRun=$null
$script:proxyResultPath=$null
$script:proxyStarted=[datetime]::MinValue
function Update-ProxyDialog {
 $state=Get-HttpProxyState $PSScriptRoot;$ui.State.Text=$state.Text
 $ui.Disable.IsEnabled=$state.Enabled -and -not $script:proxyRun
 if(-not $ui.Server.Text){$ui.Server.Text=$state.Server}
}
function Start-ProxyDialogCheck([string]$Mode) {
 if($script:proxyRun){return}
 try {
  $endpoint=ConvertTo-ChatGptProxyEndpoint $ui.Server.Text.Trim()
  $runRoot=Join-Path $PSScriptRoot 'run-results';[IO.Directory]::CreateDirectory($runRoot)|Out-Null
  if((Get-Item -LiteralPath $runRoot).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Папка результатов не должна быть ссылкой.'}
  $script:proxyResultPath=Join-Path $runRoot ('gui-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.json')
  $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $PSScriptRoot 'HttpProxyWorker.ps1')+'"'),'-Mode',$Mode,'-Server',$endpoint.Server,'-ResultPath',('"'+$script:proxyResultPath+'"'))
  $script:proxyRun=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru
  $script:proxyStarted=Get-Date
  foreach($name in @('Check','Enable','Disable','Server')){$ui[$name].IsEnabled=$false}
  $ui.Progress.Visibility='Visible';$ui.Result.Text='Проверяем HTTPS и страну выхода… до 10 секунд.'
 }catch{$ui.Result.Text=$_.Exception.Message}
}
$ui.Check.Add_Click({Start-ProxyDialogCheck 'Check'})
$ui.Enable.Add_Click({Start-ProxyDialogCheck 'Enable'})
$ui.Disable.Add_Click({try{Remove-ChatGptHttpProxy $PSScriptRoot;$ui.Result.Text='Прежняя настройка Windows возвращена. Уже открытые соединения приложения могут завершиться по старому маршруту.';Update-ProxyDialog}catch{$ui.Result.Text=$_.Exception.Message}})
$timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[timespan]::FromMilliseconds(300)
$timer.Add_Tick({
 if($script:proxyRun -and ($script:proxyRun.HasExited -or ((Get-Date)-$script:proxyStarted).TotalSeconds -gt 15)){
  try {
   if(-not $script:proxyRun.HasExited){$script:proxyRun.Kill();throw 'Проверка превысила время ожидания. Применение настройки не подтверждено.'}
   $result=Get-Content -LiteralPath $script:proxyResultPath -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json
   $ui.Result.Text=([datetime]$result.At).ToString('HH:mm:ss')+' · '+$result.Message
  }catch{$ui.Result.Text=$_.Exception.Message}
  finally{$script:proxyRun.Dispose();$script:proxyRun=$null;$ui.Progress.Visibility='Collapsed';foreach($name in @('Check','Enable','Server')){$ui[$name].IsEnabled=$true};Update-ProxyDialog}
 }
})
$window.Add_Closing({param($sender,$args) if($script:proxyRun){$args.Cancel=$true;$ui.Result.Text='Дождитесь завершения проверки.'}})
$window.Add_Closed({$timer.Stop()})
Update-ProxyDialog
if($SmokeTest){
 $window.Content.Measure([Windows.Size]::new(660,590));$window.Content.Arrange([Windows.Rect]::new(0,0,660,590));$window.Content.UpdateLayout()
 if($PreviewPath){$bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(660,590,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($window.Content);$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap));$stream=[IO.File]::Create($PreviewPath);try{$encoder.Save($stream)}finally{$stream.Dispose()}}
 Write-Output 'HTTP proxy UI smoke: OK; no settings changed.';exit 0
}
$window.MaxHeight=[Windows.SystemParameters]::WorkArea.Height
$window.Add_Loaded({Start-ProxyDialogCheck 'Check'})
$timer.Start();[void]$window.ShowDialog()
