# logsGuard

Защита раздела с логами от переполнения для Linux-систем с systemd.

Логи трёх сервисов хранятся на отдельном разделе `/LOGS`. Раздел автоматически
монтируется при загрузке, а фоновая проверка каждые 5 минут следит за его
заполнением. Если занято больше порога (по умолчанию 90%), старые логи
упаковываются в `.tar.gz` — только в тех папках, которые превысили свою долю
места. Текущий лог каждого сервиса никогда не трогается.

## Как это работает

```
загрузка ОС
   └─ logs-mount.service ── mount_logs.sh ── /var/lib/logs.img → /LOGS
                                               ├── auth_service/
                                               ├── data_process_service/
                                               └── system_event_handler_service/

каждые 5 минут
   └─ logs-guard.timer ── logs-guard.service ── logs_guard.sh
         1. df: заполнение раздела ≥ порога?        нет → выход
         2. лимит на папку = размер × порог / 3
         3. du: какая папка превысила свою треть?
         4. tar: старые логи → архив, исходники удаляются после успешного tar
```

Логи именуются как `{сервис}_YYYY_MM_DD_{timestamp}.log`, поэтому сортировка
имён совпадает с хронологическим порядком.

## Состав

| Файл | Назначение |
| --- | --- |
| `mount_logs.sh` | монтирует образ в `/LOGS`, создаёт образ и папки сервисов, если их нет |
| `logs_guard.sh` | проверка заполнения и архивация старых логов |
| `logs-mount.service` | монтирование при загрузке |
| `logs-guard.service` | запуск `logs_guard.sh` |
| `logs-guard.timer` | расписание: через 1 минуту после загрузки, затем каждые 5 минут |
| `install.sh` | установка одной командой |
| `test_logs_guard.sh` | автотесты |

## Требования

Linux с systemd (проверено на Ubuntu 26.04 в WSL2), `bash`, `tar`, `e2fsprogs`, права root.

## Установка

```
git clone https://github.com/Tuitr/logsGuard.git
cd logsGuard
sudo ./install.sh
```

Скрипты копируются в `/usr/local/sbin`, unit-файлы — в `/etc/systemd/system`,
включаются монтирование и таймер. Если образа `/var/lib/logs.img` нет, он
создаётся (200 МБ, ext4). Повторный запуск `install.sh` безопасен.

## Использование

```
findmnt /LOGS                                        # раздел смонтирован
systemctl list-timers logs-guard.timer --no-pager    # следующая проверка
journalctl -u logs-guard.service -n 20 --no-pager    # журнал проверок
sudo logs_guard.sh                                   # проверить вручную
```

Пример журнала при переполнении:

```
Занято: 98%, порог: 90%
Порог превышен! Нужна архивация
Размер раздела: 179601408 байт, лимит: 161641267, на папку: 53880422
auth_service: 315392 байт — в норме
data_process_service: 159748096 байт > 53880422 — надо архивировать
  создан data_process_service_archive_2026_10_12_182437.tar.gz, удалено файлов: 59
system_event_handler_service: 4096 байт — в норме
```

## Настройки

Задаются переменными окружения, например `sudo THRESHOLD=80 logs_guard.sh`.

| Переменная | По умолчанию | Скрипт |
| --- | --- | --- |
| `LOGS_DIR` | `/LOGS` | `logs_guard.sh` |
| `THRESHOLD` | `90` (%) | `logs_guard.sh` |
| `IMAGE` | `/var/lib/logs.img` | `mount_logs.sh` |
| `MOUNT_POINT` | `/LOGS` | `mount_logs.sh` |
| `IMAGE_SIZE` | `200M` | `mount_logs.sh` |

## Коды возврата

| Код | `mount_logs.sh` | `logs_guard.sh` |
| --- | --- | --- |
| 0 | смонтировано | проверка выполнена |
| 1 | нет прав root | нет прав root |
| 2 | не удалось создать образ или смонтировать | `/LOGS` не смонтирован |

## Тесты

```
sudo ./test_logs_guard.sh
```

Тесты создают отдельный раздел `/tmp/test_logs.img` → `/mnt/test_logs`,
запускают `logs_guard.sh` на нём и удаляют раздел после прогона. Рабочий
`/LOGS` не затрагивается.

| № | Сценарий | Ожидаемый результат |
| --- | --- | --- |
| T1 | раздел почти пустой | ничего не меняется |
| T2 | переполнена одна папка | архив только в ней, текущий лог остаётся |
| T3 | переполнены две папки | архивы в двух, третья не тронута |
| T4 | раздел занят посторонним файлом | ничего не архивируется |
| T5 | один большой текущий лог | не трогается |
| T6 | раздел не смонтирован | ошибка, код 2 |

Ожидаемый итог: `Итого: OK=24, FAIL=0`.

## Удаление

```
sudo systemctl disable --now logs-guard.timer logs-mount.service
sudo rm /etc/systemd/system/logs-{mount,guard}.service /etc/systemd/system/logs-guard.timer
sudo rm /usr/local/sbin/{mount_logs,logs_guard}.sh
sudo systemctl daemon-reload
```

Образ `/var/lib/logs.img` с логами и архивами остаётся, удалите его вручную при необходимости.
