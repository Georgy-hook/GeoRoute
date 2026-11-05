# Development

Windows client source: `clients/windows/_service`. PowerShell scripts require Windows PowerShell 5.1 and are UTF-8 with BOM. WPF is built into Windows. Building the launcher requires Visual Studio C++ Build Tools and Windows SDK; consumers do not need a compiler. Use CPython 3.14 x64 for build/test tooling; the release includes an isolated runtime for the optional bridge.

```powershell
.\clients\windows\tests\Run-Tests.ps1 -PythonExe python.exe
.\clients\windows\Build.ps1 -PythonExe python.exe -Version 0.4.1
```

The build produces `clients/windows/dist/GeoRoute-Windows-x64-0.4.1.zip` and its SHA-256. Package verification rejects private user paths, account-specific NextDNS URLs, runtime state/logs/backups, and inconsistent runtime hashes.

The launcher uses the ordinary native project `GeoRoute.Launcher.vcxproj`, static CRT, ASLR/DEP/CFG and reproducible MSVC output. It starts the system Windows PowerShell process with a fixed local script and an allowlisted argument contract. It neither embeds a PowerShell engine nor downloads executable code. A user/session-specific named event retains single-instance window activation; the GUI opts into per-monitor DPI awareness on its UI thread. Windows CI launches the compiled GUI in smoke-test mode and independently rebuilds its EXE into another directory to compare SHA-256. Build scripts and native sources remain in Git and are excluded from the user ZIP.

The optional DNS bridge now runs directly as a LocalService-hosted Python process using Windows SCM APIs. `NextDNSBridge.exe` and its C# process wrapper are no longer built or shipped. The installer recognizes the exact legacy command for migration, waits for that process to exit, and changes the service command before starting the replacement. DNS settings still change only through the existing elevated setup action. `Test-BridgeService.ps1` creates a uniquely named temporary service only in a disposable GitHub Windows runner, on a test port, without changing adapter DNS. It checks startup, restart, startup failure cleanup and subsequent recovery.

`GeoAvailability.ps1` owns regional eligibility, profile requirements and provider-list replacement. `GeoHide.ps1` writes prepared profiles; `Profiles.ps1` is the existing elevated hosts apply/restore boundary. `Home.ps1` distinguishes off/checking/ready/unavailable using actual managed hosts plus current probe evidence. Ordinary hosts mode does not require wildcard NextDNS rewrite checks. The optional bridge retains its separate diagnostics.

Tests cover independent US/EU/RU replacement, provider removal and reappearance, mixed-route failures, stale observations, attachment HTTP failure, manual editing, hosts comparison, recovery and protocol boundaries. UI smoke tests do not change the network. Live results are specific to the tested machine/time; do not promote them to global provider availability.

Never commit `geohide-settings.json`, `geohide-monitor.json`, `geohide-history.json`, user profiles/credentials, logs or backups. Provider seed lists and generic hosts templates are public. Do not disable certificate validation or add credentials to releases.

Original cloud DNS configurator docs: [English](../DNS-CONFIGURER.md) / [Russian](../DNS-CONFIGURER.ru.md).
