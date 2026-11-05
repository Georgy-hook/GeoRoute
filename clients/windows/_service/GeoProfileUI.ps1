function Update-GeoProfileCards {
    foreach($profile in $script:taskProfiles){
        if(-not $script:taskProfileControls.ContainsKey($profile.Id)){continue}
        $controls=$script:taskProfileControls[$profile.Id]
        $state=Get-GeoProfileAvailability $script:taskRoot $profile.Id $script:geoReport
        $controls.Status.Text=if($state.Ready){'● '+$state.Reason}else{'● Нельзя подключить: '+$state.Reason}
        $controls.Status.Foreground=Get-TaskBrush $(if(-not $state.Managed){'#9CAEC4'}elseif($state.State -eq 'attention'){'#F6C56B'}elseif($state.Ready){'#91F2D2'}else{'#FFAC9A'})
        $controls.Card.ToolTip=$state.Reason
        $controls.Button.IsEnabled=(-not $script:taskBusy -and $state.Ready)
        if(-not $state.Ready){$controls.Button.Content='Недоступен';$controls.Button.Background=Get-TaskBrush '#192638';$controls.Button.Foreground=Get-TaskBrush '#9CAEC4'}
    }
    $script:taskUi.ApplyProfileButton.IsEnabled=$false
    if($script:taskSelectedProfileId){
        $state=Get-GeoProfileAvailability $script:taskRoot $script:taskSelectedProfileId $script:geoReport
        $script:taskUi.ApplyProfileButton.IsEnabled=(-not $script:taskBusy -and $state.Ready)
        if(-not $state.Ready){$script:taskUi.SelectedProfileDetail.Text=$state.Reason}
    }
}
function Sync-GeoRegions($Report) {
    if($script:taskBusy -or $Report.running -or $SmokeTest -or $RenderPreview){return}
    $settings=Read-GeoSettings $script:taskRoot
    $selected=Get-GeoSelection $settings $Report
    if($settings.autoSelect){$settings.us=$selected.us;$settings.eu=$selected.eu}
    $settings.ru=$selected.ru
    # Sync all regional templates even if the selected pair did not change:
    # a newly published backup or recovered RU node must also be propagated.
    Save-GeoProfile $script:taskRoot $settings $Report
    if($settings.autoSelect){$script:taskUi.GeoUS.Text=$settings.us;$script:taskUi.GeoEU.Text=$settings.eu}
    Load-TaskProfiles -Force
    if(-not $selected.usReady -or -not $selected.euReady){$script:taskUi.GeoStatus.Text+=' · US + EU недоступен: нужны проверки ChatGPT, Gemini и вложений'}
}
