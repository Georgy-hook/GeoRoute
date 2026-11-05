# VirusTotal — GeoRoute 0.4.1

**Обнаружений нет:** у архива и пяти отдельно проверенных компонентов `malicious = 0`, `suspicious = 0`. Это снимок результатов для точных SHA-256, а не сертификат безопасности. Тайм-ауты, ошибки и неподдерживаемые форматы перечислены ниже.

Релиз сохраняет WPF GUI и запускается через **GeoRoute.cmd**. Собственные `GeoRoute.exe` и `NextDNSBridge.exe` больше не поставляются. GUI использует системный Windows PowerShell, необязательная DNS-служба работает прямо в изолированном Python под LocalService.

## Результаты

| Файл | Malicious / результатов | Undetected | Timeout | Failure | Unsupported | Анализ, МСК | Отчёт |
|---|---:|---:|---:|---:|---:|---|---|
| `GeoRoute-Windows-x64-0.4.1.zip` | 0/71 | 61 | 2 | 1 | 7 | 05.11.2026 20:57:59 | [VirusTotal](https://www.virustotal.com/gui/file/538bfd94aaf31136a298f74ac531b0c16c1878138acf80f2c1ea134e98b8fbde/detection) |
| `GeoRoute.cmd` | 0/71 | 57 | 0 | 1 | 13 | 05.11.2026 20:58:01 | [VirusTotal](https://www.virustotal.com/gui/file/7679c1919d66db8e0dfb5662fe94e44ff6ebd2317fade29729918c80810a2066/detection) |
| `_service/NextDNS-GUI.ps1` | 0/71 | 58 | 0 | 0 | 13 | 05.11.2026 20:48:25 | [VirusTotal](https://www.virustotal.com/gui/file/a9c4800ddfabef50dc768d1a804513a62fd86fd5c8d09f5de2fc27a9eabae911/detection) |
| `_service/AppInstance.ps1` | 0/71 | 58 | 0 | 0 | 13 | 05.11.2026 20:48:27 | [VirusTotal](https://www.virustotal.com/gui/file/8c4a0f723983c4ba07ca32e7207ef121e59d762a8e21f3384199a06efb0f26b6/detection) |
| `_service/bridge/bridge.py` | 0/71 | 58 | 0 | 0 | 13 | 05.11.2026 20:58:03 | [VirusTotal](https://www.virustotal.com/gui/file/76daf366968e2158f4fe21e50e403716f87de5a419aa5c314b8b19b430e6918a/detection) |
| `_service/bridge/python/python.exe` | 0/71 | 68 | 0 | 0 | 3 | 01.11.2026 01:59:16 | [VirusTotal](https://www.virustotal.com/gui/file/d718435b892db4ad5b547d12fec61be7baa7faf7a58d857ea58053be24c7a000/detection) |

Знаменатель — число результатов движков, включая неподдерживаемые типы и ошибки. У архива 61 `undetected`, два тайм-аута, одна ошибка и семь неподдерживаемых проверок. Поэтому 0/71 не означает 71 успешную проверку. Результат Python получен из существующего отчёта от 31.10.2026; дата получения не подменяет дату анализа. Сводка по каждому файлу сохранена в [JSON](virustotal-v0.4.1.json).

## Точные SHA-256

**GeoRoute-Windows-x64-0.4.1.zip**

```text
538bfd94aaf31136a298f74ac531b0c16c1878138acf80f2c1ea134e98b8fbde
```

**GeoRoute.cmd**

```text
7679c1919d66db8e0dfb5662fe94e44ff6ebd2317fade29729918c80810a2066
```

**_service/NextDNS-GUI.ps1**

```text
a9c4800ddfabef50dc768d1a804513a62fd86fd5c8d09f5de2fc27a9eabae911
```

**_service/AppInstance.ps1**

```text
8c4a0f723983c4ba07ca32e7207ef121e59d762a8e21f3384199a06efb0f26b6
```

**_service/bridge/bridge.py**

```text
76daf366968e2158f4fe21e50e403716f87de5a419aa5c314b8b19b430e6918a
```

**_service/bridge/python/python.exe**

```text
d718435b892db4ad5b547d12fec61be7baa7faf7a58d857ea58053be24c7a000
```

## Проверка и происхождение

- Код собранного пакета: commit `820c56ea9065e7674c60356d2db5867e3828ca2a`.
- [GitHub Actions 42079438711](https://github.com/Georgy-hook/GeoRoute/actions/runs/42079438711): автоматические проверки GUI, мониторинга, профилей, восстановления, запуска, миграции автозапуска и DNS-протокола; smoke-тест запуска GeoRoute.cmd прямо из чистой копии пакета.
- [SCM integration 42079438552](https://github.com/Georgy-hook/GeoRoute/actions/runs/42079438552): реальная временная служба в отдельной Windows VM, LocalService, запуск/остановка/перезапуск, занятый порт и восстановление. DNS сетевых адаптеров не менялся. Это проверка службы, а не перезагрузка компьютера пользователя.
- Проверены SHA-256 обоих GitHub artifacts, самого ZIP и всех пяти выбранных членов. Публикуется точный архив из прошедшего проверку artifact, без пересборки и перепаковки.
- Пользовательские профили, ключи, cookies, история и журналы не отправлялись. Остальные DLL/ресурсы внутри архива отдельно не проверялись.

## Что изменилось относительно 0.4.0

Промежуточные изменения компилятора и EXE launcher не обеспечили отсутствие обнаружений; [все результаты экспериментов](virustotal-experiments-2026-11-05.md) сохранены. Финальная поставка убирает ненужные собственные EXE-обёртки и оставляет явные скрипты приложения с системными/официальными host-процессами. У GUI сохранены трей, одна копия окна, профили и ручное подтверждение системных изменений.

Старые отчёты EXE не очищены и не объявлены ложными: [снимок 0.4.0](virustotal-v0.4.0.md) остаётся доступен. Точное внутреннее правило закрытых моделей не раскрыто. Подтверждён источник обнаружений на конкретных файлах и измерен результат новой поставки. Отключения антивирусов, исключений, упаковки/обфускации или переименования прежнего бинарника под другую маску не было.

[Описание результатов VirusTotal](https://docs.virustotal.com/reference/analyses-object).
