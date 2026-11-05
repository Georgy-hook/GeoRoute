# Verification — GeoRoute 0.4.1

Version 0.4.1 launches the same WPF GUI through GeoRoute.cmd and the system PowerShell host. The packaged entry is smoke-tested after copying into a clean staging folder. Mutex/event tests cover single-instance ownership, activation, background startup, repair isolation and release; startup migration tests leave the user's registry untouched.

An additional SCM test runs only in a disposable GitHub Windows runner. It creates a uniquely named temporary LocalService on a test port, checks startup, stop/restart, a startup bind failure, resource cleanup and subsequent recovery, then removes that service. It does not configure adapter DNS. This is not a reboot test on the user's computer. [Exact-file VirusTotal snapshot and coverage](../../docs/security/virustotal-v0.4.1.md).

Current automated checks additionally validate monitor duplicate-launch prevention, per-run isolation, final-result ingestion, startup/timeout/malformed-output recovery, per-row loading without synthetic history failures, Gemini-only availability independent of ChatGPT, exact-domain import validation, trusted redirects and CAPTCHA warnings.

Current automated checks validate regional replacement independently, mixed-profile rejection on failed EU, stale and removed endpoints, manual save/connect boundaries, hosts application state, off/checking/ready/unavailable home states, DNS protocol framing, recovery plans, WPF loading and portable package layout. They do not modify system hosts/DNS or close browsers.

Gemini checks use unauthenticated HTTPS requests to the page and API root. A Google CAPTCHA redirect is displayed as requiring user action; neither this redirect nor an API-root 404 proves a signed-in model response. No cookies, credentials or model messages are used by monitoring.

Live server checks are specific to the local network and timestamp. HTTP 404 at a file-host root confirms transport only. No release claim is made that a logged-in ChatGPT conversation, a specific GIF or computer-control session works on every network. A Windows service restart is not a reboot test. The UI distinguishes a saved profile from an applied configuration.

Legacy observations are retained below as historical evidence, not current release promises.

# Состояние проверки, 28.10.2026

Это публикация текущих наработок, включая известные ограничения.

## US HTTP-прокси, обновление около 17:35 МСК

- Предложенный пользователем `64.118.155.2:22222` принимает HTTP CONNECT без авторизации. SOCKS5 на этом порту не подтвердился.
- `https://chatgpt.com/cdn-cgi/trace` через прокси: HTTP 200, проверенный TLS 1.3, `loc=US`, `colo=SJC`. Узел WebRTC также ответил HTTPS 200; корни файлового хранилища и статики ответили HTTP 404 с проверенными сертификатами. Это не запрос конкретного файла.
- В Windows сохранён статический PAC для четырёх зон с поддоменами. Тесты выполняют настоящий PAC-код: 17 проверок включённых доменов, новых зон, посторонних сайтов и похожих имён. Также проверяются ввод адреса, кодирование PAC и отсутствие изменения Windows при тестах.
- Обычный профиль Chrome после запуска без proxy-флагов подтвердил `loc=US`. У настольного `ChatGPT.exe` наблюдались девять установленных TCP-соединений с этим прокси; пользователь сообщил, что настольное приложение стало работать нормально.
- Установленный GUI отвечает и самостоятельно подтвердил US. Добавлены проверка, включение, замена адреса, отключение и пункт в трее. Настройка не зависит от работы менеджера; это подтверждено устройством конфигурации, а не тестом перезагрузки Windows.
- После переключения на новый прокси не выполнена отдельная автоматическая проверка декодирования GIF и фактического ввода в компьютере Dot. Не выполнена полная перезагрузка Windows. Старые проверки ниже относятся к прежнему маршруту и не заменяют эти проверки нового подключения.

## Предыдущий DNS-маршрут

**Обновление 28.10.2026, около 15:55 МСК:** все четыре US-адреса GeoHide недоступны по TCP/443 из проверенной сети. Рабочей бесплатной замены с подтверждённым US среди проверенных операторов не найдено; доступные альтернативы показывают другие страны. Текущие US-пресеты нельзя считать рабочими. [Адреса, методика и результаты](../../docs/us-hosts-check-2026-10-28.md).

## Подтверждено на Windows

- NextDNS Bridge установлен как LocalService с автоматическим запуском и восстановлением SCM. Контрольный перезапуск прошёл.
- Windows получает новые имена из четырёх зон через Bridge; проверены UDP/TCP на IPv4/IPv6 и обычные интернет-домены.
- Старый клиент NextDNS остановлен и отключён. Позднее драйверы NextDNSEngine и WinDivert штатно остановлены; это не изменило недоступность US TCP/443.
- GIF в авторизованной сессии Dot загрузилась и скачалась. Один проверенный файл содержит 17 кадров и не содержит параметра повторения: он играет один раз. Это не проверка бесконечного цикла анимации.
- Трансляция компьютера Dot 1364×1024 подключалась. Получено управление; щелчок открыл меню удалённого браузера.
- 11 проверок протокола Bridge, 20 проверок диагностики/восстановления и 16 проверок плана hosts прошли. Тесты не требуют администратора и не меняют сеть.

## Известные ограничения

- Длительная сессия компьютера Dot обрывалась. Запросы статуса чередовали HTTP 200 JSON и HTTP 403 HTML с `cf-mitigated: challenge`. Обновление страницы временно возвращало управление. DNS в это время продолжал отвечать. Устранение тайм-аутов DNS само по себе не устраняет проверку Cloudflare.
- EU-сервер основного сайта в тесте перенаправил `/dots/home` на обычный ChatGPT. Поэтому исходный US-маршрут возвращён, EU используется для хранилищ.
- Остальные US-серверы из исходного списка в проверенной сети не установили TCP-соединение. Они не применялись.
- Полная перезагрузка Windows после установки Bridge ещё не проверена. Наличие статуса Running и успешный Restart-Service не заменяют эту проверку.

## Критерии завершения проверки загрузки

1. Новый `bootAt`, автозапуск Bridge и отсутствие загрузки старого драйвера.
2. `boot-verified.json`: `status=ok`, `afterReboot=true`, время загрузки совпадает с текущей системой.
3. Загрузка нового вложения в авторизованной сессии Dot.
4. Длительная трансляция и фактический ввод мышью/клавиатурой без повторного обрыва.

Источники: [GeoHide US](https://github.com/Internet-Helper/GeoHideDNS/blob/main/hosts/us/hosts), [признак Cloudflare Challenge](https://developers.cloudflare.com/cloudflare-challenges/challenge-types/challenge-pages/detect-response/), [компьютер Dot — официальная документация OpenAI](https://learn.chatgpt.com/docs/dots/computers-and-apps).
