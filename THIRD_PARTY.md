# Sources and components

- GeoRoute develops the Windows client in a fork of [noVibe/DnsConf](https://github.com/noVibe/DnsConf); original cloud DNS tools and their technical manuals remain in this repository.
- Provider endpoints are discovered from [Internet-Helper/GeoHideDNS](https://github.com/Internet-Helper/GeoHideDNS), using the ChatGPT mappings in the separate RU/US/EU hosts lists. GeoRoute is not an official GeoHide or NextDNS client.
- Optional bridge runtime: CPython 3.14. The distribution includes its `LICENSE.txt` and a verified runtime hash manifest. The build copies a local runtime and excludes site-packages.
- Windows PowerShell, WPF and .NET Framework are system dependencies, not separate repackaged distributions.
- App illustrations/icons in the Windows client were created for this project. RU/DE flag images are national-flag artwork obtained from flagcdn.com; US/EU assets are retained from the earlier client.

Repository names and service marks identify their respective projects. No affiliation is implied.
