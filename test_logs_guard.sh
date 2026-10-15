#!/bin/bash
# Автотесты для logs_guard.sh (п. 5* задания)

# ---------- Настройки ----------
GUARD="$(dirname "$0")/logs_guard.sh"   # проверяемый скрипт (лежит рядом)
IMG="/tmp/test_logs.img"                # образ тестового раздела
MNT="/mnt/test_logs"                    # куда его монтируем
COMPONENTS="auth_service data_process_service system_event_handler_service"
PASS=0                                  # сколько проверок прошло
FAIL=0                                  # сколько провалилось

if [ "$EUID" -ne 0 ]; then
    echo "ОШИБКА: запустите через sudo" >&2
    exit 1
fi

# ---------- Вспомогательные функции ----------

# Создать чистый тестовый раздел 50 МБ с тремя папками
setup() {
    umount "$MNT" 2>/dev/null
    rm -f "$IMG"
    truncate -s 50M "$IMG"
    mkfs.ext4 -q -m 0 "$IMG"
    mkdir -p "$MNT"
    mount -o loop "$IMG" "$MNT"
    for c in $COMPONENTS; do
        mkdir -p "$MNT/$c"
    done
}

# Убрать тестовый раздел (вызывается автоматически при выходе)
cleanup() {
    umount "$MNT" 2>/dev/null
    rm -f "$IMG"
}
trap cleanup EXIT

# Создать логи: make_logs ПАПКА КОЛИЧЕСТВО РАЗМЕР_МБ
make_logs() {
    local comp=$1 count=$2 size=$3 i
    for i in $(seq -w 1 "$count"); do
        dd if=/dev/zero of="$MNT/$comp/${comp}_2026_10_${i}_17600${i}000.log" \
           bs=1M count="$size" status=none
    done
}

# Посчитать файлы по шаблону: count_files ПАПКА "ШАБЛОН"
count_files() {
    ls "$MNT/$1"/$2 2>/dev/null | wc -l
}

# Запустить logs_guard.sh на тестовом разделе: run_guard ПОРОГ
run_guard() {
    LOGS_DIR="$MNT" THRESHOLD="$1" "$GUARD" > /dev/null 2>&1
    RC=$?
}

# Проверка: check "описание" условие
check() {
    local desc="$1"
    shift
    if "$@"; then
        echo "  [OK]   $desc"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $desc"
        FAIL=$((FAIL + 1))
    fi
}

# ---------- Сценарии ----------

echo "T1: раздел почти пустой → ничего не меняется"
setup
make_logs auth_service 3 1
BEFORE=$(ls -R "$MNT")
run_guard 90
check "код возврата 0"             [ "$RC" -eq 0 ]
check "архивов нет"                [ "$(count_files auth_service '*.tar.gz')" -eq 0 ]
check "файлы не изменились"        [ "$BEFORE" = "$(ls -R "$MNT")" ]

echo "T2: переполнена одна папка → архив только в ней"
setup
make_logs auth_service 30 1
run_guard 50
check "код возврата 0"             [ "$RC" -eq 0 ]
check "в auth_service один архив"  [ "$(count_files auth_service '*.tar.gz')" -eq 1 ]
check "остался один .log"          [ "$(count_files auth_service '*.log')" -eq 1 ]
check "свежий лог (_30_) на месте" [ -f "$MNT/auth_service/auth_service_2026_10_30_1760030000.log" ]
check "в архиве 29 файлов"         [ "$(tar -tzf "$MNT"/auth_service/*.tar.gz | wc -l)" -eq 29 ]
check "другие папки без архивов"   [ "$(count_files data_process_service '*.tar.gz')" -eq 0 ]


echo "T3: переполнены две папки → архивы в двух, третья не тронута"
setup
make_logs auth_service 15 1
make_logs data_process_service 15 1
make_logs system_event_handler_service 2 1
run_guard 50
check "код возврата 0"                    [ "$RC" -eq 0 ]
check "архив в auth_service"              [ "$(count_files auth_service '*.tar.gz')" -eq 1 ]
check "архив в data_process_service"      [ "$(count_files data_process_service '*.tar.gz')" -eq 1 ]
check "system_event_handler без архива"   [ "$(count_files system_event_handler_service '*.tar.gz')" -eq 0 ]
check "в system_event_handler оба лога"   [ "$(count_files system_event_handler_service '*.log')" -eq 2 ]

echo "T4: раздел забит не логами → ничего не архивируется"
setup
make_logs auth_service 2 1
dd if=/dev/zero of="$MNT/garbage.bin" bs=1M count=30 status=none
run_guard 50
check "код возврата 0"                    [ "$RC" -eq 0 ]
check "архивов нет нигде"                 [ "$(find "$MNT" -name '*.tar.gz' | wc -l)" -eq 0 ]
check "логи на месте"                     [ "$(count_files auth_service '*.log')" -eq 2 ]
check "посторонний файл не тронут"        [ -f "$MNT/garbage.bin" ]

echo "T5: один огромный текущий лог → не трогать"
setup
make_logs auth_service 1 30
run_guard 50
check "код возврата 0"                    [ "$RC" -eq 0 ]
check "архива нет"                        [ "$(count_files auth_service '*.tar.gz')" -eq 0 ]
check "текущий лог на месте"              [ "$(count_files auth_service '*.log')" -eq 1 ]

echo "T6: раздел не смонтирован → ошибка, код 2"
setup
umount "$MNT"
run_guard 50
check "код возврата 2"                    [ "$RC" -eq 2 ]

# ---------- Итог ----------
echo
echo "Итого: OK=$PASS, FAIL=$FAIL"
[ "$FAIL" -eq 0 ]      # код возврата теста: 0 — всё прошло
