#Requires -Version 5.1
function Get-GeoQuickStartSteps {
 @(
  [pscustomobject]@{Title='Запустите GeoRoute';Summary='Portable работает из распакованной папки. Setup создаёт ярлык и устанавливает приложение.';Tasks=@('Извлеките всю папку из ZIP. Запускайте GeoRoute.cmd, а не отдельные файлы внутри _service.','Python и Java устанавливать не нужно. Не переносите и не удаляйте папку, пока приложение работает.');Note='Для обычного подключения аккаунт NextDNS и ключ VPN не нужны.'},
  [pscustomobject]@{Title='Выберите способ подключения';Summary='Начните с обычного профиля GeoHide. Дополнительные режимы включаются отдельно.';Tasks=@('Обычный профиль: GeoRoute задаёт адреса ChatGPT, Gemini и вложений. Другие приложения продолжают работать как раньше.','Если провайдер блокирует GeoHide: в «Настройки → WARP для GeoHide» установите компонент и подключите его. Windows один раз запросит администратора.');Note='Автоподключение WARP и запуск GeoRoute в трее настраиваются отдельно. Оба варианта можно оставить выключенными.'},
  [pscustomobject]@{Title='Проверьте и подключите сервер';Summary='Сначала найдите отвечающий узел, затем примените профиль.';Tasks=@('В «Мониторинг → Серверы GeoHide» нажмите «Проверить серверы». Дождитесь завершения: повторное нажатие во время проверки недоступно.','В «Серверы» выберите подходящий профиль и нажмите «Подключить». Проверка и автовыбор сами по себе подключение не включают.','Для своего сервера: «Добавить сервер», введите IP, выберите страну и сохраните. Флаг подписывает страну; местоположение сервера он не меняет.');Note='ChatGPT, вложения и Gemini проверяются отдельно. Успешный HTTPS ещё не подтверждает ответ модели в вашем аккаунте.'},
  [pscustomobject]@{Title='Если что-то не открывается';Summary='Начните с проверки выбранного узла, затем проверьте само приложение.';Tasks=@('Для GIF и вложений откройте «Помощь». После смены маршрута полностью закройте и снова откройте Chrome или Dot. Одна очистка DNS-кеша помогает не всегда.','Другие сайты добавляются через «Серверы → Сайты и DNS». Выберите DNS-провайдера, добавьте сайты и включите этот режим отдельно.','Отключить соединение можно кнопкой на главной. Закрытие окна сворачивает GeoRoute в трей. Журнал действий находится слева.');Note='Перед удалением папки portable выключите подключение, дополнительный DNS и удалите компонент WARP, если устанавливали его.'}
 )
}
function Update-GeoQuickStart($Window) {
 $state=$Window.Tag;$step=$state.Steps[$state.Index]
 $Window.FindName('GuideCounter').Text=('{0} из {1}' -f ($state.Index+1),$state.Steps.Count)
 $Window.FindName('GuideProgress').Value=$state.Index+1
 $Window.FindName('GuideProgress').Maximum=$state.Steps.Count
 $Window.FindName('GuideTitle').Text=$step.Title
 $Window.FindName('GuideSummary').Text=$step.Summary
 $Window.FindName('GuideTasks').ItemsSource=$step.Tasks
 $Window.FindName('GuideNote').Text=$step.Note
 $Window.FindName('GuideBack').IsEnabled=$state.Index -gt 0
 $Window.FindName('GuideNext').Content=if($state.Index -eq $state.Steps.Count-1){'Выбрать сервер'}else{'Далее'}
}
function New-GeoQuickStart([string]$Root,$Owner=$null){
 $reader=[Xml.XmlNodeReader]::new([xml][IO.File]::ReadAllText((Join-Path $Root 'QuickStart.xaml')))
 try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
 if($Owner -and $Owner.IsLoaded){$window.Owner=$Owner}
 $window.Height=[Math]::Min(680,[Windows.SystemParameters]::WorkArea.Height-40)
 $window.Tag=[pscustomobject]@{Index=0;Steps=@(Get-GeoQuickStartSteps);Target=''}
 $window.FindName('GuideBack').Add_Click({param($sender,$eventArgs) $window=[Windows.Window]::GetWindow($sender);$window.Tag.Index=[Math]::Max(0,$window.Tag.Index-1);Update-GeoQuickStart $window})
 $window.FindName('GuideNext').Add_Click({param($sender,$eventArgs)
  $window=[Windows.Window]::GetWindow($sender)
  if($window.Tag.Index -lt $window.Tag.Steps.Count-1){$window.Tag.Index++;Update-GeoQuickStart $window}
  else{$window.Tag.Target='Servers';if($window.IsVisible){$window.DialogResult=$true}}
 })
 $window.FindName('GuideClose').Add_Click({param($sender,$eventArgs) $window=[Windows.Window]::GetWindow($sender);if($window.IsVisible){$window.DialogResult=$false}})
 Update-GeoQuickStart $window
 return $window
}
function Show-TaskQuickStart {
 $window=New-GeoQuickStart $script:taskRoot $script:taskWindow
 Register-TaskDarkTitleBar $window
 Register-TaskDialogKeys $window
 [void]$window.ShowDialog()
 if($window.Tag.Target){Set-TaskPage $window.Tag.Target}
}
