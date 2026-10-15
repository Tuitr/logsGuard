#!/bin/bash

#!/bin/bash

# Настройки
LOGS_DIR="${LOGS_DIR:-/LOGS}"      # раздел с логами (можно переопределить)
THRESHOLD="${THRESHOLD:-90}"       # порог заполнения, %
COMPONENTS="auth_service data_process_service system_event_handler_service"

# Нужны права root: скрипт удаляет файлы в /LOGS
if [ "$EUID" -ne 0 ]; then
    echo "ОШИБКА: запустите через sudo" >&2
    exit 1
fi

# /LOGS должен быть отдельным смонтированным разделом
if ! mountpoint -q "$LOGS_DIR"; then
    echo "ОШИБКА: $LOGS_DIR не смонтирован" >&2
    exit 2
fi

# Сколько процентов занято
USAGE=$(df --output=pcent "$LOGS_DIR" | tail -1 | tr -dc '0-9')

echo "Занято: $USAGE%, порог: $THRESHOLD%"


if [ "$USAGE" -lt "$THRESHOLD" ]; then
	echo "Порог не превышен, ничего не делаю"
	exit 0
fi
echo "Порог превышен! Нужна архивация"

# Размер раздела в байтах
SIZE=$(df -B1 --output=size "$LOGS_DIR" | tail -1 | tr -dc '0-9')

# Общий лимит: сколько байт можно занять до порога
LIMIT=$(( SIZE * THRESHOLD / 100 ))

# Лимит на одну папку: треть общего
PER_DIR=$(( LIMIT / 3 ))

echo "Размер раздела: $SIZE байт, лимит: $LIMIT, на папку: $PER_DIR"

# Проверяем каждую папку
for c in $COMPONENTS; do
    DIR="$LOGS_DIR/$c"
    DIR_SIZE=$(du -s -B1 "$DIR" | cut -f1)

    if [ "$DIR_SIZE" -gt "$PER_DIR" ]; then
        echo "$c: $DIR_SIZE байт > $PER_DIR — надо архивировать"
	        # все .log, кроме самого свежего, от старых к новым
        FILES=$(cd "$DIR" && ls *.log 2>/dev/null | sort | head -n -1)

        if [ -z "$FILES" ]; then
            echo "  нечего архивировать (остался только текущий лог)"
            continue
        fi

        # имя архива с датой и временем, чтобы не перезаписать старые архивы
        ARCHIVE="${c}_archive_$(date +%Y_%m_%d_%H%M%S).tar.gz"

        # сначала архив, удаление — только если архив создан
        if tar -czf "$DIR/$ARCHIVE" -C "$DIR" $FILES; then
            (cd "$DIR" && rm $FILES)
            echo "  создан $ARCHIVE, удалено файлов: $(echo "$FILES" | wc -l)"
        else
            echo "  ОШИБКА: архив не создан, файлы не тронуты" >&2
        fi
    else
        echo "$c: $DIR_SIZE байт — в норме"
    fi
done
