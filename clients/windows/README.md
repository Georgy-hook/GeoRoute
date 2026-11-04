# GeoRoute Windows

Пользовательская инструкция: [установка](../../docs/INSTALL.ru.md), [главная страница](../../README.md).

Portable ZIP содержит `GeoRoute.exe`, совместимый старый launcher `NextDNS.exe` и папку `_service`. Запускайте основной `GeoRoute.exe` после распаковки всей папки. Администратор нужен только для явных изменений системы; мониторинг работает без него.

Сборка и тесты: [DEVELOPMENT.md](../../docs/DEVELOPMENT.md). Источники регионов задаются в `geohide-servers.json`, локальные ручные адреса — в исключённом из Git `geohide-settings.json`. Обновление источника не стирает ручные узлы. Профили и статус каждого требуемого IP проверяются перед подключением. Отсутствие US не мешает обновлять RU/EU; отсутствие EU блокирует смешанный профиль, пока не появится замена.

Архив прежних инструкций Bridge: [legacy-windows-client.md](../../docs/legacy-windows-client.md). Ограничения проверки: [VERIFICATION.md](VERIFICATION.md).
