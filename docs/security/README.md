# VirusTotal — GeoRoute 0.4.2

**Обнаружений нет:** у точного MSI, ZIP и семи выбранных компонентов `malicious = 0`, `suspicious = 0`. Это результаты для указанных SHA-256, а не гарантия безопасности. У MSI 55 ответов `undetected`, у ZIP — 37; остальные ответы включают тайм-ауты, ошибки и неподдерживаемые форматы.

## Результаты

Время — московское. «Тайм-ауты» включают `confirmed-timeout`; число результатов в каждой строке — 71, включая неуспешные проверки.

| Файл | Malicious / suspicious | Undetected | Тайм-ауты | Ошибки | Unsupported | Дата анализа, МСК | Отчёт с SHA-256 |
|---|---:|---:|---:|---:|---:|---|---|
| **GeoRoute-Setup-0.4.2-x64.msi** | 0 / 0 | 55 | 2 | 2 | 12 | 06.11.2026 13:24:10 | [VirusTotal](https://www.virustotal.com/gui/file/8b7b473e9598a1a304eb4ec850b63ca566bdb12bf032271d96ee9b5dec18dba3/detection) |
| GeoRoute-Windows-x64-0.4.2.zip | 0 / 0 | 37 | 22 | 5 | 7 | 06.11.2026 13:24:02 | [VirusTotal](https://www.virustotal.com/gui/file/cc09af6b59d494eb1d65a7ce9400dcbd984e45b7a31c36a1e9e8839239add05c/detection) |
| GeoRoute.cmd | 0 / 0 | 57 | 0 | 1 | 13 | 05.11.2026 20:58:01 | [VirusTotal](https://www.virustotal.com/gui/file/7679c1919d66db8e0dfb5662fe94e44ff6ebd2317fade29729918c80810a2066/detection) |
| NextDNS-GUI.ps1 | 0 / 0 | 58 | 0 | 0 | 13 | 06.11.2026 13:24:03 | [VirusTotal](https://www.virustotal.com/gui/file/8c1c327ed087585ee0b28a6d019467c61d6f642aba974ee0242a04c5aa517a03/detection) |
| AppInstance.ps1 | 0 / 0 | 49 | 9 | 1 | 12 | 06.11.2026 13:16:55 | [VirusTotal](https://www.virustotal.com/gui/file/37ebc35f2daaf7181c8416216e4414529263f23fc4ccf37b2e1dff96309ca6b2/detection) |
| InstallerActions.ps1 | 0 / 0 | 48 | 9 | 1 | 13 | 06.11.2026 13:16:57 | [VirusTotal](https://www.virustotal.com/gui/file/a97e021c3a40cf2a98535640ac078f7a14f817e004bff060443ad2794698e98a/detection) |
| ProfileDefaults.ps1 | 0 / 0 | 40 | 17 | 2 | 12 | 06.11.2026 13:23:07 | [VirusTotal](https://www.virustotal.com/gui/file/fcb02d450fb2ec22868963e3b9bf24cebc132c06514bff72f51a11b16ed28453/detection) |
| bridge.py | 0 / 0 | 58 | 0 | 0 | 13 | 05.11.2026 20:58:03 | [VirusTotal](https://www.virustotal.com/gui/file/76daf366968e2158f4fe21e50e403716f87de5a419aa5c314b8b19b430e6918a/detection) |
| Python runtime / python.exe | 0 / 0 | 68 | 0 | 0 | 3 | 01.11.2026 01:59:16 | [VirusTotal](https://www.virustotal.com/gui/file/d718435b892db4ad5b547d12fec61be7baa7faf7a58d857ea58053be24c7a000/detection) |

Нулевые обнаружения не означают 71 успешную проверку. Другие DLL и ресурсы внутри пакетов отдельно не отправлялись. Неизменившиеся компоненты используют существующие отчёты с исходной датой анализа, включая Python от 31.10.2026 UTC.

## Проверить скачанный файл

MSI, 22 704 384 байта:

```text
8b7b473e9598a1a304eb4ec850b63ca566bdb12bf032271d96ee9b5dec18dba3
```

ZIP, 24 694 228 байт:

```text
cc09af6b59d494eb1d65a7ce9400dcbd984e45b7a31c36a1e9e8839239add05c
```

В релизе рядом лежат файлы `.sha256`. В PowerShell хеш показывает `Get-FileHash "путь к скачанному файлу" -Algorithm SHA256`.

## Происхождение и ограничения

- Публикуются точные файлы из [Windows build + VirusTotal, run 42202058892](https://github.com/Georgy-hook/GeoRoute/actions/runs/42202058892), исходный код пакета — `9d6ae1dce694a7d69d3f5f13de68bba89965a5de`. После проверки файлы не пересобирались и не перепаковывались.
- Проверены SHA-256 обоих artifacts, MSI/ZIP и всех семи выбранных членов ZIP. Персональные профили, журналы, токены и cookies в отправленные пакеты не входили.
- Для `ProfileDefaults.ps1` финальный lookup API вернул устаревшую карточку `0/0`. Использован завершённый анализ из [run 42201839234](https://github.com/Georgy-hook/GeoRoute/actions/runs/42201839234): SHA-256 совпадает побайтно с итоговым ZIP. В 17 тайм-аутах этого файла есть один `confirmed-timeout`. Сборщик отчёта исправлен: пустая карточка больше не считается завершённой проверкой; регрессионные тесты не делают сетевых запросов.
- Функциональные проверки в Windows VM охватывают ярлыки, WPF, путь с кириллицей, блокировку работающего приложения, реальное обновление между версиями, сохранение профилей, чистую переустановку и удаление. Проверено отсутствие изменений DNS, hosts и прокси. [Пределы проверок](../VERIFICATION.md).

## Предыдущие варианты

EXE-установщики на Inno Setup [6.7.1](https://www.virustotal.com/gui/file/505a367c1dd3fed0386585a38b43855fb6a003d594f68a5e7f1c4c2f5a48e47a/detection) и [7.1.1](https://www.virustotal.com/gui/file/2fbc963872fbc5079512f14eb5730e746cf255ddd6cdadca8a454634433382c6/detection) получили по три обнаружения и не вошли в релиз. Итоговый MSI использует штатную установку и удаление Windows; собственных EXE-обёрток GUI/Bridge в поставке нет. Конкретное внутреннее правило антивирусных моделей неизвестно.

Исторические отчёты 0.4.0/0.4.1 и эксперименты доступны в [архиве v0.4.1](https://github.com/Georgy-hook/GeoRoute/tree/v0.4.1/docs/security). Устаревшие подробные отчёты убраны из текущего дерева; Git-история и прежние результаты не переписывались.
