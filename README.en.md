# GeoRoute

Windows desktop manager for ChatGPT and Gemini GeoHide routes and endpoint availability. [Русский](README.md).

**[Download for Windows](https://github.com/Georgy-hook/GeoRoute/releases/latest)**. Download the `GeoRoute-Windows-x64` ZIP asset, extract the whole folder, and open **GeoRoute.exe**. Python and Java are not required. Requirements: Windows 10/11 x64, Windows PowerShell 5.1 and .NET Framework 4.8.

**VirusTotal snapshot for 0.4.0 (2026-11-05): detections present.** ZIP and `GeoRoute.exe`: **2/71**; `NextDNSBridge.exe`: **3/71**; bundled Python: **0/71** (existing analysis dated 2026-11-02). These findings have not been confirmed as false positives. [Reports, coverage, dates and exact SHA-256 hashes](docs/security/virustotal-v0.4.0.md).

Wait for the initial checks, choose an available route under **Servers**, then use the single **Enable / Disable** control on the home page and confirm the Windows elevation request. The interface is currently Russian.

The manager refreshes provider lists for US/EU/RU hourly and probes endpoints every two minutes. Regional replacement is independent: an EU outage does not prevent updating US or RU profiles. Unavailable, retired and stale endpoints cannot unlock a managed profile. A mixed US+EU route requires both roles to pass. Healthy choices are retained; manual addresses survive provider refresh.

Monitoring has its own sidebar entry, overall and per-server loading indicators, and a single active scan. Gemini-only US/EU profiles are independent of ChatGPT; the combined route sends Gemini through EU. Google CAPTCHA redirects are shown as requiring user action, not as fully healthy model access or a transport outage. No account, Gmail or broad Google-domain routing is added.

Automatic selection updates saved profiles. Applying them to Windows requires an explicit connection action and elevation. The ordinary mode manages a marked section of `hosts`, not an all-traffic VPN. Closing the window keeps monitoring in the tray; exiting stops monitoring while applied hosts settings remain. Optional NextDNS Bridge and HTTP proxy features are not enabled automatically.

A green check proves the tested HTTPS transport/configuration only, not an authenticated ChatGPT conversation, a specific GIF download or computer-control session. Availability depends on the local network and GeoHide endpoints.

[Installation guide](docs/INSTALL.ru.md) · [Verification limits](clients/windows/VERIFICATION.md) · [Development](docs/DEVELOPMENT.md) · [Changelog](CHANGELOG.md).

Based on [noVibe/DnsConf](https://github.com/noVibe/DnsConf). The upstream cloud DNS tools remain available separately: [technical manual](DNS-CONFIGURER.md). No NextDNS account or API key is needed for the ordinary desktop hosts mode. GeoRoute is an independent client, not an official GeoHide/NextDNS product.

Custom profiles: use the **?** button beside **Add server** for the in-app guide, or see the [file format and import limits](README.md#как-добавить-собственный-профиль). Import accepts `.hosts` files up to 1 MiB with 1–512 unique, supported exact domains. Importing adds a local profile without changing the active system configuration; selecting and connecting is a separate action. Custom profiles do not participate in automatic GeoHide endpoint replacement.

Create a profile without a file: **Servers → Add server → By IP**, enter a public server IP, choose ChatGPT or Gemini and the country, then save. A name is optional. The client generates service-specific host mappings locally; saving does not enable the route or verify connectivity. File import remains available as a separate input mode.
