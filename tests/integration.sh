#!/bin/bash
# Only paths under our own mktemp directory may be mounted/removed.
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
if (( EUID != 0 )); then
    echo 'SKIP integration: требуются root и возможность loop mount'; exit 0
fi
for cmd in mktemp mount umount mountpoint mkfs.ext4 dd python3; do
    if ! command -v "$cmd" >/dev/null; then echo "SKIP integration: нет $cmd"; exit 0; fi
done
work=$(mktemp -d /tmp/logs-guard-loop-XXXXXXXX)
mounted=0
cleanup() {
    if (( mounted )); then
        if ! umount -- "$work/mnt"; then
            echo "ОШИБКА очистки: сохранён $work (файловая система ещё смонтирована)" >&2
            return 1
        fi
    fi
    rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mkdir -- "$work/mnt"
# Allocate the entire image; no sparse-file measurements.
dd if=/dev/zero of="$work/disk.img" bs=1M count=64 status=none
mkfs.ext4 -q -m 0 -F "$work/disk.img"
if ! mount -o loop -- "$work/disk.img" "$work/mnt"; then
    echo 'SKIP integration: loop mount недоступен'; exit 0
fi
mounted=1
LOGS_TEST_MOUNT="$work/mnt" python3 -m unittest discover -s tests -p test_integration.py -v
umount -- "$work/mnt"
mounted=0
if LOGS_DIR="$work/mnt" bash ./logs_guard.sh >"$work/unmounted.out" 2>&1; then
    echo 'FAIL integration unmounted: ожидался код 2'; exit 1
else
    rc=$?
    [[ $rc == 2 ]]
    echo 'OK integration: несмонтированная точка отклонена (код 2)'
fi
