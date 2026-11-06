# Changelog

## 0.4.3 — в разработке

- Общие профили GeoHide для ChatGPT, Gemini и вложений; удалены отдельные встроенные Gemini US/EU и устаревшая карточка «Вложения 25.10».
- Перенос старого каталога с резервной копией, сохранением пользовательских профилей, выбранного региона и ручных серверов.
- Добавление по IP создаёт один профиль без выбора сервиса.
- Проверка www.google.com через тот же GeoHide-узел; неподдерживаемое перенаправление Google не попадает в управляемый профиль. Ограничение Gemini отображается отдельно от рабочего ChatGPT.
- Восстановление NextDNS Bridge проверяет DNS независимо от правил GeoHide; диагностика применённого hosts сохраняется при работающем Bridge.
- Штатный общий маршрут Gemini и проверки Google: проверка HTTP/2 с cookie в памяти, сохранение www.google.com на том же IP, выбор проверенного резерва по задержке.

## 0.4.2

- Обычный русскоязычный MSI-установщик с ярлыками на рабочем столе и в «Пуске» и удалением через настройки Windows.
- Обновление сохраняет профили, адреса, настройки и журналы; установщик просит закрыть работающий GUI.
- Установка и удаление не меняют сеть. Удаление останавливается, если управляемый маршрут ещё включён.
- Интеграционный тест установки, ярлыков, обновления и удаления в отдельной Windows VM.
- Актуальные инструкции для пользователей; удалены устаревшие снимки состояния сети и одноразовые инструменты экспериментов. Исторические результаты доступны по тегам.

## 0.4.1 — 2026-11-05

- Run the same WPF GUI through `GeoRoute.cmd` and the system PowerShell host, removing custom GUI and DNS-service executable wrappers from the distribution.
- Preserve single-instance activation, quiet tray startup, repair mode and per-monitor DPI; migrate exact legacy startup commands from the same app directory.
- Run the optional DNS bridge directly as LocalService in the bundled isolated Python process using Windows SCM APIs, with controlled startup/stop status and cancellation of active connections.
- Preserve TLS certificate validation and the existing elevated DNS/hosts boundary. No automatic network activation is introduced.
- Add real SCM integration checks in a disposable Windows runner, single-instance/startup migration checks and a smoke test of the packaged entry point.
- Record intermediate VirusTotal experiments separately; publish exact-file results and coverage with the release.

## 0.4.0 — 2026-11-05

- Use four new Image Gen transparent navigation icons for Connect, Monitoring, Journal and Settings, keeping full-resolution lossless PNG sources.
- Redesign Monitoring with a generated server-orbit spot image, compact region cards and quieter metadata. Keep live progress and per-server loading behavior.
- Group Settings into rounded cards with keyboard-accessible toggles; add an illustrated Journal header and rounded profile-form fields.
- Add a short page fade that respects reduced-motion preferences and expand WPF previews to cover the new screens.
- Preserve original generated artwork and design prompts in the repository; keep the generated UI mockup separate from actual runtime controls.

## 0.3.2 — 2026-11-05

- Create a custom profile directly from a public IP, country and service (ChatGPT or Gemini); no user-authored hosts file required.
- Generate service-specific mappings and an optional automatic name through the existing transactional profile save path, without changing the active connection.
- Keep file import in a separate input mode, show validation errors beside Save and update the in-app/README guides.
- Verify real GUI-worker persistence for both services, rejected addresses, IPv6 and the existing file-import path.

## 0.3.1 — 2026-11-05

- Add an accessible **?** help button beside profile import and inside the import dialog, with an offline, scrollable, plain-language guide.
- Document the profile file format, supported domains, import limits and custom-profile update behavior in README.
- Align the file picker and size check with the backend: `.hosts` only, up to 1 MiB.

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
