# Тесты в кластере

Все наборы тестов живут в [ShiroVPN/shiro_tests](https://github.com/ShiroVPN/shiro_tests):
один образ, одна команда `pytest`, конфиг из переменных окружения. Здесь —
только Job'ы, которые этот образ запускают в уже развёрнутом стеке.

```bash
./scripts/run-tests.sh                    # оба Job'а, логи в конце
KUBECTL="sudo k3s kubectl" ./scripts/run-tests.sh
```

Скрипт перед запуском копирует `PEERHUB_ID` из `peerhub-config` ноды в
ConfigMap `tests-config` (namespace `shiro`): `main_api`-тесты будят хаб
heartbeat'ом, и id должен быть тем самым, иначе задачи уедут в очередь,
которую никто не читает.

| Job | Пространство имён | Что проверяет |
| --- | --- | --- |
| `shiro-tests-core` | `shiro` | бот, мини-приложение, контракт `main_api`, задачи воркера, инварианты схемы |
| `shiro-tests-peerhub-wireguard` | `shiro-peerhub-wg` | `peerhub.*` на wg-easy |

Набор `tests/peerhub_3xui` живёт в том же образе, но требует живую панель
3x-ui (`XUI_URL`, `XUI_TOKEN`, `XUI_SUBSCRIPTION_BASE_URL`) — его запускают
там, где такая нода есть.

## Чего не хватает для полного прогона

- **Платежи.** `main_api.create_payment` ходит в Platega по `PLATEGA_URL`
  самого воркера, а не теста. Модуль `tests/main_api/worker/test_payments.py`
  поэтому исключён из Job'а: чтобы его прогнать, направьте
  `PLATEGA_URL` воркера на поддельную Platega
  (`tests/main_api/fake_platega.py` из `shiro_tests`) и уберите `--deselect`.

## Образ

`ghcr.io/shirovpn/shiro_tests:<version>`, тег вписан в оба Job'а руками:
после релиза `shiro_tests` (тег `v*`) обновите его и сделайте Sync.

## CI

`.github/workflows/tests.yml` на PR в `main` собирает манифесты и, если в
секретах репозитория есть `KUBECONFIG_B64` (base64 от kubeconfig с доступом к
`shiro` и `shiro-peerhub-wg`), запускает те же Job'ы и печатает логи. Без
секрета прогон в кластере пропускается — остаётся проверка манифестов.
