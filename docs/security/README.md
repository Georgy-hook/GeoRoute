# VirusTotal — GeoRoute 0.4.3

**Обнаружений нет:** у точного MSI, ZIP и восьми выбранных компонентов `malicious = 0`, `suspicious = 0`. Это снимок результатов для указанных SHA-256, а не гарантия безопасности. У MSI 58 ответов `undetected`, один тайм-аут и 12 неподдерживаемых проверок.

## Результаты

Время — московское. Тайм-ауты включают `confirmed-timeout`; неподдерживаемый формат и ошибка не считаются успешной проверкой.

| Файл | Malicious / suspicious | Undetected | Тайм-ауты | Ошибки | Unsupported | Дата анализа, МСК | Отчёт с SHA-256 |
|---|---:|---:|---:|---:|---:|---|---|
| GeoRoute-Setup-0.4.3-x64.msi | 0 / 0 | 58 | 1 | 0 | 12 | 06.11.2026 20:30:53 | [VirusTotal](https://www.virustotal.com/gui/file/0134f84ebf9c1b7ca51cb9bb408d199db913c93559fa6885f938c308a15e4c9a/detection) |
| GeoRoute-Windows-x64-0.4.3.zip | 0 / 0 | 53 | 11 | 0 | 7 | 06.11.2026 20:30:43 | [VirusTotal](https://www.virustotal.com/gui/file/3e88a45037890bf8a61f0239e7d2d39d7899d4e2945e86c5bcfa0a97246d97e5/detection) |
| GeoRoute.cmd | 0 / 0 | 57 | 0 | 1 | 13 | 05.11.2026 20:58:01 | [VirusTotal](https://www.virustotal.com/gui/file/7679c1919d66db8e0dfb5662fe94e44ff6ebd2317fade29729918c80810a2066/detection) |
| NextDNS-GUI.ps1 | 0 / 0 | 56 | 2 | 1 | 12 | 06.11.2026 20:21:30 | [VirusTotal](https://www.virustotal.com/gui/file/b06750ba744af3e022064ed84354d42f1abdfe94efda7c0f2242a15424dfe9e7/detection) |
| AppInstance.ps1 | 0 / 0 | 49 | 9 | 1 | 12 | 06.11.2026 13:16:55 | [VirusTotal](https://www.virustotal.com/gui/file/37ebc35f2daaf7181c8416216e4414529263f23fc4ccf37b2e1dff96309ca6b2/detection) |
| InstallerActions.ps1 | 0 / 0 | 48 | 9 | 1 | 13 | 06.11.2026 13:16:57 | [VirusTotal](https://www.virustotal.com/gui/file/a97e021c3a40cf2a98535640ac078f7a14f817e004bff060443ad2794698e98a/detection) |
| ProfileDefaults.ps1 | 0 / 0 | 58 | 0 | 0 | 13 | 06.11.2026 20:21:33 | [VirusTotal](https://www.virustotal.com/gui/file/13dc45eff40cce7ee9a386da35db2ddbbdf9539974f5e84e164e76ec677e93da/detection) |
| gemini_probe.py | 0 / 0 | 58 | 0 | 0 | 13 | 06.11.2026 20:21:35 | [VirusTotal](https://www.virustotal.com/gui/file/a690111dcf76b8e449cc1c0113d907b4b9e889aaba676425198c5dd8f4489498/detection) |
| bridge/bridge.py | 0 / 0 | 58 | 0 | 0 | 13 | 05.11.2026 20:58:03 | [VirusTotal](https://www.virustotal.com/gui/file/76daf366968e2158f4fe21e50e403716f87de5a419aa5c314b8b19b430e6918a/detection) |
| bridge/python/python.exe | 0 / 0 | 68 | 0 | 0 | 3 | 01.11.2026 01:59:16 | [VirusTotal](https://www.virustotal.com/gui/file/d718435b892db4ad5b547d12fec61be7baa7faf7a58d857ea58053be24c7a000/detection) |

## Проверить скачанный файл

В релизе рядом с MSI и ZIP лежат файлы `.sha256`. В PowerShell хеш показывает `Get-FileHash "путь к скачанному файлу" -Algorithm SHA256`.

**GeoRoute-Setup-0.4.3-x64.msi**  22 819 612 байт:

```text
0134f84ebf9c1b7ca51cb9bb408d199db913c93559fa6885f938c308a15e4c9a
```

**GeoRoute-Windows-x64-0.4.3.zip**  24 806 701 байт:

```text
3e88a45037890bf8a61f0239e7d2d39d7899d4e2945e86c5bcfa0a97246d97e5
```

## Происхождение и ограничения

- Публикуются точные файлы из [Windows build + VirusTotal, run 42261969010](https://github.com/Georgy-hook/GeoRoute/actions/runs/42261969010), исходный код пакета — `25fcea6aa2f8ee818ce0e0a00470779bc644a9a6`. После анализа файлы не пересобирались и не перепаковывались. Последующие изменения релизной ветки касаются документации.
- Сверены SHA-256 MSI, ZIP и всех восьми выбранных членов ZIP с отчётом. Персональные профили, журналы, токены и cookies в отправленные пакеты не входили.
- Неизменившиеся компоненты используют существующие отчёты с исходной датой анализа. Ноль обнаружений не означает, что все движки поддерживают формат или что все файлы внутри архива проверены отдельно. Остальные DLL, ресурсы и wheel-файлы отдельно не отправлялись.
- Windows CI проверил установку, обновление, сохранение профилей, запуск GUI и удаление этих пакетов. [Пределы функциональных проверок](../VERIFICATION.md).
- MSI использует штатный Windows Installer. Собственных EXE-обёрток GUI/Bridge в поставке нет; Python включён с лицензией и проверкой целостности. Установщик не подписан сертификатом издателя.

## Предыдущие версии

[Отчёт 0.4.2](https://github.com/Georgy-hook/GeoRoute/blob/v0.4.2/docs/security/README.md) и [архив 0.4.1](https://github.com/Georgy-hook/GeoRoute/tree/v0.4.1/docs/security) сохраняют прежние хеши, результаты и эксперименты. Результаты одной версии не распространяются на другой файл.
