# k8s-new — ShiroVPN в Kubernetes

Манифесты ядра и VPN-нод из репозитория `deploy`, переложенные в kustomize +
Argo CD по образцу `k8s-toy`. Папка пока не git-репозиторий: её содержимое
задумано как корень репозитория `ShiroVPN/k8s_new`, поэтому `repoURL` в
`argocd/*.yaml` указывает туда.

Две единицы деплоя, как и в compose:

```
namespace shiro                     namespace shiro-peerhub-wg
┌────────────────────────────┐      ┌────────────────────────────┐
│ postgres  rabbitmq  redis  │◀─────│ peerhub-wireguard-worker   │
│ main-api-worker+scheduler  │ amqp │ peerhub-heartbeat          │
│ bot  main-api-webhook      │ redis│ wg-easy (hostNetwork)      │
│ caddy (hostPort 80/443)    │      │ wg-easy-hooks (Job)        │
│ cloudbeaver                │      └────────────────────────────┘
└────────────────────────────┘
```

## Раскладка

Один объект — один файл, компоненты разложены по папкам.

```
manifests/core/
  config/             core-config, main-api-config (config.yml), caddy-config (Caddyfile)
  postgres/           pvc, deployment, service
  rabbitmq/           pvc, deployment, service
  redis/              deployment, service
  main-api-worker/    deployment (+ init-контейнер migrate)
  main-api-scheduler/ deployment
  main-api-webhook/   deployment, service
  bot/                deployment, service
  caddy/              pvc, deployment
  cloudbeaver/        pvc, deployment, service
manifests/node/
  wg-easy/                  pvc, deployment, service
  peerhub-wireguard-worker/ pvc, deployment
  peerhub-heartbeat/        deployment
  wg-easy-hooks/            configmap, job
overlays/core/              namespace shiro, nodeSelector, ksops.yaml
overlays/peerhub-wg/        namespace shiro-peerhub-wg, peerhub-config, ksops.yaml
argocd/                     Application'ы core и peerhub-wg + KSOPS-патч repo-server
.sops.yaml                  recipients (age) и что шифровать
secrets/                    примеры Secret'ов (открытые) и *.enc.yaml (в git)
deploy.sh                   init_cluster | join_cluster | label | run (--profile)
```

Профиль — это метка узла `shiro.io/<profile>=true`. Одна машина может нести
несколько профилей: после `init_cluster` на ней стоит `shiro.io/core=true`, и
та же машина получает `shiro.io/peerhub-wg=true` командой
`./deploy.sh label --profile peerhub-wg`. У каждой
следующей VPN-ноды своё имя профиля (`peerhub-wg-2`), потому что `PEERHUB_ID`,
`COUNTRY`, `SERVER_NAME`, `WG_HOST` у неё свои.

## Секреты: SOPS + age

`secrets/*.enc.yaml` — обычные Secret-манифесты, зашифрованные SOPS, лежат в
git. Значения (только `data`/`stringData`) — шифротекст, имена и namespace
видны. Argo CD расшифровывает их при синхронизации через KSOPS, поэтому на
машины ничего копировать не нужно.

Ключи:

```bash
age-keygen -o ~/.config/sops/age/keys.txt   # приватный ключ, в git не кладётся
# публичный ключ (age1...) — в .sops.yaml, по одному на разработчика
```

Приватным ключом разработчик расшифровывает и меняет секреты:

```bash
sops secrets/core.enc.yaml          # откроет расшифрованный YAML в $EDITOR
sops -e secrets/core.yaml > secrets/core.enc.yaml
```

Argo CD нужен **один приватный ключ**, чей публичный адрес есть в `.sops.yaml`.
Он кладётся файлом на машину с Argo CD, дальше `init_cluster` сам создаёт из
него Secret `sops-age` в namespace `argocd`. GitHub ключ не нужен: CI секретов
не расшифровывает.

Один раз перед первым запуском (значения — из `deploy/`):

```bash
cp secrets/core.example.yaml secrets/core.yaml
cp secrets/node.example.yaml secrets/node.yaml
kubectl create secret docker-registry ghcr --docker-server=ghcr.io \
  --docker-username=<login> --docker-password=<PAT> \
  --dry-run=client -o yaml > secrets/ghcr.yaml
$EDITOR secrets/core.yaml secrets/node.yaml
sops -e secrets/core.yaml > secrets/core.enc.yaml
sops -e secrets/node.yaml > secrets/node.enc.yaml
sops -e secrets/ghcr.yaml > secrets/ghcr.enc.yaml
```

Открытые `secrets/*.yaml` — в `.gitignore`, в git попадают только `*.enc.yaml`
и `*.example.yaml`. `ghcr.enc.yaml` один на все namespace: kustomize ставит
Secret в namespace того overlay, который его подключает.

## Чем отличается от compose

- **Миграции** — init-контейнер `migrate` у `main-api-worker` (в compose это
  отдельный сервис). Схема обновляется до старта воркера.
- **Порядок старта** — `depends_on` нет. postgres/rabbitmq/redis поднимаются
  первыми своими readiness-пробами, остальные поды перезапускаются, пока не
  достучятся. Это нормально, как и в compose с ботом.
- **URL'ы целиком в Secret** (`DATABASE_URL`, `BROKER_URL`, `BACKEND_URL`):
  поды не собирают их из пароля и хоста, а просто читают.
- **Ноды — это поды в том же кластере**, поэтому воркер и heartbeat ходят в
  брокер и Redis по Service-именам (`rabbitmq.shiro.svc.cluster.local`), без
  hostPort и без адреса ядра в конфиге.
- **wg-easy** работает с `hostNetwork: true`: интерфейс `wg0` создаётся в сети
  хоста, иначе туннель изолирован в pod-сети. Поэтому нужен
  `net.ipv4.ip_forward=1` на самой ноде, а UI 51821 наружу не публикуется —
  только port-forward.
- **Caddy выключен в `overlays/core`** (`replicas: 0`): 80/443 на машине уже
  заняты другим Caddy. Пока он выключен, вебхук Platega и мини-приложение
  снаружи недоступны (платежи всё равно выключены). Освободятся порты —
  поставить `1`.
- **Redis без тома** (как в compose): результаты задач живут час, терять их
  не страшно.
- **CloudBeaver** — UI к Postgres, добавлен сверх compose (был в черновике
  `k8s`). Наружу не публикуется, доступ через port-forward.
- **Теги образов** — прямо в манифестах, руками; после правки нажать Sync.
- **Не перенесено:** `backup.sh`, `monitor.sh`, `tg.sh`, `topup.sh` (хостовые
  cron-скрипты поверх `docker compose`) и `watchdog/` (живёт на другом
  сервере). Значит, бэкапов и алертов в этой схеме пока нет.

## Что нужно на сервере

- 80/tcp и 443/tcp снаружи — caddy берёт сертификаты Let's Encrypt.
- 51820/udp снаружи — WireGuard.
- Ядро WireGuard/AmneziaWG: `sudo modprobe wireguard` (на OpenVZ/LXC не
  заработает — нужен KVM).
- Форвардинг на хосте, потому что wg-easy в hostNetwork:
  `sudo sysctl -w net.ipv4.ip_forward=1` и, если нужен IPv6,
  `net.ipv6.conf.all.forwarding=1`; закрепить в `/etc/sysctl.d/`.
- A-записи `WEBHOOK_DOMAIN`, `MINI_APP_DOMAIN` и `WG_HOST` — на этот сервер.
- Если на машине ещё работает compose-стек, сначала погасить его:
  `cd /opt/shiro/deploy/core && docker compose down` и то же для `node` —
  80/443 и 51820/udp заняты.
- Для присоединения других серверов: 6443/tcp от них, 8472/udp и 10250/tcp в
  обе стороны.

## Всё на одном сервере

```bash
git clone git@github.com/ShiroVPN/k8s_new.git
cd k8s_new
./deploy.sh init_cluster
./deploy.sh label --profile peerhub-wg
./deploy.sh run --profile core
./deploy.sh run --profile peerhub-wg
```

`run --profile peerhub-wg` спросит `PEERHUB_ID` (предложит uuid), `COUNTRY`,
`SERVER_NAME`, `WG_HOST` и `WG_PORT` и запишет их в
`overlays/peerhub-wg/peerhub-config.yaml` — закоммитить и запушить до Sync.
На машине без публичного IP в `WG_HOST` вписать `0.0.0.0`: конфиги клиентов с
таким Endpoint не заработают, но стек и бот поднимутся.

Репозиторий публичный, доступ Argo CD настраивать не нужно: панель
сама склонирует его по `repoURL`. Нажать **Sync** у `core`, затем у
`peerhub-wg`. `init_cluster` берёт ключ из `SOPS_AGE_KEY_FILE` или
`~/.config/sops/age/keys.txt`, ставит Argo CD и KSOPS и создаёт `sops-age`.
Ключ разработчика попадает на машину с Argo CD один раз, копией:

```bash
mkdir -p ~/.config/sops/age
scp <dev>@<laptop>:.config/sops/age/keys.txt ~/.config/sops/age/keys.txt
```

Если ключ лежит не в `~/.config/sops/age/keys.txt`:

```bash
SOPS_AGE_KEY_FILE=/path/to/age.agekey ./deploy.sh init_cluster
```

Значения, которые правятся не в секретах, а в конфигах:

- `manifests/core/config/core.yaml` — `WEBHOOK_DOMAIN`, `MINI_APP_DOMAIN`,
  `STUB_PAYMENT`, `ADMIN_TELEGRAM_IDS`.
- `overlays/peerhub-wg/peerhub-config.yaml` — `PEERHUB_ID` (uuid предложит
  `run --profile peerhub-wg`), `COUNTRY`, `SERVER_NAME`, `WG_HOST`, `WG_PORT`.

Закоммитить и запушить в `main` — Argo тянет оттуда. Namespace'ы
`shiro`/`shiro-peerhub-wg` создаются синхронизацией, вручную их создавать не
нужно.

Проверки:

```bash
sudo k3s kubectl -n shiro get pods
sudo k3s kubectl -n shiro-peerhub-wg get pods
sudo k3s kubectl -n shiro logs deploy/caddy | grep -i 'certificate obtained'
sudo k3s kubectl -n shiro logs deploy/bot --tail 5        # "Bot started"
sudo k3s kubectl -n shiro exec deploy/postgres -- psql -U shiro -d shiro \
  -c 'select server_name, country, last_seen_at from peerhubs_table'
```

Бот в первую минуту может перезапускаться: он ждёт, пока воркер объявит
`main_api_queue`. Job `wg-easy-hooks` дописывает правила изоляции клиентов в
PostUp, а PostUp выполняется при поднятии `wg0` — поэтому один раз после
первого Sync:

```bash
sudo k3s kubectl -n shiro-peerhub-wg logs job/wg-easy-hooks
sudo k3s kubectl -n shiro-peerhub-wg rollout restart deploy/wg-easy
```

## Вторая VPN-нода

Отдельный сервер — отдельный профиль с своим именем:

```bash
cp -r overlays/peerhub-wg overlays/peerhub-wg-2
#  kustomization.yaml: namespace shiro-peerhub-wg-2, nodeSelector shiro.io/peerhub-wg-2
#  peerhub-config.yaml: PEERHUB_ID, COUNTRY, SERVER_NAME, WG_HOST, WG_PORT
cp argocd/peerhub-wg.yaml argocd/peerhub-wg-2.yaml   # name/path/namespace

K3S_URL=https://<ядро>:6443 K3S_TOKEN=<токен> ./deploy.sh join_cluster --profile peerhub-wg-2
./deploy.sh run --profile peerhub-wg-2
```

Второй overlay подключает тот же `secrets/node.enc.yaml` — пароль wg-easy у
нод общий. Если нужен свой, сделайте `secrets/node-2.enc.yaml` по образцу и
поправьте `overlays/peerhub-wg-2/ksops.yaml`.

## Панели

```bash
# Argo CD
sudo k3s kubectl -n argocd port-forward svc/argocd-server 18080:443 --address 127.0.0.1

# UI wg-easy
sudo k3s kubectl -n shiro-peerhub-wg port-forward deploy/wg-easy 51821:51821

# management RabbitMQ
sudo k3s kubectl -n shiro port-forward deploy/rabbitmq 15672:15672

# CloudBeaver: логин admin, пароль CB_ADMIN_PASSWORD из shiro-secret.
# Postgres внутри UI: host postgres, база shiro, пользователь shiro.
sudo k3s kubectl -n shiro port-forward deploy/cloudbeaver 8978:8978
```

CI собирает `manifests/core` и `manifests/node`; overlay'и не собираются, потому
что для них нужен приватный ключ.
