#!/bin/bash
set -euo pipefail
IMAGE=${IMAGE-/var/lib/logs.img}
MOUNT_POINT=${MOUNT_POINT-/LOGS}
IMAGE_SIZE=${IMAGE_SIZE-200M}
LOGS_UUID=${LOGS_UUID-}
trap 'echo "ОШИБКА: подготовка или монтирование LOGS не выполнены" >&2' ERR
if (( EUID != 0 )); then echo 'ОШИБКА: требуются права root' >&2; exit 1; fi
for cmd in mountpoint mkdir mount df; do command -v "$cmd" >/dev/null; done
if ! mountpoint -q -- "$MOUNT_POINT"; then
    mkdir -p -- "$MOUNT_POINT"
    if [[ -n $LOGS_UUID ]]; then
        [[ $LOGS_UUID =~ ^[a-zA-Z0-9-]+$ ]] || { echo 'Некорректный UUID' >&2; exit 2; }
        # A preformatted real partition is NEVER formatted here.
        mount -U "$LOGS_UUID" -- "$MOUNT_POINT"
    else
        if [[ ! -e $IMAGE ]]; then
            command -v mkfs.ext4 >/dev/null
            # noclobber protects existing files; format only our newly created image.
            (set -C; : > "$IMAGE")
            truncate -s "$IMAGE_SIZE" -- "$IMAGE"
            mkfs.ext4 -q -- "$IMAGE"
        fi
        [[ -f $IMAGE && ! -L $IMAGE ]]
        mount -o loop -- "$IMAGE" "$MOUNT_POINT"
    fi
fi
for c in auth_service data_process_service system_event_handler_service; do
    [[ ! -L $MOUNT_POINT/$c ]]
    mkdir -p -- "$MOUNT_POINT/$c"
done
df -h -- "$MOUNT_POINT"
