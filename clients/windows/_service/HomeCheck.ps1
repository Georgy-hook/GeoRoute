# The home check is read-only. It has its own report and never feeds the catalogue or auto-selection.
function Resolve-GeoHomeCheck($Report, $Needs, [string]$Transport) {
    if (-not $Report -or $Report.running -or -not @($Needs).Count) { return 'Unknown' }
    if ($Report.HomeIssue -eq 'NoNetwork') { return 'CheckInternet' }
    $missing = $false
    $unknown = $false
    foreach ($need in $Needs) {
        $rows = @($Report.rows | Where-Object { $_.Address -eq $need.Address -and $_.Region -eq $need.Role })
        if ($rows.Count -ne 1) { return 'Unknown' }
        $row = $rows[0]
        if ($row.Transport -ne $Transport -or $row.CheckState -ne 'Complete' -or $row.SourceActive -ne $true -or
            -not (Test-GeoObservationFresh $row)) { return 'Unknown' }
        if ($need.Service -eq 'Gemini') {
            if ($row.GeminiDenied -or $row.GeminiChallenge) { return 'Denied' }
            if (-not $row.GeminiReady) {
                if ($row.GeminiNoReply) { $missing = $true } else { $unknown = $true }
            }
        } else {
            if ($row.ChatDenied -or ($need.Files -and $row.FilesDenied)) { return 'Denied' }
            $eligible = $row.('Eligible' + $need.Role)
            if (-not $eligible) {
                if ($row.ChatNoReply) { $missing = $true } else { $unknown = $true }
            }
            if ($need.Files -and (-not $row.FilesTLS -or $row.FilesHTTP -notin @(200,204,301,302,400,401,404,405))) {
                if ($row.FilesNoReply) { $missing = $true } else { $unknown = $true }
            }
        }
    }
    if ($unknown) { return 'Unavailable' }
    if ($missing) {
        if ($Transport -eq 'Physical' -and -not $Report.InternetConfirmed) { return 'CheckInternet' }
        return 'NoReply'
    }
    return 'Ready'
}

function Get-GeoHomeProfile {
    $id = $script:taskSelectedProfileId
    if (-not $id) { $id = Get-GeoCombinedId $script:taskRoot }
    return $script:taskProfiles | Where-Object Id -CEQ $id | Select-Object -First 1
}

function Test-GeoHomeTarget {
    $current = Get-GeoHomeProfile
    return $null -ne $script:homeTarget -and $null -ne $current -and
        $current.Id -ceq $script:homeTarget.Id -and $current.MapKey -ceq $script:homeTarget.MapKey
}

function Test-GeoHomeApplied($Target, [string]$Transport, [string]$HostsPath = (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts')) {
    if (-not $Target) { return $false }
    $text = [IO.File]::ReadAllText($HostsPath)
    $blocks = [regex]::Matches($text, '(?ms)^# BEGIN CHATGPT-US-WINDOWS\r?\n(.*?)^# END CHATGPT-US-WINDOWS')
    if ($blocks.Count -ne 1) { return $false }
    $block = $blocks[0].Groups[1].Value
    $warp = $block -match '(?m)^# Transport: GeoRouteWARP\s*$'
    return $warp -eq ($Transport -eq 'Warp') -and ((Get-TaskMap $block) -join "`n") -ceq $Target.MapKey
}

function Start-GeoHomeCheck([ValidateSet('Physical','Warp')][string]$Transport) {
    if ($script:homeCheck -or $script:taskBusy -or $SmokeTest -or $RenderPreview) { return }
    if (-not (Test-GeoHomeTarget)) {
        Set-GeoHomePhase Changed
        return
    }
    try {
        if ($script:homeTarget.Id -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw 'Некорректный ID профиля.' }
        $directory = Join-Path $script:taskRoot 'run-results'
        [void][IO.Directory]::CreateDirectory($directory)
        if ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Небезопасный путь отчёта.' }
        $id = [guid]::NewGuid().ToString('N')
        $path = Join-Path $directory ('home-' + $id + '.json')
        $args = @('-NoLogo','-NoProfile','-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass',
            '-File',('"' + (Join-Path $script:taskRoot 'GeoHideWorker.ps1') + '"'),
            '-ResultPath',('"' + $path + '"'),'-RunId',$id,'-HomeProfileId',('"' + $script:homeTarget.Id + '"'),'-HomeTransport',$Transport)
        $process = Start-Process -FilePath $script:taskShell -ArgumentList $args -WindowStyle Hidden -PassThru -ErrorAction Stop
        $script:homeCheck = [pscustomobject]@{
            Id = $id
            Path = $path
            Process = $process
            Transport = $Transport
            Started = Get-Date
        }
        Set-TaskBusy $true
        if ($Transport -eq 'Warp') { Set-GeoHomePhase CheckWarp } else { Set-GeoHomePhase CheckDirect }
    } catch {
        Add-TaskLog ('Проверка профиля: ' + $_.Exception.Message) -Kind Problems
        Set-GeoHomePhase $(if ($Transport -eq 'Warp') { 'WarpFailed' } else { 'Failed' })
    }
}

function Close-GeoHomeCheck($Run) {
    if (-not $Run) { return }
    try {
        if (-not $Run.Process.HasExited) {
            $Run.Process.Kill()
            $Run.Process.WaitForExit(2000) | Out-Null
        }
    } finally {
        $Run.Process.Dispose()
        Remove-Item -LiteralPath $Run.Path -Force -ErrorAction SilentlyContinue
        $script:homeCheck = $null
        Set-TaskBusy $false
    }
}

function Poll-GeoHomeCheck {
    $run = $script:homeCheck
    if (-not $run) { return }
    if (-not $run.Process.HasExited -and ((Get-Date) - $run.Started).TotalSeconds -lt 90) { return }
    try {
        if (-not $run.Process.HasExited -or $run.Process.ExitCode -ne 0) { throw 'Проверка не завершена. Проверьте интернет и повторите.' }
        $report = [IO.File]::ReadAllText($run.Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($report.runId -cne $run.Id -or $report.ProfileId -cne $script:homeTarget.Id) { throw 'Ответ относится к другой проверке.' }
        $warp = Get-WarpState
        if ($run.Transport -eq 'Warp') {
            if (-not $warp.Connected -or -not $warp.CanControl -or $warp.ProfileId -cne $script:homeTarget.Id -or
                -not $report.WarpCommandId -or $warp.CommandId -cne $report.WarpCommandId -or
                -not (Test-GeoHomeApplied $script:homeTarget 'Warp')) { throw 'Выбранный маршрут WARP изменился.' }
        } elseif ($warp.Requested -or $warp.Connected) { throw 'Во время прямой проверки изменилось подключение.' }
        $outcome = Resolve-GeoHomeCheck $report $script:homeNeeds $run.Transport
    } catch {
        $outcome = 'Unknown'
        Add-TaskLog $_.Exception.Message -Kind Problems
    } finally { Close-GeoHomeCheck $run }
    if (-not (Test-GeoHomeTarget)) {
        Set-GeoHomePhase Changed
        return
    }
    Complete-GeoHomeCheck $outcome $run.Transport $report
}
