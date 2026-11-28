#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'HomeCheck.ps1')

function Set-GeoHomePhase([string]$Phase, [string]$Note='') {
    $script:homePhase = $Phase
    $script:homeNote = $Note
    $script:homePhaseAt = Get-Date
    if ($Phase -eq 'Offer') { $script:homeOfferAt = $script:homePhaseAt }
    $follow = $script:taskPage -eq 'Home' -and $script:taskUi.HomePage.IsKeyboardFocusWithin
    Update-GeoHome -Force
    if ($follow) {
        $ui = $script:taskUi
        $next = if ($Phase -in @('Consent','InstallOnly') -or $ui.HomeToggle.Visibility -ne 'Visible') { $ui.HomeSecondary } else { $ui.HomeToggle }
        if ($next.IsVisible -and $next.IsEnabled) { [void]$next.Focus() }
    }
}

function Start-GeoHomeDirect {
    $value = Get-WarpState
    if ($value.Requested -or $value.Connected) {
        Set-GeoHomePhase Conflict
        return
    }
    $script:homeTarget = Get-GeoHomeProfile
    if (-not $script:homeTarget) {
        Set-GeoHomePhase Manual
        return
    }
    $state = Get-GeoHomeState $script:taskRoot $script:geoReport
    if ($state.On -and -not (Test-GeoHomeApplied $script:homeTarget Physical)) {
        Set-GeoHomePhase ActiveMismatch
        return
    }
    $catalog = [IO.File]::ReadAllText((Join-Path $script:taskRoot 'profiles.json')) | ConvertFrom-Json
    $entry = @($catalog.Profiles | Where-Object id -CEQ $script:homeTarget.Id)
    if ($entry.Count -ne 1 -or -not (Get-GeoProfileRegion $entry[0])) {
        Set-GeoHomePhase Manual
        return
    }
    $script:homeNeeds = @(Get-GeoProfileNeeds $script:taskRoot $entry[0])
    Start-GeoHomeCheck Physical
}

function Complete-GeoHomeCheck([string]$Outcome, [string]$Transport, $Report) {
    if ($Transport -eq 'Warp') {
        if ($Outcome -eq 'Ready') {
            $script:homeWarpCommand = $Report.WarpCommandId
            Set-GeoHomePhase WarpReady
        } else {
            $note = if ($Outcome -eq 'Denied') { 'Сервис ограничил доступ. Смена сервера не выполнялась.' }
                    else { 'Ответ выбранного сервера через туннель не подтверждён.' }
            Set-GeoHomePhase WarpFailed $note
        }
        return
    }
    switch ($Outcome) {
        Ready {
            if (Test-GeoHomeApplied $script:homeTarget 'Physical') {
                Set-GeoHomePhase DirectReady
                return
            }
            $script:homeDirectReport = $Report
            Set-GeoHomePhase Apply
            Start-TaskAction Apply $script:homeTarget.Id -FromHome
        }
        NoReply { Set-GeoHomePhase Offer }
        CheckInternet { Set-GeoHomePhase CheckInternet }
        Denied { Set-GeoHomePhase Denied }
        default { Set-GeoHomePhase Failed }
    }
}

function Start-GeoHomeWarp {
    if (-not (Test-GeoHomeTarget)) {
        Set-GeoHomePhase Changed
        return
    }
    $warp = Get-WarpState
    if ($warp.Requested -or $warp.Connected) {
        Set-GeoHomePhase Conflict
        return
    }
    $profile = Get-WarpProfile $script:taskRoot $script:homeTarget.Id
    $warpMap = @($profile.map | ForEach-Object { $_.address + ' ' + $_.domain } | Sort-Object) -join "`n"
    if ($warpMap -cne $script:homeTarget.MapKey) {
        Set-GeoHomePhase Changed
        return
    }
    if (-not $warp.Installed) {
        Set-GeoHomePhase Consent
        return
    }
    if (-not $warp.CanControl) {
        Set-GeoHomePhase OtherOwner
        return
    }
    Set-GeoHomePhase ConnectWarp
    Start-TaskWarpAction Connect $script:homeTarget.Id -FromHome
}

function Complete-GeoHomeWarpAction([string]$Mode, [bool]$Ok) {
    if (-not $Ok) {
        $phase = if ($Mode -eq 'Install') { 'InstallFailed' } else { 'WarpFailed' }
        Set-GeoHomePhase $phase
        return
    }
    switch ($Mode) {
        Install {
            if ($script:homePhase -eq 'InstallOnlyBusy') {
                Set-GeoHomePhase Installed
                return
            }
            if (-not (Get-WarpState).Installed) {
                Set-GeoHomePhase InstallFailed
                return
            }
            Start-GeoHomeWarp
        }
        Connect { Start-GeoHomeCheck Warp }
        Disconnect {
            if ($script:homePhase -eq 'ReturnDirect') {
                if (Test-GeoHomeTarget) { Start-GeoHomeCheck Physical } else { Set-GeoHomePhase Changed }
            } else { Set-GeoHomePhase '' }
        }
    }
}

function Complete-GeoHomeDirectAction([string]$Mode, [bool]$Ok, [string]$Failure='') {
    if (-not $Ok) {
        Set-GeoHomePhase Failed $Failure
        return
    }
    if ($Mode -eq 'Restore') {
        Set-GeoHomePhase ''
        return
    }
    if ((Test-GeoHomeTarget) -and (Test-GeoHomeApplied $script:homeTarget 'Physical')) {
        Set-GeoHomePhase DirectReady
    } else { Set-GeoHomePhase Changed }
}

# All side effects are dispatched by a visible action, or by completion of that same approved attempt.
function Invoke-GeoHomeAction([string]$Action) {
    if ($SmokeTest -or $RenderPreview -or -not $Action) { return }
    try {
        if ($Action -eq 'CancelCheck' -and $script:homeCheck) {
            $wasWarp = $script:homeCheck.Transport -eq 'Warp'
            Close-GeoHomeCheck $script:homeCheck
            if ($wasWarp) { Set-GeoHomePhase WarpFailed 'Проверка отменена. Туннель остаётся включённым.' }
            else { Set-GeoHomePhase '' }
            return
        }
        if ($script:taskBusy -or $script:warpRun -or $script:homeCheck) { return }
        switch ($Action) {
            Direct { Start-GeoHomeDirect }
            CheckActive {
                if (Test-GeoHomeApplied (Get-GeoHomeProfile) Physical) { Start-GeoHomeDirect }
                else { Set-GeoHomePhase ActiveMismatch }
            }
            Retry {
                if ($script:homeTarget -and -not (Test-GeoHomeTarget)) {
                    Set-GeoHomePhase Changed
                    return
                }
                Start-GeoHomeDirect
            }
            TryWarp {
                if ($script:homePhase -ne 'Offer') { return }
                if (((Get-Date) - $script:homeOfferAt).TotalMinutes -gt 5) {
                    Set-GeoHomePhase Expired
                    return
                }
                Start-GeoHomeWarp
            }
            Install {
                if ($script:homePhase -notin @('Consent','InstallOnly')) { return }
                $only = $script:homePhase -eq 'InstallOnly'
                if (-not $only -and ((Get-Date) - $script:homeOfferAt).TotalMinutes -gt 5) {
                    Set-GeoHomePhase Expired
                    return
                }
                if (-not $only -and -not (Test-GeoHomeTarget)) {
                    Set-GeoHomePhase Changed
                    return
                }
                if ((Get-WarpState).Installed) {
                    if ($only) { Set-GeoHomePhase Installed } else { Start-GeoHomeWarp }
                    return
                }
                Set-GeoHomePhase $(if ($only) { 'InstallOnlyBusy' } else { 'Installing' })
                Start-TaskWarpAction Install -FromHome
            }
            Cancel { Set-GeoHomePhase '' }
            VerifyWarp {
                $script:homeTarget = Get-GeoHomeProfile
                if (-not $script:homeTarget -or -not (Test-GeoHomeApplied $script:homeTarget 'Warp')) {
                    Set-GeoHomePhase Conflict
                    return
                }
                $catalog = [IO.File]::ReadAllText((Join-Path $script:taskRoot 'profiles.json')) | ConvertFrom-Json
                $entry = @($catalog.Profiles | Where-Object id -CEQ $script:homeTarget.Id)
                if ($entry.Count -ne 1) {
                    Set-GeoHomePhase Conflict
                    return
                }
                $script:homeNeeds = @(Get-GeoProfileNeeds $script:taskRoot $entry[0])
                Start-GeoHomeCheck Warp
            }
            BackDirect {
                $warp = Get-WarpState
                if ($warp.Requested -or $warp.Connected -or $warp.State -eq 'cleanup-required') {
                    if (-not $warp.CanControl) {
                        Set-GeoHomePhase OtherOwner
                        return
                    }
                    if ($warp.ProfileId -and $script:homeTarget -and $warp.ProfileId -cne $script:homeTarget.Id) {
                        Set-GeoHomePhase Conflict
                        return
                    }
                    Set-GeoHomePhase ReturnDirect
                    Start-TaskWarpAction Disconnect -FromHome
                } elseif (Test-GeoHomeTarget) { Start-GeoHomeCheck Physical } else { Set-GeoHomePhase '' }
            }
            Disconnect {
                $state = Get-GeoHomeState $script:taskRoot $script:geoReport
                if (-not $state.On) {
                    Set-GeoHomePhase ''
                    return
                }
                if ($state.Transport -eq 'Warp') {
                    if (-not (Get-WarpState).CanControl) {
                        Set-GeoHomePhase OtherOwner
                        return
                    }
                    Set-GeoHomePhase Disconnecting
                    Start-TaskWarpAction Disconnect -FromHome
                } else {
                    Set-GeoHomePhase Disconnecting
                    Start-TaskAction Restore -FromHome
                }
            }
            Servers { Set-TaskPage Servers }
            Settings { Set-TaskPage Settings }
            Help { Set-TaskPage Overview }
        }
    } catch {
        Add-TaskLog ('Подключение: ' + $_.Exception.Message) -Kind Problems
        Set-GeoHomePhase Failed
    }
}
