# Sources and components

- GeoRoute develops the Windows client in a fork of [noVibe/DnsConf](https://github.com/noVibe/DnsConf); original cloud DNS tools and their technical manuals remain in this repository.
- Provider endpoints are discovered from [Internet-Helper/GeoHideDNS](https://github.com/Internet-Helper/GeoHideDNS), using the ChatGPT mappings in the separate RU/US/EU hosts lists. GeoRoute is not an official GeoHide or NextDNS client.
- Optional bridge runtime: CPython 3.14. The distribution includes its `LICENSE.txt` and a verified runtime hash manifest. The build copies a local runtime and excludes site-packages.
- The shared Gemini/Google HTTP/2 probe includes [h2 4.4.1](https://github.com/python-hyper/h2/), [hpack 4.2.0](https://github.com/python-hyper/hpack/) and [hyperframe 6.1.0](https://github.com/python-hyper/hyperframe/) under the MIT license. Their original wheel metadata and licenses are retained in `_service/vendor/`; pinned SHA-256 values are checked before loading. The client does not download these dependencies at startup.
- Windows PowerShell, WPF and .NET Framework are system dependencies, not separate repackaged distributions.
- App illustrations/icons in the Windows client were created for this project. RU/DE flag images are national-flag artwork obtained from flagcdn.com; US/EU assets are retained from the earlier client.

Repository names and service marks identify their respective projects. No affiliation is implied.
