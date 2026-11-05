# VirusTotal — GeoRoute 0.4.0

**В отчётах есть срабатывания.** Архив и основной EXE получили 2 отметки `malicious` из 71 движка; служба Bridge — 3 из 71. Срабатывания не подтверждены как ложные. Для Python в приведённом отчёте обнаружений нет.

Проверены точные файлы [публичного релиза 0.4.0](https://github.com/Georgy-hook/GeoRoute/releases/tag/v0.4.0). SHA-256 архива сверён с метаданными GitHub и локальной проверенной копией. Файлы не пересобирались и не запускались во время подготовки проверки; стандартная отправка в VirusTotal разрешает анализ и публикацию в его сообществе.

## Результаты

Числитель — категория `malicious`; знаменатель — `coverage.engines` из ответа VirusTotal. Часть движков сообщает неподдерживаемый тип или тайм-аут. Полная разбивка сохранена в [JSON](virustotal-v0.4.0.json). Категория `suspicious` равна 0 у всех четырёх файлов.

| Файл | Malicious / всего движков | Дата анализа, МСК | VirusTotal |
|---|---:|---|---|
| `GeoRoute-Windows-x64-0.4.0.zip` | **2 / 71** | 05.11.2026 18:08:04 | [Отчёт](https://www.virustotal.com/gui/file/9f8a8e8742aebe8d164ba56d8f58d6c401d347fbfeb5d16e63f5fd9730611d3d/detection) |
| `GeoRoute.exe` | **2 / 71** | 05.11.2026 18:08:05 | [Отчёт](https://www.virustotal.com/gui/file/9197f88dfd53c11716d1d3c74923bf132a7ddaf1712d42bc5f253d139f9bce10/detection) |
| `_service/bridge/NextDNSBridge.exe` | **3 / 71** | 05.11.2026 18:08:07 | [Отчёт](https://www.virustotal.com/gui/file/bd8091d98f3ffc2cc7b81079b8464ce2d826c5183c64a3bf3662e59c8d9cbac0/detection) |
| `_service/bridge/python/python.exe` | **0 / 71** | 02.11.2026 13:02:52 | [Отчёт](https://www.virustotal.com/gui/file/4942b86a6597e5aee0128daa00050ed79bc21f6e709a78eb19cbfeb0c2f39ac9/detection) |

Python уже имел отчёт от 02.11.2026; его существующий результат получен по совпадающему SHA-256. Остальные три файла отправлены на новый анализ 05.11.2026. Дата получения снимка: 2026-11-05T15:09:46.426456+00:00.

## Метки обнаружений

- **GeoRoute-Windows-x64-0.4.0.zip**: `W32.Malware.B4FA2B78`, `malicious (moderate confidence)`.
- **GeoRoute.exe**: `W32.Malware.B4FA2B78`, `Malicious`.
- **_service/bridge/NextDNSBridge.exe**: `malicious (moderate confidence)`, `ti!BD8091D98F3F`, `Malicious`.
- **_service/bridge/python/python.exe**: обнаружений в отчёте нет.

Ответы поиска по SHA-256 в этой процедуре содержат сокращённую сводку. Сохранённые ответы завершённого анализа (`0-analysis.json`, `1-analysis.json`, `2-analysis.json` в артефакте Actions) дополнительно содержат результаты отдельных движков:

| Файл | Движок | Метка |
|---|---|---|
| ZIP | Bkav | `W32.Malware.B4FA2B78` |
| ZIP | Elastic | `malicious (moderate confidence)` |
| GeoRoute.exe | Bkav | `W32.Malware.B4FA2B78` |
| GeoRoute.exe | APEX | `Malicious` |
| NextDNSBridge.exe | Elastic | `malicious (moderate confidence)` |
| NextDNSBridge.exe | McAfeeD | `ti!BD8091D98F3F` |
| NextDNSBridge.exe | APEX | `Malicious` |

Небольшое число срабатываний требует разбора; оснований автоматически объявлять их ложными нет. Даже отсутствие обнаружений не даёт гарантии безопасности. [Проверенные изменения и повторные анализы](virustotal-experiments-2026-11-05.md).

[Данные проверки исходных EXE](virustotal-cause-evidence-v0.4.0.json): совпадения CRC32/SHA-256 в метках Bkav/McAfeeD идентифицируют файлы; конкретные правила срабатывания неизвестны.

## SHA-256 проверенных файлов

**GeoRoute-Windows-x64-0.4.0.zip**

```text
9f8a8e8742aebe8d164ba56d8f58d6c401d347fbfeb5d16e63f5fd9730611d3d
```

**GeoRoute.exe**

```text
9197f88dfd53c11716d1d3c74923bf132a7ddaf1712d42bc5f253d139f9bce10
```

**_service/bridge/NextDNSBridge.exe**

```text
bd8091d98f3ffc2cc7b81079b8464ce2d826c5183c64a3bf3662e59c8d9cbac0
```

**_service/bridge/python/python.exe**

```text
4942b86a6597e5aee0128daa00050ed79bc21f6e709a78eb19cbfeb0c2f39ac9
```

## Охват и воспроизводимость

- Архив проверен целиком. `GeoRoute.exe`, `NextDNSBridge.exe` и встроенный `python.exe` дополнительно проверены отдельно.
- Остальные скрипты, DLL и ресурсы из ZIP не получили отдельных отчётов в этой процедуре. Пользовательские профили, журналы, cookies и ключи не загружались.
- Публичные отчёты привязаны к указанным SHA-256. Другая версия или локальная пересборка имеют отдельный хеш и требуют своей проверки. Результаты не распространяются на весь компьютер или на серверы GeoHide.
- [Запуск проверки GitHub Actions](https://github.com/Georgy-hook/GeoRoute/actions/runs/42051782089) содержит исходные ответы и квитанции в артефакте `virustotal-release-audit`. Статус выполнения workflow отражает завершение сбора отчётов. Детекты перечислены в таблице выше.
- [Workflow](../../.github/workflows/virustotal.yml) получает существующий публичный релиз, проверяет digest и использует официальный `https://ai.virustotal.com`. Повторные запуски используют сохранённый `VTAI_AGENT_TOKEN` в GitHub Secrets; секрет не включается в приложение и публичные отчёты.
- При неопределённом исходе отправки процедура читает квитанцию по тому же SHA-256; автоматическая повторная загрузка не выполняется.

[Справка VirusTotal о результатах и ограничениях](https://docs.virustotal.com/docs/vtai-overview).
