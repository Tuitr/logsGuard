#!/bin/bash
set -euo pipefail
# Установка лабы: скрипты, юниты systemd, включение автозапуска

if [ "$EUID" -ne 0 ]; then
    echo "ОШИБКА: запустите через sudo" >&2
    exit 1
fi

# перейти в папку, где лежит install.sh, чтобы найти соседние файлы
cd "$(dirname "$0")" || exit 1

echo "1. Копирую скрипты в /usr/local/sbin"
install -m 755 mount_logs.sh logs_guard.sh /usr/local/sbin/ || exit 2

echo "2. Копирую unit-файлы в /etc/systemd/system"
install -m 644 logs-mount.service logs-guard.service logs-guard.timer /etc/systemd/system/ || exit 2

if [[ ! -e /etc/default/logs-guard ]]; then
    install -m 644 logs-guard.conf /etc/default/logs-guard
fi

echo "3. Включаю автозапуск"
systemctl daemon-reload
systemctl enable --now logs-mount.service
systemctl enable --now logs-guard.timer

echo
echo "Готово:"
findmnt /LOGS
systemctl list-timers logs-guard.timer --no-pager
