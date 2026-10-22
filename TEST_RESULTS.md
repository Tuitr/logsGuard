# Фактические результаты проверки

Дата: 2026-10-22. Среда: Linux, пользователь bgdn, uid=1000 (без root).

## Выполнено

```bash
./test_logs_guard.sh
```

Последний прогон:

```text
test_access_and_missing_command ... ok
test_boundaries_and_selection ... ok
test_collision ... ok
test_command_failures ... ok
test_concurrent ... ok
test_delete_error_and_aggregate ... ok
test_empty_single_and_symlink ... ok
test_environment ... ok
test_post_check ... ok
test_read_failure_and_other_component ... ok
test_repeat_and_post_usage ... ok
test_thresholds ... ok

Ran 12 tests in 1.563s
OK
SKIP integration: требуются root и возможность loop mount
```

Это 12 тестовых методов, часть содержит несколько сценариев через subTest.
Код завершения общей команды — 0: быстрые проверки успешны, интеграционные
**пропущены**. Нулевой код при наличии SKIP не означает прохождение loop-тестов.

Дополнительно выполнены с кодом 0:

```bash
bash -n logs_guard.sh mount_logs.sh install.sh test_logs_guard.sh tests/integration.sh
git diff --check
```

## Не выполнено

Весь loop-набор (5 методов: below, one_two_three с тремя случаями,
nonlogs_and_single, single_large_current, real_enospc), а также проверка
несмонтированной точки после loop-набора: пропуск из-за отсутствия root.
Следовательно, реальное выделение места ext4 и настоящий ENOSPC в этой среде
**не проверены**. Быстрый набор проверил внедрённые ошибки записи/чтения tar,
но они не заменяют интеграционный прогон.

Для выполнения на машине с root и loop mount:

```bash
sudo ./tests/integration.sh
```

Установка в /usr/local, изменение systemd и монтирование настоящего раздела
здесь не выполнялись. ShellCheck в среде отсутствует и не запускался.
Полная матрица сценариев и оставшиеся ограничения приведены в README.md.
