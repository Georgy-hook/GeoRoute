#Requires -Version 5.1
function Get-GeoQuickStartSteps {
 @(
  [pscustomobject]@{
      Title='Откройте GeoRoute'
      Summary='У Portable и Setup один и тот же главный экран — «Подключение».'
      Tasks=@('Portable: извлеките всю папку из ZIP и откройте GeoRoute.cmd.','Setup: установите GeoRoute и откройте его через ярлык. Python и Java отдельно устанавливать не нужно.')
      Note='WARP заранее устанавливать не нужно.'
  },
  [pscustomobject]@{
      Title='Нажмите «Подключиться»'
      Summary='GeoRoute начнёт с прямой проверки выбранного сервера.'
      Tasks=@('Если сервер ответит, подтвердите запрос Windows на применение профиля.','Дождитесь надписи «Подключено напрямую». WARP для этого не нужен. Если хотите выбрать другой профиль, нажмите «Изменить».')
      Note='Зелёный статус подтверждает HTTPS выбранного сервера, но не вход в аккаунт и не ответ модели.'
  },
  [pscustomobject]@{
      Title='WARP — только по вашему выбору'
      Summary='Если интернет есть, но сервер не ответил, можно повторить проверку напрямую или попробовать тот же сервер через WARP.'
      Tasks=@('Перед первой установкой GeoRoute объяснит, что изменится. «Не сейчас» ничего не устанавливает.','Если компонент уже установлен, повторной установки не будет. После включения туннеля GeoRoute проверит сервер ещё раз.')
      Note='Автоподключение при запуске Windows включается отдельно в «Дополнительно».'
  },
  [pscustomobject]@{
      Title='Как отключиться и где искать помощь'
      Summary='Кнопка «Отключиться» находится на главной. Закрытие окна лишь сворачивает его в трей.'
      Tasks=@('Если сервер через WARP не ответил, нажмите «Вернуться к прямому подключению». При отказе сервиса автоматической смены маршрута нет.','Журналы и ручное управление — в «Дополнительно». Другие сайты настраиваются отдельно: «Серверы → Сайты и DNS».')
      Note='Удаление portable-папки не удаляет службу Windows. При необходимости используйте «Удалить компонент WARP».'
  }
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
 $Window.FindName('GuideNext').Content=if($state.Index -eq $state.Steps.Count-1){'На главный экран'}else{'Далее'}
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
  else{$window.Tag.Target='Home';if($window.IsVisible){$window.DialogResult=$true}}
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
