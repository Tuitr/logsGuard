#!/bin/bash
IMAGE="${IMAGE:-/var/lib/logs.img}"       # файл-образ, наша «флешка»
MOUNT_POINT="${MOUNT_POINT:-/LOGS}"       # куда её подключаем
IMAGE_SIZE="${IMAGE_SIZE:-200M}"          # размер образа, если его нужно создать
COMPONENTS="auth_service data_process_service system_event_handler_service"   

if [ "$EUID" -ne 0 ]; then
    echo "ОШИБКА: запустите через sudo" >&2
    exit 1
fi

#если смонтировано - монтируем
if mountpoint -q "$MOUNT_POINT"; then
    echo "$MOUNT_POINT уже смонтирован"
else
    # если образа нет — создать и отформатировать
    if [ ! -f "$IMAGE" ]; then
        echo "Образ $IMAGE не найден — создаю ($IMAGE_SIZE)"
        if ! truncate -s "$IMAGE_SIZE" "$IMAGE" || ! mkfs.ext4 -q -L LOGS "$IMAGE"; then
            echo "ОШИБКА: не удалось создать образ" >&2
            exit 2
        fi
    fi
    mkdir -p "$MOUNT_POINT"
    if ! mount -o loop "$IMAGE" "$MOUNT_POINT"; then
        echo "ОШИБКА: не удалось смонтировать" >&2
        exit 2
    fi
    echo "Смонтировал $IMAGE в $MOUNT_POINT"
fi

#создать папки компонент (работает всегда)
for c in $COMPONENTS; do
	mkdir -p "$MOUNT_POINT/$c"
done

#показать результат
df -h "$MOUNT_POINT"
