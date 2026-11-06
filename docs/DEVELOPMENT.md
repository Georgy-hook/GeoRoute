# Development

Windows client source: `clients/windows/_service`. PowerShell scripts require Windows PowerShell 5.1 and are UTF-8 with BOM. WPF is built into Windows. Use CPython 3.14 x64 for build/test tooling; the release includes an isolated runtime for the optional bridge. GUI and Bridge need no custom EXE, C++ toolchain or .NET SDK. The MSI build uses WiX Toolset 3.14.1 from the GitHub Windows runner image.

```powershell
.\clients\windows\tests\Run-Tests.ps1 -PythonExe python.exe
.\clients\windows\Build.ps1 -PythonExe python.exe -Version 0.4.3
.\clients\windows\Build-Installer.ps1 -PythonExe python.exe -Version 0.4.3
```

The build produces `clients/windows/dist/GeoRoute-Windows-x64-0.4.3.zip`, `GeoRoute-Setup-0.4.3-x64.msi` and their SHA-256 files. Package verification rejects private user paths, account-specific NextDNS URLs, runtime state/logs/backups, and inconsistent runtime hashes.

`GeoRoute.cmd` opens the existing WPF GUI in the system Windows PowerShell process. It accepts only the fixed normal/tray/repair/smoke modes and never forwards arbitrary command text. The process-scoped ExecutionPolicy argument does not change machine execution policy or antivirus settings. `AppInstance.ps1` owns the mutex/event contract; a second launch activates the existing window, background startup does not unhide it, and exit releases ownership. Tray startup quotes the CMD path explicitly and migrates only exact legacy commands belonging to the same app directory. The UI thread retains per-monitor DPI awareness. CI smoke-tests the packaged entry point, and package validation rejects the removed custom EXE files. Experimental compiled launcher implementations remain in Git history, with their measured outcomes in the security experiments report.

The optional DNS bridge now runs directly as a LocalService-hosted Python process using Windows SCM APIs. `NextDNSBridge.exe` and its C# process wrapper are no longer built or shipped. The installer recognizes the exact legacy command for migration, waits for that process to exit, and changes the service command before starting the replacement. DNS settings still change only through the existing elevated setup action. `Test-BridgeService.ps1` creates a uniquely named temporary service only in a disposable GitHub Windows runner, on a test port, without changing adapter DNS. It checks startup, restart, startup failure cleanup and subsequent recovery.

`GeoAvailability.ps1` owns regional eligibility, profile requirements and provider-list replacement. `GeoHide.ps1` writes prepared profiles; `Profiles.ps1` is the existing elevated hosts apply/restore boundary. `Home.ps1` distinguishes off/checking/ready/unavailable using actual managed hosts plus current probe evidence. Ordinary hosts mode does not require wildcard NextDNS rewrite checks. The optional bridge retains its separate diagnostics.

Tests cover independent US/EU/RU replacement, provider removal and reappearance, mixed-route failures, stale observations, attachment HTTP failure, manual editing, hosts comparison, recovery and protocol boundaries. UI smoke tests do not change the network. Live results are specific to the tested machine/time; do not promote them to global provider availability.

`ProfileMigration.ps1` upgrades bundled profiles to shared GeoHide routes, backs up the old catalog/files, removes only the two built-in Gemini IDs and the exact retired attachments ID, preserves custom profiles and remaps preferences. It is idempotent and never applies hosts. `Save-GeoProfile` adds the exact `www.google.com` frontend only after its same-node probe succeeds, preventing an unsupported SNI route from breaking Google Search. Gemini failures are explicit warnings on a working shared ChatGPT route; they are not model-access success. Home compares the active marked hosts block with the saved profile before declaring it current. Test live GeoHide endpoints through the physical interface: TUN sniffing can override a curl `--resolve` destination.

Never commit `geohide-settings.json`, `geohide-monitor.json`, `geohide-history.json`, user profiles/credentials, logs or backups. Provider seed lists and generic hosts templates are public. Do not disable certificate validation or add credentials to releases.

## Installer

`Build-Installer.ps1` validates the portable ZIP and SHA-256 before extracting a fresh staging directory. `installer/generate_wix.py` generates declarative MSI source from that payload. Setup is per-user, creates shortcuts targeting system PowerShell, and uses Windows Installer for uninstall. Code components have stable GUIDs. Mutable catalog/routes/profile seeds are installed into `_service/defaults`; `ProfileDefaults.ps1` atomically copies only missing user files on GUI startup. MSI never owns user profiles, so update/uninstall preserves them and a clean reinstall after deleting data works. Native RemoveFolder rows remove empty directories only. Setup does not change hosts/DNS/proxy or install the optional service. Uninstall refuses to strand a managed hosts route and removes only the exact startup entry for this installed copy.

`Test-Installer.ps1` is restricted to disposable GitHub Windows runners. It tests exact payload hashes, a Cyrillic/space-containing path, the installed shortcut command with WPF smoke, the running-app mutex, data preservation across update/reinstall/uninstall, owned/unrelated startup values, and unchanged network configuration. `AppInstance.ps1` retains a shared session mutex so Setup can ask users to exit safely.

CI scans exact tested ZIP/MSI bytes plus selected source/runtime members and the fixed uninstall helper. Read each report: ZIP results alone do not describe the installer. No custom uninstaller EXE is distributed. Never rebuild after scanning. Explicit `[audit-client]` commit markers on trusted feature/develop/release pushes trigger scans; fork PRs cannot access the token.

Original cloud DNS configurator docs: [English](../DNS-CONFIGURER.md) / [Russian](../DNS-CONFIGURER.ru.md).

## Documentation and release verification

Run `python tools/check_docs.py` to check tracked Markdown targets, images and heading anchors. CI runs it with the ordinary repository tests. Update both language READMEs together.

The VirusTotal header badge is an explicitly dated snapshot for one MSI version and links to that file's full SHA-256 report. It is not a live status or a certification badge. When publishing a new installer, update the version, date, verdict and report URL together only after meaningful analysis results are available. Preserve coverage limitations in the security report. The ordinary Shields format follows examples in [kObsidian](https://github.com/bezata/kObsidian#readme) and [VirusTotal Action](https://github.com/cssnr/virustotal-action/discussions/27); see [Shields static badges](https://shields.io/badges/static-badge). The official [VT widget](https://docs.virustotal.com/reference/widgeturl) is an iframe integration, rather than a GitHub Markdown badge.

`verify-windows-release.yml` downloads the public MSI/ZIP without rebuilding them, checks GitHub digests, checksum sidecars and the tag's security report, then exercises the installer in a disposable Windows VM. It also tests the default per-user location, both shortcuts and Windows Installer registration. Screenshots are WPF renders from the installed release in a fresh verification profile; diagnostic previews do not run live network actions or prove model availability. Release tags and published bytes remain immutable when documentation is updated.
