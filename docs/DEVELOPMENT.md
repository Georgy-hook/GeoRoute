# Development

Windows client source: `clients/windows/_service`. PowerShell scripts require Windows PowerShell 5.1 and are UTF-8 with BOM. WPF is built into Windows. Use CPython 3.14 x64 for build/test tooling; the release includes an isolated runtime for the optional bridge. No custom EXE, C++ toolchain or .NET SDK is required to build this version.

```powershell
.\clients\windows\tests\Run-Tests.ps1 -PythonExe python.exe
.\clients\windows\Build.ps1 -PythonExe python.exe -Version 0.4.1
```

The build produces `clients/windows/dist/GeoRoute-Windows-x64-0.4.1.zip` and its SHA-256. Package verification rejects private user paths, account-specific NextDNS URLs, runtime state/logs/backups, and inconsistent runtime hashes.

`GeoRoute.cmd` opens the existing WPF GUI in the system Windows PowerShell process. It accepts only the fixed normal/tray/repair/smoke modes and never forwards arbitrary command text. The process-scoped ExecutionPolicy argument does not change machine execution policy or antivirus settings. `AppInstance.ps1` owns the mutex/event contract; a second launch activates the existing window, background startup does not unhide it, and exit releases ownership. Tray startup quotes the CMD path explicitly and migrates only exact legacy commands belonging to the same app directory. The UI thread retains per-monitor DPI awareness. CI smoke-tests the packaged entry point, and package validation rejects the removed custom EXE files. Experimental compiled launcher implementations remain in Git history, with their measured outcomes in the security experiments report.

The optional DNS bridge now runs directly as a LocalService-hosted Python process using Windows SCM APIs. `NextDNSBridge.exe` and its C# process wrapper are no longer built or shipped. The installer recognizes the exact legacy command for migration, waits for that process to exit, and changes the service command before starting the replacement. DNS settings still change only through the existing elevated setup action. `Test-BridgeService.ps1` creates a uniquely named temporary service only in a disposable GitHub Windows runner, on a test port, without changing adapter DNS. It checks startup, restart, startup failure cleanup and subsequent recovery.

`GeoAvailability.ps1` owns regional eligibility, profile requirements and provider-list replacement. `GeoHide.ps1` writes prepared profiles; `Profiles.ps1` is the existing elevated hosts apply/restore boundary. `Home.ps1` distinguishes off/checking/ready/unavailable using actual managed hosts plus current probe evidence. Ordinary hosts mode does not require wildcard NextDNS rewrite checks. The optional bridge retains its separate diagnostics.

Tests cover independent US/EU/RU replacement, provider removal and reappearance, mixed-route failures, stale observations, attachment HTTP failure, manual editing, hosts comparison, recovery and protocol boundaries. UI smoke tests do not change the network. Live results are specific to the tested machine/time; do not promote them to global provider availability.

Never commit `geohide-settings.json`, `geohide-monitor.json`, `geohide-history.json`, user profiles/credentials, logs or backups. Provider seed lists and generic hosts templates are public. Do not disable certificate validation or add credentials to releases.

Original cloud DNS configurator docs: [English](../DNS-CONFIGURER.md) / [Russian](../DNS-CONFIGURER.ru.md).
