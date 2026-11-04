# Архив Windows-клиента до GeoRoute 0.2.0

Историческая документация предварительной версии. Текущая установка: [GeoRoute](INSTALL.ru.md).

# NextDNS для Windows: GUI и Bridge

Менеджер с профилями US/EU, иконками Image Gen, анимациями, треем, журналом, очисткой DNS и окном восстановления. Служба NextDNS Bridge передаёт системные DNS-запросы в уже настроенный профиль NextDNS и работает без открытого GUI.

## US-прокси для настольного ChatGPT / Dot

Откройте **«US-прокси…»** слева или в меню трея. Введите анонимный HTTP CONNECT-прокси в формате IPv4:порт и нажмите **«Проверить и включить»**. Текущий предложенный пользователем адрес — `64.118.155.2:22222`; 28.10.2026 ChatGPT подтвердил через него выход US. Доступность бесплатного адреса нужно проверять повторно; его можно заменить в этом же окне.

Маршрутизируются только четыре зоны ChatGPT/OpenAI и их поддомены, включая будущие хранилища вложений. Статический PAC сохраняется в пользовательской настройке Windows; он поддерживается Chromium/Electron и проверен с настольным ChatGPT и Chrome. Фоновый HTTP-сервер, отдельный VPN-клиент и открытый менеджер не требуются. Проверка сертификатов HTTPS сохраняется. Кнопка «Отключить» возвращает прежнюю настройку, если её не меняло другое приложение. Существующий сторонний PAC или ручной прокси не перезаписываются.

Для этого режима профиль NextDNS и установка Bridge не нужны. Параметры Bridge и hosts ниже относятся к отдельному DNS-режиму. Подробности реализации PAC: [официальный код Chromium](https://github.com/chromium/chromium/blob/main/net/proxy_resolution/pac_file_fetcher_impl.cc).

## Готовая сборка

Скачайте ZIP из [предварительного релиза](https://github.com/Georgy-hook/DnsConf/releases), распакуйте всю папку и запустите `NextDNS.exe`. Файл EXE должен оставаться рядом с папкой `_service`.

В «GIF / вложения не работают…» доступны установка Bridge, перезапуск службы и возврат прежних DNS. Изменения системы сначала показываются в GUI и требуют подтверждения администратора Windows. Закрытие главного окна оставляет менеджер в трее; «Выйти из менеджера» завершает GUI. Установленная служба продолжает работать отдельно.

**Состояние на 28.10.2026 — предварительная версия.** Установка и перезапуск службы, новые DNS-имена, загрузка GIF и щелчок в компьютере Dot проверены. Длительное соединение Dot обрывалось с HTTP 403 Cloudflare. Полная перезагрузка Windows после установки ещё не проверена. Успешный DNS-тест не считается подтверждением работы GIF или управления компьютером. [Подробности проверки](VERIFICATION.md).

## Предварительная настройка

Для DNS Bridge нужны Windows x64, Windows PowerShell 5.1 и собственный профиль NextDNS, уже указанный в DNS-over-HTTPS Windows. Инсталлятор извлекает ID из текущих DoH-настроек. API-ключ NextDNS ему не требуется.

Сначала настройте облачные перенаправления через DnsConf. `connection-routes.json` содержит ожидаемые ответы для диагностики, но не создаёт правила в NextDNS. Рабочий пример для `PINNED_REDIRECTS`:

```text
oaiusercontent.com=45.13.237.213,chatgpt.com=192.255.159.241,openai.com=192.255.159.241,oaistatic.com=192.255.159.241
```

Это адреса стороннего оператора GeoHide, проверенные на указанную дату. Их доступность и доступность Dot зависят от сервера и сети. EU-профиль основного сайта в проверке перенаправил Dot на обычный ChatGPT; для Dot оставлен вариант US + EU для вложений. Профили можно импортировать из `.hosts` и обновлять отдельно.

## Сборка из чистого checkout

Для сборки нужен установленный CPython 3.14 x64 с полной стандартной библиотекой. Проверено с Python 3.14.7. Его runtime и лицензия копируются в ZIP локально; скачивания во время сборки нет.

Для тестов PAC-маршрутизации нужен `node.exe` в PATH; для запуска готового менеджера и сборки архива Node.js не требуется.

Из Windows PowerShell 5.1:

```powershell
.\clients\windows\tests\Run-Tests.ps1 -PythonExe python.exe
.\clients\windows\Build.ps1 -PythonExe python.exe
```

Можно передать полный путь к собственному `python.exe`. Результат: `clients/windows/dist/NextDNS-Windows-2026.10.28-preview.zip` и файл SHA-256 рядом. Сборка не устанавливает службу, не меняет DNS/hosts и не запускает GUI. Архив собирается по `package-files.json`, а Python runtime — по сгенерированному манифесту хешей. Старые ZIP и локальные папки разработчика не требуются.

## Устройство

| Файлы | Назначение |
|---|---|
| `_service/bridge/bridge.py` | DoH, TLS, локальные UDP/TCP DNS, статус и проверка загрузки Windows |
| `_service/bridge/NextDNSBridge.cs` | Обёртка Windows Service; запуск изолированного Python и обработка остановки |
| `_service/NetworkSetup.ps1` | Установка, защищённая резервная копия сети, перезапуск, возврат настроек |
| `_service/Profiles.ps1` | Импорт и применение hosts-профилей с резервной копией и защитой от одновременных изменений |
| `_service/Connection*.ps1`, `Health.ps1` | DNS- и HTTP/TLS-диагностика с ограничением времени |
| `_service/Repair*.ps1`, `BrowserRecovery.ps1` | План восстановления и обычный перезапуск Chrome после подтверждения сохранения работы |
| `_service/NextDNS-GUI.ps1`, `*.xaml`, `Tray.ps1` | WPF, переходы, журнал и трей |
| `_service/assets/`, `design/` | Иконки и изображения для приложения; исходные PNG Image Gen и промпты для дальнейшей доработки |

Bridge слушает только `127.0.0.1` и `::1`, порт 53, и использует два узла того же NextDNS. TLS 1.3, проверка имени и сертификата обязательны. ClientHello делится на два корректных TLS records с сохранением байтов handshake. Открытого внешнего DNS и переключения на другого провайдера нет.

Служба работает как LocalService. Код находится в Program Files; статус — в `%ProgramData%\NextDNSBridge`. Резервная копия сети доступна только Administrators/System. Старый клиент и автозапуск его драйвера отключаются; драйвер принудительно не выгружается. SCM настроен на восстановление после сбоя. Эти настройки проверяются отдельным тестом реальной загрузки Windows.

Личный ID NextDNS, SID пользователя, журналы, сетевые резервные копии и состояние GUI в Git и сборку не включаются. `boot-verified.json` создаётся на самом компьютере только после успешного DNS-теста вскоре после старта Windows и сверяется с текущим `bootAt`.

Сетевые проверки с настоящими DNS/службой и проверки вложений в авторизованном Dot выполняются отдельно от тестов CI. Тесты CI не обращаются к пользовательскому NextDNS и не закрывают браузер.


### GeoHide monitoring and changing endpoints (2026-11-02)

The Monitoring tab checks RU/US/EU HTTPS endpoints directly over the physical IPv4 interface, independently of the system proxy and Happ TUN. It shows certificate-validated ChatGPT trace responses, observed exit country, attachment-host TLS status, latency, flags and the last 24 real observations. HTTP 404 at the attachment root confirms transport only, not a downloaded GIF. Missing/failed probes are never green. Monitoring runs every two minutes while the manager is running; provider lists refresh hourly from the regional hosts files in Internet-Helper/GeoHideDNS. Source fetch errors preserve the previous list. Manual addresses are stored separately and survive refresh.

Automatic selection retains a healthy US/EU pair and updates the prepared hosts profiles and expected-route configuration when a replacement is available. If either region has no verified candidate, the previous pair is retained. System hosts and active DNS are changed only by the existing Apply action with Windows elevation. This update does not enable NextDNS or change Happ. Existing imported combined profiles retain their IDs. Manual mode and US/EU address fields are available on the same tab. Runtime settings, history and probe results are local and excluded from source control.


### Connecting and manual address selection

In **Monitoring**, the connection card is above the server table. The visible status distinguishes unsaved edits, a saved profile that is not applied in Windows, and a profile whose entries match the current managed hosts block. This status confirms configuration only, not a successful chat or file download.

- **Automatically**: the manager selects addresses for the saved profile. Click **Connect selected addresses** and approve Windows to apply them. Background selection never silently switches the active Windows connection.
- **Manually**: select or type the US IP for ChatGPT and the EU IP for attachments, then click **Save and connect** and approve Windows. No separate save step is needed. **Save without connecting** retains a choice for later.
- **Add another server to monitoring** only adds a probe target. It does not connect that address.
