# Changelog

## 0.3.0 — 2026-11-05

- Add Monitoring to the sidebar and move the manual-address editor below results in a collapsed section.
- Show global progress and per-server queued/checking indicators. Disable scan, refresh and add-server actions during an active scan.
- Isolate reports by run ID; always unlock controls on completion, start failure, malformed output or timeout. Pending probes do not create failed history samples.
- Add Gemini routing to the US+EU profile, plus independent Gemini US/EU profiles with automatic endpoint replacement.
- Probe Gemini page and API separately from ChatGPT. Expose Google CAPTCHA as an actionable warning, preserve normal HTTPS certificate validation and block real failed/stale routes.
- Keep routing limited to the supported Gemini hosts; Google accounts, Gmail and broad Google zones are excluded.

## 0.2.0 — 2026-11-04

- Rename the desktop client and project to GeoRoute; keep legacy launcher compatibility.
- Single enable/disable home control; separate Servers, Help, Journal and Settings screens.
- Independent US/EU/RU source refresh and profile replacement. A failed EU can be replaced without changing healthy US.
- Reject managed routes with missing, failed, stale or retired required nodes; explain the failing role on the profile card.
- Regional monitoring with flags, actual egress country, latency, filters and the last 24 real checks.
- Explicit manual/automatic editor and save-and-connect action. Background selection updates prepared profiles only.
- Fix permanent wildcard DNS warnings in hosts-only mode; optional NextDNS Bridge keeps its own checks.
- Portable Windows ZIP, beginner installation guide, documented limits and reproducible build checks.

Previous preview: Windows GUI + NextDNS Bridge (2026-10-28). Original cloud DNS tools are retained.
