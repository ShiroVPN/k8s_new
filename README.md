# k8s-new — ShiroVPN в Kubernetes

Манифесты ядра и VPN-нод из репозитория `deploy`, переложенные в kustomize +
Argo CD по образцу `k8s-toy`. Корень репозитория `ShiroVPN/k8s_new`, поэтому
`repoURL` в `argocd/*.yaml` указывает туда.

Три единицы деплоя:

```
namespace shiro                     namespace shiro-peerhub-wg
┌────────────────────────────┐      ┌────────────────────────────┐
│ deps: postgres rabbitmq    │◀─────│ peerhub-wireguard-worker   │
│       redis                │ amqp │ peerhub-heartbeat          │
│ apps: main-api-worker      │ redis│ wg-easy (hostNetwork)      │
│       +scheduler +webhook  │      │ wg-easy-hooks (Job)        │
│       bot                  │      └────────────────────────────┘
│ aux:  caddy cloudbeaver    │
└────────────────────────────┘
                │ OTLP
                ▼
namespace observability
┌──────────────────────────────────────┐
│ otel-collector                       │
│   traces → jaeger                    │
│   metrics → prometheus (remote-write)│
│   logs → elasticsearch               │
│ grafana (datasources + 2 dashboards) │
└──────────────────────────────────────┘
```

## Раскладка

Один объект — один файл, компоненты разложены по папкам.

```
manifests/core/
  config/             core-config, main-api-config (config.yml), caddy-config (Caddyfile)
  deps/               открытое, что мы только запускаем
    postgres/         pvc, deployment, service
    rabbitmq/         pvc, deployment, service
    redis/            deployment, service
  aux/                панели и прокси вокруг стека
    caddy/            pvc, deployment
    cloudbeaver/      pvc, deployment, service
  apps/               наш код
    main-api-worker/    deployment (+ init-контейнер migrate)
    main-api-scheduler/ deployment
    main-api-webhook/   deployment, service
    bot/                deployment, service
manifests/node/
  wg-easy/                  pvc, deployment, service
  peerhub-wireguard-worker/ pvc, deployment
  peerhub-heartbeat/        deployment
  wg-easy-hooks/            configmap, job
manifests/observability/
  config/             otel-collector, prometheus, grafana provisioning
  grafana/dashboards/ Function_calls.json, Logs.json (через configMapGenerator)
  otel-collector/     deployment, service
  jaeger/             deployment, service
  prometheus/         pvc, deployment, service
  elasticsearch/      pvc, deployment, service
  grafana/            deployment, service
overlays/core/              namespace shiro, nodeSelector, ksops.yaml
overlays/peerhub-wg/        namespace shiro-peerhub-wg, peerhub-config, ksops.yaml
overlays/observability/     namespace observability, nodeSelector, ksops.yaml
argocd/                     Application'ы core, peerhub-wg, observability + KSOPS-патч
.sops.yaml                  recipients (age) и что шифровать
secrets/                    примеры Secret'ов (открытые) и *.enc.yaml (в git)
deploy.sh                   init_cluster | join_cluster | label | run | forward
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
cp secrets/observability.example.yaml secrets/observability.yaml
kubectl create secret docker-registry ghcr --docker-server=ghcr.io \
  --docker-username=<login> --docker-password=<PAT> \
  --dry-run=client -o yaml > secrets/ghcr.yaml
$EDITOR secrets/core.yaml secrets/node.yaml secrets/observability.yaml
sops -e secrets/core.yaml > secrets/core.enc.yaml
sops -e secrets/node.yaml > secrets/node.enc.yaml
sops -e secrets/observability.yaml > secrets/observability.enc.yaml
sops -e secrets/ghcr.yaml > secrets/ghcr.enc.yaml
```

`observability.yaml` содержит только пароль администратора Grafana.

Открытые `secrets/*.yaml` — в `.gitignore`, в git попадают только `*.enc.yaml`
и `*.example.yaml`. `ghcr.enc.yaml` один на все namespace: kustomize ставит
Secret в namespace того overlay, который его подключает.

## Образы из интернета

Сторонние образы kubelet тянет с Docker Hub при первом запуске пода. Загрузить
их заранее, не дожидаясь `ImagePullBackOff`:

```bash
./deploy.sh cache_images
```

Команда собирает список образов из `manifests/` (свои `ghcr.io/shirovpn/*`
пропускает) и делает `sudo k3s ctr -n k8s.io images pull` для каждого. Если
часть не скачалась — печатает их и выходит с ошибкой: значит на ноде сломан
DNS или egress, и лечить надо это, а не манифесты.

## Пересоздание кластера без пересборки

`k3s-uninstall.sh` удаляет `/var/lib/rancher/k3s`, поэтому вместе с кластером
исчезают все образы в containerd — и скачанные, и собранные локально.
Сохранить их до удаления:

```bash
./deploy.sh save_images      # -> /var/lib/shiro-k8s-images.tar
sudo /usr/local/bin/k3s-uninstall.sh
./deploy.sh init_cluster
./deploy.sh load_images      # секунды вместо сборки
```

Файл лежит вне `/var/lib/rancher`, поэтому переживает uninstall. Другой путь —
`IMAGE_CACHE=/path/to/images.tar ./deploy.sh save_images`.

Данные PVC при этом теряются: если в Postgres есть нужное, сначала дамп.

```bash
sudo k3s kubectl -n shiro exec deploy/postgres -- pg_dump -U shiro shiro \
  > ~/shiro-db-backup.sql
```

Восстановление после `init_cluster` (база пустая, миграции прогонит
init-контейнер):

```bash
sudo k3s kubectl -n shiro exec -i deploy/postgres -- psql -U shiro -d shiro \
  < ~/shiro-db-backup.sql
```

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
  только port-forward. Это единственный под с сетью хоста: без неё 51820/udp
  снаружи не работает.
- **bot без `hostNetwork`**: в pod-сети он доступен по Service `bot:8080`, и
  Caddy проксирует мини-приложение туда же. Сеть хоста нужна была только для
  локального деплоя, в ветке `dev` она возвращается.
- **Caddy включён**: держит 80/443 на хосте и обслуживает `WEBHOOK_DOMAIN`,
  `MINI_APP_DOMAIN` и панели под `ADMIN_DOMAIN`. `ADMIN_DOMAIN` — заглушка на
  `admin.example.com`: имени пока нет, поэтому все сайты стоят с
  `tls internal` (сертификат от собственного CA Caddy). Каждая панель — на
  своём поддомене, см. раздел «Доступ к панелям». Когда появится A-запись:
  вписать домен в `core-config` и убрать `tls internal`.
- **Redis без тома** (как в compose): результаты задач живут час, терять их
  не страшно.
- **CloudBeaver** — UI к Postgres, добавлен сверх compose (был в черновике
  `k8s`). Наружу не публикуется, доступ через port-forward.
- **Телеметрия** — отдельный namespace `observability`: otel-collector, jaeger,
  prometheus, elasticsearch, grafana. Конфиги взяты из
  `peerhub_wireguard_worker/tests`, дашборды скопированы в
  `manifests/observability/grafana/dashboards` и приезжают через
  `configMapGenerator`. Приложения шлют OTLP на
  `otel-collector.observability.svc.cluster.local:4317`; сейчас это умеет
  только `peerhub-wireguard-worker`, остальным сервисам нужна
  инструментация в их репозиториях.
- **Хранение телеметрии** — prometheus и elasticsearch на PVC, jaeger в памяти
  (трейсы теряются при рестарте пода, как в compose). Grafana без тома:
  дашборды и датасорсы приезжают из репозитория.
- **vm.max_map_count** — elasticsearch без него не стартует,
  `init_cluster` выставляет `262144` через sysctl.
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
- Диск: prometheus просит 2Gi, elasticsearch — 5Gi, плюс тома postgres,
  rabbitmq, caddy, cloudbeaver. Стек observability съедает примерно
  1.5–2 GiB RAM.
- `vm.max_map_count=262144` для elasticsearch. `init_cluster` выставляет его
  через sysctl, но после перезагрузки нужно закрепить в `/etc/sysctl.d/`.
- A-записи `WEBHOOK_DOMAIN`, `MINI_APP_DOMAIN` и `WG_HOST` — на этот сервер.
  `ADMIN_DOMAIN` пока заглушка и работает только через `tls internal`.
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
# только на ветке dev, до run: Application'ы ждут образы dev-* с
# imagePullPolicy: Never, без сборки поды уйдут в ErrImageNeverPull
./dev.sh build
./deploy.sh run --profile core
./deploy.sh run --profile observability
./deploy.sh run --profile peerhub-wg
```
На ветке `dev` порядок жёсткий: сначала `./dev.sh build` (он же ставит тег
`dev-*` в `overlays/dev/component`), потом `run`. На `main` сборка не нужна —
образы приезжают из ghcr.

`run --profile peerhub-wg` спросит `PEERHUB_ID` (предложит uuid), `COUNTRY`,
`SERVER_NAME`, `WG_HOST` и `WG_PORT` и запишет их в
`overlays/peerhub-wg/peerhub-config.yaml` — закоммитить и запушить до Sync.
На машине без публичного IP в `WG_HOST` вписать `0.0.0.0`: конфиги клиентов с
таким Endpoint не заработают, но стек и бот поднимутся.

Репозиторий публичный, доступ Argo CD настраивать не нужно: панель
сама склонирует его по `repoURL`. Нажать **Sync** у `core`, `peerhub-wg` и
`observability`. `init_cluster` берёт ключ из `SOPS_AGE_KEY_FILE` или
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
  `ADMIN_DOMAIN`, `STUB_PAYMENT`, `ADMIN_TELEGRAM_IDS`.
- `overlays/peerhub-wg/peerhub-config.yaml` — `PEERHUB_ID` (uuid предложит
  `run --profile peerhub-wg`), `COUNTRY`, `SERVER_NAME`, `WG_HOST`, `WG_PORT`.

Закоммитить и запушить в `main` — Argo тянет оттуда. Namespace'ы
`shiro`/`shiro-peerhub-wg` создаются синхронизацией, вручную их создавать не
нужно.

Проверки:

```bash
sudo k3s kubectl -n shiro get pods
sudo k3s kubectl -n shiro-peerhub-wg get pods
sudo k3s kubectl -n observability get pods
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

## Доступ к панелям

Caddy работает в pod-сети, поэтому Service-имена резолвятся его DNS'ом и
`kubectl port-forward` не нужен вообще. Каждая панель сидит на своём
поддомене `ADMIN_DOMAIN`, потому что под путём часть из них ломается.

```caddy
{$ADMIN_DOMAIN} {
        tls internal
        redir https://grafana.{$ADMIN_DOMAIN}{uri} 302
}

grafana.{$ADMIN_DOMAIN} {
        tls internal
        reverse_proxy grafana.observability.svc.cluster.local:3000
}

rabbitmq.{$ADMIN_DOMAIN} {
        tls internal
        reverse_proxy rabbitmq.shiro.svc.cluster.local:15672
}
```

Раздаются только панели со своим логином — Grafana, RabbitMQ, CloudBeaver,
wg-easy. Prometheus, Jaeger и Elasticsearch аутентификации не имеют, наружу
их не выставляем: они доступны через `./deploy.sh forward --all` и из
Grafana (там датасорсы на оба).

Подпуть (`admin.example.com/grafana/`) сознательно не используется: он
требует `GF_SERVER_SERVE_FROM_SUB_PATH` и `QUERY_BASE_PATH`, а `%(domain)s` в
Grafana подставляет `GF_SERVER_DOMAIN` без порта — port-forward тогда
редиректит на `http://localhost/grafana/` и всё ломается. С поддоменами
манифесты остаются ровно такими, как у upstream.

Локальная проверка без DNS — дописать имена в `/etc/hosts`:

```
127.0.0.1 grafana.admin.example.com rabbitmq.admin.example.com
127.0.0.1 cloudbeaver.admin.example.com wg-easy.admin.example.com
```

Браузер будет ругаться на неизвестный CA: сертификат подписан внутренним CA
Caddy (`/data/caddy/pki/authorities/local/root.crt` на PVC `caddy-data`).

Caddyfile приезжает через ConfigMap и смонтирован через `subPath`, поэтому при
правке конфига под надо пересоздать вручную:

```bash
sudo k3s kubectl -n shiro rollout restart deploy/caddy
```

Путь через port-forward остался и никуда не делся — он удобнее на ноутбуке,
где нет DNS и настоящего сертификата.
## Ветка dev: локальная сборка образов

`dev` — ветка для проверки изменений без новых релизов. Те же Application'ы,
только `targetRevision: dev`; overlay'и подключают
`overlays/dev/component`, который подменяет теги наших образов на `dev-*` и
ставит `imagePullPolicy: Never`.

Отличия от `main`, кроме тегов:

- `bot` снова с `hostNetwork: true` — на ноутбуке мини-приложение открывается
  через сеть хоста;
- `syncPolicy.automated.prune` — пуш в `dev` применяется без нажатия Sync;
- `scripts/shiro-k8s-netfilter.sh` и `dev.sh` есть только здесь.

`argocd/ksops-patch.yaml` одинаков в обеих ветках: host networking у
repo-server больше не нужен, кластерный DNS работает (см. раздел про VPN).

Образы собираются на машине с кластером, импортируются в containerd k3s и
никуда не публикуются:

```bash
./dev.sh pull                     # git pull в соседних репозиториях
./dev.sh build                    # собрать все три
./dev.sh build bot                # только бота
./dev.sh restart bot              # перезапустить без сборки
./dev.sh logs                     # логи main-api-worker, follow
./dev.sh status                   # Application'ы и поды
```

`build` собирает, делает `docker save | sudo k3s ctr -n k8s.io images import -`,
прописывает новый `dev-<дата>-<время>` в `overlays/dev/component`, коммитит и
пушит `dev`. Application'ы в этой ветке включены с `automated.prune`, поэтому
Argo CD сам замечает пуш за минуту (`timeout.reconciliation=60s`) и
перекатывает поды. Отдельного «задеплоить» нет: `build` и есть деплой.

`selfHeal` намеренно выключен: иначе Argo откатывал бы аннотацию от
`./dev.sh restart` и поды перезапускались бы по кругу.

Если в панели видно `ErrImageNeverPull` с тегом `dev-0`, значит образ ещё не
собран на этой машине — запустите `./dev.sh build` (или `build <component>`
для одного сервиса). Тег `dev-0` в `overlays/dev/component` — начальная
заглушка, её заменяет первая же сборка.

### Если VPN ломает DNS и Sync

Симптом: поды падают с `Temporary failure in name resolution`, а Argo пишет

```
error resolving repo revision: rpc error: code = Unavailable desc = dns:
A record lookup error: lookup argocd-repo-server on 10.43.0.10:53:
read udp 10.42.0.12:44340->10.43.0.10:53: read: connection refused
```

Причина в том, как v2raya ставит правила. В таблице `inet v2raya`:

```
chain tp_pre {
        type nat hook prerouting priority dstnat - 5;
        meta l4proto { tcp, udp } th dport 53 jump dns_redirect
}
chain dns_redirect {
        meta mark & 0x00000080 == 0x00000080 return
        meta l4proto { tcp, udp } th dport 53 redirect to :52353
}
```

Правило ловит **любой** пакет на порт 53 и перенаправляет его на
`127.0.0.1:52353`. В сетевом namespace пода такого порта нет, поэтому запрос к
CoreDNS умирает. Обратите внимание: в `tp_rule` есть исключения для `veth*` и
`br-*`, а в `dns_redirect` их нет — поэтому TCP до Postgres работает, а DNS
нет. Правки RoutingA на это не влияют: правило не смотрит на адрес.

Чинится двумя шагами, оба на машине с кластером.

**1. Пометить трафик кластера как «не проксировать».** v2raya пропускает
пакеты с меткой `0x80`, поэтому:

```bash
sudo install -m 755 scripts/shiro-k8s-netfilter.sh /usr/local/sbin/
```

и юнит, который применяет правила после старта v2raya:

```ini
# /etc/systemd/system/shiro-k8s-netfilter.service
[Unit]
Description=Keep k3s pod/service traffic out of v2raya transparent proxy
After=v2raya.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/shiro-k8s-netfilter.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now shiro-k8s-netfilter
```

Правила живут в собственной таблице `inet shiro_k8s`, поэтому перезапуск
v2raya их не сносит. Если v2raya обновит схему правил, скрипт можно
перезапустить руками.

**2. Дать CoreDNS нормальный upstream.** k3s копирует `/etc/resolv.conf` ноды
в под CoreDNS (`dnsPolicy: Default`), а там `nameserver 127.0.0.1` — то есть
сам CoreDNS. Внешние имена не резолвятся даже после шага 1. Отдельный файл
только для kubelet:

```bash
echo 'nameserver 192.168.1.1' | sudo tee /etc/resolv.k8s.conf
sudo tee /etc/rancher/k3s/config.yaml <<'EOF'
kubelet-arg:
  - "resolv-conf=/etc/resolv.k8s.conf"
EOF
sudo systemctl restart k3s
```

`192.168.1.1` — роутер; подойдёт любой резолвер, доступный из pod-сети.
Хостовый `/etc/resolv.conf` при этом не трогается, v2raya продолжает им
управлять.

Проверка:

```bash
./dev.sh diagnose        # маршруты, CoreDNS, endpoints, PVC, образы
```

и запрос изнутри кластера — подставьте тег, который сейчас в
`overlays/dev/component`:

```bash
sudo k3s kubectl -n shiro run dnstest --rm -i --restart=Never \
  --image=ghcr.io/shirovpn/main_api_worker:dev-20261114-225930 \
  -- /venv/bin/python -c 'import socket;print(socket.gethostbyname("postgres"))'
```

Должны резолвиться и `postgres` (внутреннее имя), и `api.telegram.org`
(внешнее).

Что нужно на машине с кластером:

- Docker или Podman (`CONTAINER_ENGINE=podman`).
- Репозитории приложений рядом с `k8s_new`: `../main_api_worker`, `../BotV2`,
  `../peerhub_wireguard_worker`. Другие пути — через `MAIN_API_WORKER_DIR`,
  `BOT_DIR`, `WG_WORKER_DIR`.
- Собирать на той машине, где крутятся поды: образ живёт только в containerd
  этой ноды, `imagePullPolicy: Never` с другой ноды его не достанет.

### Цикл работы над фичей или фиксом

1. Правите код в `../main_api_worker` (или `../BotV2`, `../peerhub_wireguard_worker`).
2. `./dev.sh build main-api-worker` — сборка, импорт, новый тег, пуш в `dev`.
3. Через минуту Argo CD перекатывает поды. Проверить: `./dev.sh status`.
4. Логи: `./dev.sh logs` (по умолчанию `main-api-worker`, можно `logs bot`,
   `logs peerhub-wireguard-worker`). Это `kubectl logs -f` по всем подам
   компонента сразу, с префиксом имени пода.
5. Панели: `./deploy.sh forward --all`, потом `./deploy.sh forward stop`.
6. Когда всё работает — перенести изменения приложений в их репозитории,
   собрать релиз, обновить теги в `manifests/*` на `main` и запушить `main`.

Если поменялись только манифесты `k8s_new`, шаги 1–2 не нужны: коммит в `dev`
и Sync. Если поменялись зависимости или Dockerfile — только `build`, без
`restart`.

Возврат на релизные образы: в `argocd/*.yaml` вернуть `targetRevision: main`
и применить Application'ы заново (`./deploy.sh run --profile core`).

## Панели

Одна команда поднимает панели на `127.0.0.1`; процессы живут в фоне, pid'ы в
`/tmp/shiro-forward`, логи рядом.

```bash
./deploy.sh forward            # только панели с паролем
./deploy.sh forward grafana    # одна конкретная
./deploy.sh forward --all      # вместе с jaeger, prometheus, elasticsearch
./deploy.sh forward stop       # погасить все
```

Каждый туннель под присмотром супервизора: `kubectl port-forward` завершается,
когда под пересоздали (любой rollout или Sync с новым тегом), супервизор через
2 секунды подключается к новому поду. В `grafana.log` это видно строкой
`forward exited, reconnecting`. Без этого панель молча умирала до следующего
ручного запуска.

| Порт | Что | Логин |
|---|---|---|
| 18080 | Argo CD | admin, пароль печатает `init_cluster` |
| 18081 | Grafana | admin, пароль `GRAFANA_ADMIN_PASSWORD` из `observability-secret` |
| 18085 | RabbitMQ management | core, пароль `RABBITMQ_PASSWORD` из `shiro-secret` |
| 18086 | CloudBeaver | admin, пароль `CB_ADMIN_PASSWORD` из `shiro-secret` |
| 18087 | wg-easy UI | admin, пароль `WG_EASY_PASSWORD` из `node-secret` |

Без своего пароля идут только три панели, поэтому по умолчанию они не
поднимаются — смотреть трейсы и метрики можно в Grafana, где есть датасорсы
Jaeger и Elasticsearch.

| Порт | Что | Только с `--all` |
|---|---|---|
| 18082 | Jaeger UI | да |
| 18083 | Prometheus | да |
| 18084 | Elasticsearch | да |

В CloudBeaver Postgres подключается как host `postgres`, база `shiro`,
пользователь `shiro`.

CI собирает `manifests/core`, `manifests/node` и `manifests/observability`;
overlay'и не собираются, потому что для них нужен приватный ключ.

## Ветки

- `main` — то, что стоит на прод-сервере: Argo CD тянет `targetRevision: main`.
- `dev` — те же манифесты с локальной сборкой образов; Application'ы в этой
  ветке указывают на `targetRevision: dev`. Подробности в README ветки `dev`.

Перед деплоем в прод проверьте, что `argocd/*.yaml` смотрят на `main`:
`grep targetRevision argocd/*.yaml`.
