# k8s-new — ShiroVPN в Kubernetes

Манифесты ShiroVPN для kustomize и Argo CD. Репозиторий описывает ядро, бота,
observability и любое число VPN-нод. Окружение — это кластер.

## Что где живёт

- `shiro` — postgres, rabbitmq, redis, main_api (worker, scheduler, webhook),
  bot (bot, notify-worker, webapp), dbgate, pgadmin.
- `observability` — otel-collector, jaeger, prometheus, elasticsearch, grafana.
- `shiro-vpn-<name>` — одна VPN-нода: caddy, 3x-ui, wg-easy и их воркеры.

## Запуск

На первом сервере:

```bash
./deploy.sh init_cluster
./deploy.sh run --env prod --apps core,observability,bot
```

`init_cluster` печатает команду для следующего сервера. На нём:

```bash
K3S_URL=... K3S_TOKEN=... DEPLOY_KUBECONFIG_B64=... ./deploy.sh join_cluster
./deploy.sh run --env prod --apps vpn-node
```

`run` создаёт Applications. ApplicationSet'ов нет. Каждое приложение
привязано к узлу, где запустили `run`.

## VPN-нода

Одна запись `vpn-nodes/<name>.env` на ноду. `run --apps vpn-node` находит её
по имени узла, а если записи нет — спрашивает значения и создаёт файл.
Запись надо закоммитить.

## Окружения

`--env dev|prod` выбирает `components/<env>`: теги образов и правки бота.
Окружение — не ветка.

## Секреты

`secrets/*.enc.yaml` шифрует SOPS, расшифровывает KSOPS при синхронизации.
Ключ age лежит в `~/.config/sops/age/keys.txt`; `init_cluster` кладёт его в
Secret `sops-age`.

## Панели

```bash
./deploy.sh forward          # панели с паролем
./deploy.sh forward --all
./deploy.sh forward stop
```

Порты и логины — в `AGENTS.md`, раздел «Panels».

## Подробности

`AGENTS.md` описывает требования: сеть, записи нод, `vpn-node-config`,
Argo CD, обходы удалённой ноды, CI, тесты и переустановку.
