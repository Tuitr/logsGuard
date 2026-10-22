#!/bin/bash
# GNU/Linux, Bash 4+. Codes: 0 OK, 1 execution error, 2 environment,
# 3 invalid configuration, 4 already running, 5 still above threshold.
set -u
export LC_ALL=C
error() { echo "ОШИБКА: $*" >&2; }
THRESHOLD=${THRESHOLD-90}
# Bound the input before arithmetic (including leading zeroes).
if [[ ! $THRESHOLD =~ ^[0-9]{1,3}$ ]]; then
    error 'THRESHOLD: требуется целое число 1..100 (не более трёх цифр)'; exit 3
fi
THRESHOLD=$((10#$THRESHOLD))
if (( THRESHOLD < 1 || THRESHOLD > 100 )); then
    error 'THRESHOLD: требуется целое число 1..100'; exit 3
fi
LOGS_DIR=${LOGS_DIR-/LOGS}
components=(auth_service data_process_service system_event_handler_service)
if [[ $(id -u) != 0 ]]; then error 'требуются права root'; exit 2; fi
for cmd in mountpoint df du find sort tar gzip mktemp rm ln flock id; do
    if ! command -v "$cmd" >/dev/null; then error "нет команды $cmd"; exit 2; fi
done
if [[ ! -d $LOGS_DIR || -L $LOGS_DIR ]] || ! mountpoint -q -- "$LOGS_DIR"; then
    error "$LOGS_DIR отсутствует или не смонтирован"; exit 2
fi
if [[ ! -r $LOGS_DIR || ! -w $LOGS_DIR || ! -x $LOGS_DIR ]]; then error "нет доступа к $LOGS_DIR"; exit 2; fi
# Open the mount directory itself: no lock file to unlink or replace.
exec {lock_fd}<"$LOGS_DIR" || exit 2
flock -n -E 4 "$lock_fd"
lock_status=$?
if (( lock_status == 4 )); then error 'другой запуск уже выполняется'; exit 4; fi
if (( lock_status != 0 )); then error 'не удалось установить блокировку'; exit 1; fi
for c in "${components[@]}"; do
    dir=$LOGS_DIR/$c
    if [[ ! -d $dir || -L $dir || ! -r $dir || ! -w $dir || ! -x $dir ]]; then
        error "каталог компонента недоступен: $dir"; exit 2
    fi
done
# Validate command status AND output; never calculate from empty strings.
read_df() {
    local output
    output=$(df -B1 --output=size,pcent -- "$LOGS_DIR") || { error 'df завершился с ошибкой'; return 1; }
    if [[ $output =~ ^[^$'\n']*$'\n'[[:space:]]*([0-9]+)[[:space:]]+([0-9]+)%[[:space:]]*$ ]]; then
        size=${BASH_REMATCH[1]}; usage=${BASH_REMATCH[2]}
        if (( ${#size} <= 18 && ${#usage} <= 3 )); then
            size=$((10#$size)); usage=$((10#$usage))
            (( size > 0 )) && return 0
        fi
    fi
    error 'некорректный вывод df'; return 1
}
read_df || exit 1
echo "Занято: $usage%, порог: $THRESHOLD%"
(( usage < THRESHOLD )) && { echo 'Ниже порога: без изменений'; exit 0; }
# Avoid overflow in size * threshold.
per_dir=$(( (size / 100 * THRESHOLD + size % 100 * THRESHOLD / 100) / 3 ))
echo "Лимит каталога: $per_dir байт"
# Preflight every du before any mutation.
sizes=()
for c in "${components[@]}"; do
    output=$(du -s -B1 -- "$LOGS_DIR/$c") || { error "du: $c"; exit 1; }
    value=${output%%$'\t'*}
    if [[ ! $value =~ ^[0-9]{1,18}$ ]]; then error "некорректный вывод du: $c"; exit 1; fi
    sizes+=("$((10#$value))")
done
tmp=''; listing=''
cleanup() {
    local status=0
    if [[ -n $tmp ]]; then rm -f -- "$tmp" || status=1; fi
    if [[ -n $listing ]]; then rm -f -- "$listing" || status=1; fi
    return "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
failed=0
for i in "${!components[@]}"; do
    c=${components[i]}; dir=$LOGS_DIR/$c
    (( sizes[i] > per_dir )) || continue
    # Latest = maximum basename in bytewise C order, independent of mtime.
    listing=$(mktemp) || { error 'mktemp списка'; failed=1; continue; }
    if ! find "$dir" -maxdepth 1 -type f -name '*.log' -printf '%f\0' >"$listing"; then
        error "find: $c"; failed=1; cleanup || exit 1; listing=''; continue
    fi
    if ! sort -z -o "$listing" "$listing"; then error "sort: $c"; failed=1; cleanup || exit 1; listing=''; continue; fi
    if ! mapfile -d '' -t files <"$listing"; then error "чтение списка: $c"; exit 1; fi
    if ! rm -f -- "$listing"; then error "удаление списка: $c"; exit 1; fi
    listing=''
    if (( ${#files[@]} < 2 )); then echo "$c: нечего архивировать"; continue; fi
    unset 'files[${#files[@]}-1]'
    tmp=$(mktemp -- "$dir/${c}_archive_XXXXXXXXXXXX.part") || { error "mktemp: $c"; failed=1; continue; }
    archive=${tmp%.part}.tar.gz
    if ! tar -czf "$tmp" -C "$dir" -- "${files[@]}"; then
        error "tar: $c, исходники сохранены"; failed=1; cleanup || exit 1; tmp=''; continue
    fi
    # Hard link publishes atomically and fails if the destination already exists.
    if ! ln -T -- "$tmp" "$archive"; then
        error "публикация архива: $c, исходники сохранены"; failed=1; cleanup || exit 1; tmp=''; continue
    fi
    if ! rm -- "$tmp"; then error "удаление временного архива: $c"; exit 1; fi
    tmp=''
    paths=(); for file in "${files[@]}"; do paths+=("$dir/$file"); done
    if ! rm -- "${paths[@]}"; then
        error "удаление исходников: $c; архив сохранён: $archive"; failed=1
    else
        echo "$c: создан $archive, удалено ${#files[@]} файлов"
    fi
done
read_df || exit 1
if (( usage >= THRESHOLD )); then
    echo "ВНИМАНИЕ: раздел всё ещё достиг порога: $usage% >= $THRESHOLD%"
    (( failed == 0 )) && exit 5
fi
(( failed == 0 )) || exit 1
exit 0
