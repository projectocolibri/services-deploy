<!-- Banner: add docs/banner.png and replace this comment with ![Services deploy](docs/banner.png) -->

# Services deploy

**Self-hosted MySQL and PostgreSQL with replicas, point-in-time backups, off-site copies, VPN, HTTPS gateway and monitoring — one repository, one `.env`, one `docker compose up -d`.**

![Docker Compose](https://img.shields.io/badge/Docker%20Compose-v2.24%2B-2496ED?logo=docker&logoColor=white)
![MySQL](https://img.shields.io/badge/Percona%20Server-8.4-4479A1?logo=mysql&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17-4169E1?logo=postgresql&logoColor=white)
![PMM](https://img.shields.io/badge/PMM-3-F05A28?logo=grafana&logoColor=white)
![WireGuard](https://img.shields.io/badge/WireGuard-VPN-88171A?logo=wireguard&logoColor=white)
![nginx](https://img.shields.io/badge/nginx-gateway-009639?logo=nginx&logoColor=white)

```
                           Internet
                  ┌───────────┴───────────┐
              UDP 51820              TCP 80 / 443
            ┌─────▼─────┐           ┌─────▼─────┐
            │    VPN    │           │   HTTP    │
            │ WireGuard │           │   nginx   │
            └─────┬─────┘           └─────┬─────┘
                  │ admins                │ public apps
 ─────────────────┴──── internal network ─┴─────────────────────────
  mysql-primary     ── replication ──►  mysql-replica     (read only)
  postgres-primary  ── streaming ────►  postgres-replica  (read only)
  backups ──► off-site (rclone)    PMM · Dozzle · Portainer · admin panels
```

## ✨ Key features

- **One file per server.** Every setting lives in `.env`; `COMPOSE_PROFILES` decides what a server runs. All servers share the same committed files.
- **Replicas out of the box.** Both databases clone their primary on first start and replicate continuously (GTID for MySQL, streaming for PostgreSQL).
- **Point-in-time recovery.** XtraBackup full + incremental and pgBackRest full + differential, with binary logs / WAL. Restore any moment of the last 14 days into a temporary server.
- **Backups where you want them.** Take them on the primary's server, the replica's server, or both, with no load on the primary when the replica does it.
- **Off-site copies that never delete.** rclone to Google Drive, S3, SFTP and 70+ others, encrypted, with old versions kept.
- **Private by default.** Only the VPN and the HTTP gateway face the internet; everything else is reached through WireGuard.
- **Monitoring and alerts provisioned.** PMM dashboards, Query Analytics, and alert rules (databases down, replication, WAL archiving, disk, CPU, memory) created on startup.
- **Storage you choose.** Each service keeps its data in a Docker volume or in any folder you set.

## 🧱 Tech stack

| Layer | Technology | Role |
|---|---|---|
| Orchestration | **Docker Compose** v2.24+ (`include`, profiles) | One project, one network, per-server roles |
| Databases | **Percona Server for MySQL 8.4**, **Percona Distribution for PostgreSQL 17** | Primaries and read-only replicas |
| Backups | **Percona XtraBackup 8.4**, **pgBackRest 2.59**, **supercronic** | Physical backups, log archiving, schedules |
| Off-site | **rclone** | Encrypted copies to cloud or remote storage |
| Gateway | **WireGuard** (linuxserver/wireguard), **nginx** | Private access, TLS termination for apps |
| Monitoring | **PMM 3** (Grafana, VictoriaMetrics, ClickHouse), **cAdvisor**, **Dozzle**, **Portainer** | Metrics, alerts, logs, container management |
| Admin | **phpMyAdmin**, **pgAdmin 4** | Database UIs through the VPN |
| Apps | **Java** (own JRE), **Node.js 24** (Angular SSR, Express) | Example application containers |
| Scripting | **Bash** | Entrypoints, backups, restores |

## 🚀 Quick start

**Prerequisites**

- **Docker Engine** with **Docker Compose v2.24** or later
- **Linux** server (Ubuntu, Alpine); **Docker Desktop** works for development
- **2+ CPU cores** and **4+ GB RAM** (PMM Server)

```bash
git clone <repository> services-deploy
cd services-deploy
cp .env.example .env          # every setting, documented; edit passwords and VPN_HOST
docker compose config --quiet # validate the configuration
```

## ▶️ Basic usage

```bash
docker compose up -d
docker compose ps
```

The replicas clone their primary on the first start: allow a minute (the MySQL replica restarts once after cloning). Before going to production, replace every default password in `.env`, set **`VPN_HOST`** and go through the [production checklist](#production-checklist).

---

## 📚 Guide

1. [Technical architecture](#architecture)
2. [Environment configuration](#configuration)
3. [Development workflow](#development)
4. [Testing and validation](#testing)
5. [Practical examples](#examples)
6. [Troubleshooting](#troubleshooting)
7. [Operations](#operations)
8. [Production checklist](#production-checklist)

---

<a id="architecture"></a>

## 🏗️ 1. Technical architecture

### One project, many roles

- The root **`compose.yaml`** includes every stack (`gateway/`, `monitoring/`, `databases/`, `sync/`, `apps/`) and declares the shared network. Every folder with a `compose.yaml` is a stack; stacks list their sub-stacks with `include`.
- **Every service has its own Compose profile.** `COMPOSE_PROFILES` in `.env` lists the services of *this* server, and `docker compose up -d` starts exactly those. All servers run the same committed files; only `.env` differs.
- **No service depends on another stack.** Each one waits for what it needs by itself (entrypoint wrappers poll their dependencies), so any subset of profiles works.

### Network and access

See the diagram at the top.

- Only the **VPN** (`51820/udp`) and the **HTTP gateway** (`80`, `443`) are published. Everything else is internal and reached through the VPN by service name (`http://pmm-server:8080`).
- **Across servers**, a replica server joins the VPN host as a WireGuard peer. The VPN host container has a fixed address (**`VPN_DNS_IP`**) whose DNS answers with the VPN host's service names. Replicas and backups use it as their DNS server: Docker DNS answers local names first and forwards the rest (e.g. `mysql-primary`) through the tunnel.

### Data flow

```
 primary ──replication──► replica
    │                        │
    │ binlog / WAL           │ binlog / WAL (the replica's own)
    ▼                        ▼
 *-backup-primary        *-backup-replica        full + incremental/differential
 (primary's server)      (replica's server)      + continuous logs, 14 days
    │                        │
    └────────► sync (rclone) ◄┘ ──► off-site storage (encrypted, never deletes)

 every server ──► pmm-client + cAdvisor ──► PMM Server ──► alert rules ──► email / Slack
```

### Runtime lifecycle

1. **Primaries** start through entrypoint wrappers that create application users and databases on every start (`*_DATABASES`), and install what backups need (MySQL page tracking).
2. **Replicas** clone their primary on the first start (`CLONE INSTANCE` / `pg_basebackup`), then replicate.
3. **Backup containers** wait for their local server, take a full backup if none exists, then run their schedule with **supercronic**. PostgreSQL archives WAL itself (`archive_command` → pgBackRest); MySQL binary logs are streamed by `mysqlbinlog`.
4. **PMM Server** starts, then its entrypoint creates the Slack contact point (if enabled) and every missing alert rule of `monitoring/pmm/alerting/rules/`.
5. **pmm-client** registers the node, cAdvisor and, with `MONITOR_DATABASES=true`, the running databases.

---

<a id="configuration"></a>

## ⚙️ 2. Environment configuration

### 2.1 The `.env` file

- **`.env`** at the root is the only settings file. Compose loads it automatically and passes it to every stack. It is not committed: each server has its own.
- **`.env.example`** is the committed template: development defaults and a comment for every variable.
- **`COMPOSE_ENV_FILES` must not be set** in the shell, or Compose reads the files it names instead of `.env`.
- When `.env.example` gets a new variable, copy it into each server's `.env`. Compare them with `diff .env.example .env`.
- **`TZ`**: UTC is recommended; PMM, Grafana and Dozzle show browser time anyway. Images without time zone data (pmm-client, cAdvisor, Dozzle, the MySQL backups) stay on UTC; PostgreSQL keeps the zone it was initialized with.

| Section of `.env.example` | Contents |
|---|---|
| 1. Project | **`PROJECT_NAME`**: prefix of containers and volumes. Renaming it orphans existing volumes. |
| 2. Profiles | **`COMPOSE_PROFILES`**: what this server runs |
| 3. Network | **`NETWORK_NAME`**, **`NETWORK_SUBNET`** (also routed through the VPN), **`VPN_DNS_IP`** |
| 4. Services | `TZ` and storage, then one block per service: VPN host, VPN client, HTTP, PMM Server, PMM client, Dozzle, Portainer, MySQL, PostgreSQL, apps, sync |

### 2.2 Values to set for production

| Service | Variables |
|---|---|
| Gateway | **`VPN_HOST`**, **`VPN_PEERS`** |
| MySQL | `MYSQL_ROOT_PASSWORD`, `MYSQL_USER`, `MYSQL_USER_PASSWORD`, `MYSQL_REPLICATION_PASSWORD`, `MYSQL_MONITOR_PASSWORD`, `MYSQL_DATABASES` |
| PostgreSQL | `POSTGRES_PASSWORD`, `POSTGRES_REPLICATION_PASSWORD`, `POSTGRES_MONITOR_PASSWORD`, `POSTGRES_APP_USER`, `POSTGRES_APP_PASSWORD`, `POSTGRES_DATABASES`, `POSTGRES_ADMIN_EMAIL`, `POSTGRES_ADMIN_PASSWORD` |
| Monitoring | `PMM_ADMIN_PASSWORD`, `PORTAINER_ADMIN_PASSWORD`, `SMTP_*`, `SLACK_WEBHOOK_URL` |
| Storage | `*_DATA_VOLUME`, `*_BACKUP_VOLUME` (see [2.4](#24-storage)) |
| Off-site copies | `SYNC_DESTINATION`, `SYNC_VOLUMES`, `SYNC_DATA_DIR`, `SYNC_ENCRYPT_PASSWORD`, `SYNC_ENCRYPT_SALT` |

Passwords and users are applied when a data volume is **first initialized**: changing them later does not change an existing database. The PMM client uses the same `MYSQL_MONITOR_*` and `POSTGRES_MONITOR_*` accounts the primaries create.

### 2.3 Server roles (profiles)

| Group | Profile | Service |
|---|---|---|
| Gateway | `vpn-host` | WireGuard server (on the server with the primaries) |
| | `vpn-client` | WireGuard peer of another server's VPN host |
| | `http` | nginx gateway |
| Monitoring | `pmm` | PMM Server |
| | `metrics` | PMM client + cAdvisor |
| | `logs` | Dozzle |
| | `portainer` | Portainer |
| MySQL | `mysql-primary` | Primary, read/write |
| | `mysql-replica` | Read-only replica |
| | `mysql-backup-primary` | Backups of the primary (on its server) |
| | `mysql-backup-replica` | Backups of the replica (on its server) |
| | `mysql-admin` | phpMyAdmin |
| PostgreSQL | `postgres-primary` | Primary, read/write (also starts `postgres-backup-server`) |
| | `postgres-replica` | Read-only hot standby |
| | `postgres-backup-primary` | Backups of the primary (on its server) |
| | `postgres-backup-replica` | Backups of the replica (on its server) |
| | `postgres-admin` | pgAdmin |
| Apps | `java-service-example`, `angular-app-example`, `nodejs-app-example` | App examples |
| Sync | `sync` | Copies volumes (the backups) off-site with rclone |

```bash
# One server with everything (default), backups of the replicas
COMPOSE_PROFILES=vpn-host,http,pmm,metrics,logs,portainer,mysql-primary,mysql-replica,mysql-backup-replica,mysql-admin,postgres-primary,postgres-replica,postgres-backup-replica,postgres-admin

# Two servers: the primaries...
COMPOSE_PROFILES=vpn-host,http,pmm,metrics,logs,portainer,mysql-primary,mysql-admin,postgres-primary,postgres-admin
# ...and the replicas with their backups, copied off-site
COMPOSE_PROFILES=vpn-client,mysql-replica,mysql-backup-replica,postgres-replica,postgres-backup-replica,sync

# Backups on both servers (two independent sets): add to the primaries' list
...,mysql-backup-primary,postgres-backup-primary,sync

# Only MySQL, backups of the primary
COMPOSE_PROFILES=mysql-primary,mysql-backup-primary
```

- After changing roles, `docker compose up -d` starts the new services.
- Commands only see active profiles: stop a removed role explicitly (`docker compose --profile mysql-admin down`, or `--profile '*'` for all).
- With no profile set, Compose starts nothing (`no service selected`).
- The apps are not in the default list: add them where they run.

### 2.4 Storage

Every service keeps its data in a **Docker volume** by default. Set its variable to an **absolute folder path** to keep the data there instead.

| Variable | Default volume | Data | Folder owner (Linux) |
|---|---|---|---|
| `MYSQL_PRIMARY_DATA_VOLUME` | `mysql-data` | MySQL primary | `1001:1001` |
| `MYSQL_REPLICA_DATA_VOLUME` | `mysql-replica-data` | MySQL replica | `1001:1001` |
| `MYSQL_PRIMARY_BACKUP_VOLUME` | `mysql-primary-backup` | MySQL backups of the primary | `root` |
| `MYSQL_REPLICA_BACKUP_VOLUME` | `mysql-replica-backup` | MySQL backups of the replica | `root` |
| `POSTGRES_PRIMARY_DATA_VOLUME` | `postgres-data` | PostgreSQL primary | `26:26` |
| `POSTGRES_REPLICA_DATA_VOLUME` | `postgres-replica-data` | PostgreSQL replica | `26:26` |
| `POSTGRES_PRIMARY_BACKUP_VOLUME` | `postgres-primary-backup` | pgBackRest repository of the primary | `26:26` |
| `POSTGRES_REPLICA_BACKUP_VOLUME` | `postgres-replica-backup` | pgBackRest repository of the replica | `26:26` |
| `POSTGRES_ADMIN_DATA_VOLUME` | `pgadmin-data` | pgAdmin | `5050:0` |
| `PMM_DATA_VOLUME` | `pmm-data` | PMM Server | `1000:0` |
| `PORTAINER_DATA_VOLUME` | `portainer-data` | Portainer | `root` |
| `JAVA_SERVICE_EXAMPLE_DATA_VOLUME` | `java-service-example-data` | Java service example | `1000:1000` |

```bash
# .env — everything of this server under /srv/mydata (c:/mydata on Windows)
POSTGRES_PRIMARY_DATA_VOLUME=/srv/mydata/databases/primary/postgres/data
POSTGRES_PRIMARY_BACKUP_VOLUME=/srv/mydata/databases/primary/postgres/backup
MYSQL_PRIMARY_DATA_VOLUME=/srv/mydata/databases/primary/mysql/data
```

- **Linux (Ubuntu, Alpine):** create each folder before the first start, owned by its service's user:

  ```bash
  sudo install -d -o 26 -g 26 /srv/mydata/databases/primary/postgres/data
  sudo install -d -o 26 -g 26 /srv/mydata/databases/primary/postgres/backup
  sudo install -d -o 1001 -g 1001 /srv/mydata/databases/primary/mysql/data
  ```

- **Docker Desktop on Windows:** folders such as `c:/mydata/...` work for everything **except PostgreSQL data** (`POSTGRES_PRIMARY_DATA_VOLUME`, `POSTGRES_REPLICA_DATA_VOLUME`): PostgreSQL requires a data folder only its user can read, which Windows folders cannot provide. Keep those in volumes. Windows folders are slower than volumes.
- **Socket volumes** (`postgres-socket`, `postgres-replica-socket`) hold no data and are not configurable.
- **Moving existing data:** a new value starts the service empty. Stop the services using it, copy the data, set the variable, start again:

  ```bash
  docker compose stop postgres-db postgres-backup-primary postgres-backup-server
  docker run --rm -v <PROJECT_NAME>_postgres-data:/from \
      -v /srv/mydata/databases/primary/postgres/data:/to alpine cp -a /from/. /to/
  # set POSTGRES_PRIMARY_DATA_VOLUME=/srv/mydata/databases/primary/postgres/data in .env
  docker compose up -d
  ```

### 2.5 VPN

**VPN host** (server with the primaries) — private access to every internal service:

1. Set **`VPN_HOST`** (public IP or domain) and list the users in **`VPN_PEERS`** (comma separated, letters and digits only).
2. Start the stack. Each user gets a config and a QR code in `gateway/vpn/host/config/peer_<name>/`.
3. Import `peer_<name>.conf` into the WireGuard app, or scan `peer_<name>.png`.

Only the VPN subnet and the internal network go through the tunnel. After changing `VPN_HOST`, delete `gateway/vpn/host/config/peer_*` to regenerate client configs.

**VPN client** (replicas on another server) — the tunnel comes up on the host network, so its containers reach the primaries with no other change:

1. On the VPN host: add a peer, e.g. `VPN_PEERS=admin,replica1`, run `docker compose up -d vpn`, and copy `gateway/vpn/host/config/peer_replica1/peer_replica1.conf` to the new server (it holds that server's private key).
2. On the replica server (a clone of this repository): save it as `gateway/vpn/client/config/peer.conf`.
3. `cp .env.example .env` and use a **different subnet**, e.g. `NETWORK_SUBNET=172.31.0.0/16` (the client refuses overlapping routes).
4. Set the profiles, e.g. `vpn-client,mysql-replica,mysql-backup-replica,postgres-replica,postgres-backup-replica,sync`, and remove `*-replica` / `*-backup-replica` from the VPN host's list.
5. Use the **same database passwords and `VPN_DNS_IP`** as the VPN host.
6. `docker compose up -d`; check `docker compose ps vpn-client` is healthy and the replication state ([section 7](#operations)).

The replica server needs no open inbound port. Not covered yet: the VPN host's admin panels and PMM cannot reach containers on the replica server, and `pmm-client-register.sh` only registers databases on its own network.

### 2.6 HTTP gateway

TLS ends at nginx; every service behind it serves plain HTTP on its **`*_PORT`** (8080 by default). Requests for unknown hosts are refused.

**Public app**

1. Copy `gateway/http/conf.d/app.conf.example` to `<app>.conf`; set the domain and `proxy_pass http://<service>:<port>`.
2. Put the certificate in `gateway/http/certs/<domain>/fullchain.pem` and `privkey.pem`.
3. Reload: `docker compose exec http nginx -s reload`.

**Internal sites** (e.g. `https://pmm.monitor.example.lan`)

1. Copy `gateway/http/conf.d/internal.conf.example` to `<name>.conf` and replace `example.lan`. Its map lists one host name per service on port 8080; update a line if you changed that service's `*_PORT` (nginx does not read `.env`).
2. Issue a certificate from the internal CA (created on the first run):

   ```bash
   cd gateway/http
   ./internal-ca.sh example.lan '*.apps.example.lan' '*.mysql.example.lan' \
     '*.postgres.example.lan' '*.monitor.example.lan'
   ```

   Install `gateway/http/certs/internal-ca/ca.crt` as a trusted root CA on every client. **Never share `ca.key`.**
3. Point the names at this server in your internal DNS (or the VPN clients' hosts file), then reload nginx.

Only private networks (LAN, VPN, Docker) are allowed on internal sites.

### 2.7 Databases

| Engine | Primary (read/write) | Replica (read only) |
|---|---|---|
| MySQL (Percona Server 8.4) | `mysql-primary:3306` | `mysql-replica:3306` |
| PostgreSQL (Percona Distribution 17) | `postgres-primary:5432` | `postgres-replica:5432` |

- **Apps connect by role alias** (`*-primary`, `*-replica`), never by service name.
- **MySQL**: the replica clones the primary (`CLONE INSTANCE`), then follows it with GTID replication under `super_read_only`.
- **PostgreSQL**: the replica clones the primary (`pg_basebackup`), then streams its WAL as a hot standby.
- Replication is asynchronous. **A replica is not a backup**: it replays mistakes within seconds.

**Application databases** are created by the primary on every start; existing ones are never changed or dropped.

| | MySQL | PostgreSQL |
|---|---|---|
| Databases | **`MYSQL_DATABASES`** (empty: none) | **`POSTGRES_DATABASES`** (empty: none) |
| Owner / grants | all privileges to `MYSQL_USER` | owned by `POSTGRES_APP_USER`, created if missing |
| Names | lowercase, digits, `_`; `app%` is a grant-only pattern | lowercase, digits, `_` |

Fixed at initialization (a new volume is needed to change them): MySQL **`--lower-case-table-names=1`** (must match on both servers), PostgreSQL **`--encoding=UTF8 --locale=C.UTF-8`**.

**Admin panels**: phpMyAdmin (`http://mysql-admin:8080`) and pgAdmin (`http://postgres-admin:8080`) list the servers in `MYSQL_ADMIN_HOSTS` / `POSTGRES_ADMIN_HOSTS`.

### 2.8 Backups

Enable a backup profile on the server where the backup should run. Each side backs up **only the server on its own machine, into its own storage**: with both sides you get two independent sets.

| | MySQL (`databases/mysql/backup`) | PostgreSQL (`databases/postgres/backup`) |
|---|---|---|
| Profiles | `mysql-backup-primary`, `mysql-backup-replica` | `postgres-backup-primary`, `postgres-backup-replica` |
| Tool | Percona XtraBackup, zstd | pgBackRest, zstd |
| Schedule | full **`MYSQL_BACKUP_FULL_SCHEDULE`** (Sun 02:00), incremental **`MYSQL_BACKUP_INCREMENTAL_SCHEDULE`** (other days), UTC | full **`POSTGRES_BACKUP_FULL_SCHEDULE`** (Sun 01:00), differential **`POSTGRES_BACKUP_DIFF_SCHEDULE`** (other days), `TZ` |
| Point in time | binary logs, streamed continuously (`mysqlbinlog`) | WAL, archived by PostgreSQL at least every minute while there are writes |
| Verification | decompress and prepare a copy of the chain | `pgbackrest verify` |
| Retention | **`MYSQL_BACKUP_RETENTION_DAYS`** (14) | **`POSTGRES_BACKUP_RETENTION_DAYS`** (14) |
| Storage | `MYSQL_*_BACKUP_VOLUME`: `chains/`, `binlog/` | `POSTGRES_*_BACKUP_VOLUME`: pgBackRest repository |

- **First start:** a full backup at once, then the schedule. An incremental/differential without a full backup is taken as full.
- **Incrementals (MySQL)** copy pages changed since the previous backup; both servers install **page tracking** (`component_mysqlbackup`) so only changed pages are read. **Differentials (PostgreSQL)** copy files changed since the last full.
- **Retention:** any moment of the last N days stays restorable; older backups and the logs only they need are removed. The newest is never removed.
- **Replica side, MySQL:** the replica's own binary logs carry the primary's GTIDs; nothing is needed from the primary.
- **Replica side, PostgreSQL:** the standby archives the WAL it receives (`archive_mode=always`). pgBackRest still starts and stops each backup on the primary, through **`postgres-backup-server`** (TLS, port 8432, runs with `postgres-primary`). It creates the TLS certificates in `databases/postgres/backup/certs/` on its first start. On one server, nothing else is needed. With the replica elsewhere, copy three files; `postgres-backup-replica` waits for them:

  ```bash
  # from the primary's server to the replica's server
  scp databases/postgres/backup/certs/{ca.crt,client.crt,client.key} \
      replica-server:services-deploy/databases/postgres/backup/certs/
  ```

  To replace them: delete every file in `certs/` on the primary's server, `docker compose restart postgres-backup-server`, copy again, `docker compose restart postgres-backup-replica`.
- **Health checks:** unhealthy until the first backup exists, and when the last backup failed, the MySQL binlog stream stopped, or PostgreSQL's last WAL archive attempt failed.
- **Recreated server** (new data volume): MySQL detects the new `server_uuid`, takes a full backup and keeps the old chains apart. pgBackRest refuses another cluster's repository (stanza-create keeps retrying): copy it off-site if needed, then delete it ([section 7](#operations)).
- Give the backups enough disk: put `*_BACKUP_VOLUME` on a folder of a separate disk.

**Off-site copies (`sync`)** — rclone copies what **`SYNC_VOLUMES`** lists to **`SYNC_DESTINATION`**, once at start and then on **`SYNC_SCHEDULE`** (05:00). Run one per server with backups, each with its own destination folder.

- **Never deletes:** expired files stay on the destination; a changed file's previous version moves to `_versions/<date>/`.
- **`SYNC_MAX_AGE`** (`90d`) deletes older files from the destination. Keep it well above the retention plus the time between full backups.
- **`SYNC_ENCRYPT_PASSWORD`** / **`SYNC_ENCRYPT_SALT`** encrypt contents and names. Store them outside these servers: without them nothing can be read back.
- **What to copy:** volume names or folders (the same values as the storage variables; default `${MYSQL_REPLICA_BACKUP_VOLUME},${POSTGRES_REPLICA_BACKUP_VOLUME}`). Folders must be inside **`SYNC_DATA_DIR`** (their common parent, e.g. `/srv/mydata`).
- **Set up the remote** once per server (e.g. Google Drive named `gdrive`). Without a browser, answer `n` to "Use web browser to automatically authenticate?". The config is stored in `sync/rclone/` (not committed):

  ```bash
  docker compose run --rm sync config
  ```

### 2.9 Monitoring and alerts

| Tool | What it shows | URL (through the VPN) |
|---|---|---|
| **PMM** | Server resources, MySQL / PostgreSQL dashboards, replication, Query Analytics, containers, alerts | `http://pmm-server:8080` (user `admin`) |
| **Dozzle** | Live logs of every container | `http://dozzle:8080` |
| **Portainer** | Containers, images, volumes, networks; start/stop, console, stats | `http://portainer:8080` (user `admin`) |

- The PMM client registers the node (its hostname) and `cadvisor-<hostname>`; with **`MONITOR_DATABASES=true`** it also registers the running databases. Restart `pmm-client` to register a database started later.
- Portainer has full control of Docker. Change the deployment in this repository: `docker compose up -d` replaces containers edited in Portainer. Its `admin` password comes from `PORTAINER_ADMIN_PASSWORD` on the first start only (12+ characters).

| Alert channel | `.env` | Result |
|---|---|---|
| Email | **`ALERT_EMAIL_ENABLED=true`** and `SMTP_*` | PMM can send email; create the contact point in the UI |
| Slack | **`ALERT_SLACK_ENABLED=true`** and `SLACK_WEBHOOK_URL` | Contact point **Slack** created on start (read-only in the UI) |

Restart `pmm-server` after changing them, then route alerts in **Alerting → Notification policies** and use **Test** on the contact point. Before setting `ALERT_SLACK_ENABLED=false`, remove Slack from the policies; otherwise it is kept and a warning is logged.

**Alert rules** in `monitoring/pmm/alerting/rules/` are created on every start **if their `uid` does not exist yet**, in the folder **Custom alerts**, and stay editable in the UI.

| Rule | Fires when | For | Severity |
|---|---|---|---|
| MySQL down / PostgreSQL down | PMM cannot connect to the server | 2m | critical |
| MySQL replication stopped | replica I/O or SQL thread not running | 2m | critical |
| MySQL / PostgreSQL replica lag | replica more than 5 minutes behind | 5m | warning |
| PostgreSQL WAL archiving failing | `archive_command` keeps failing | 10m | critical |
| Disk almost full | less than 10% free | 10m | warning |
| High CPU | CPU more than 90% busy | 15m | warning |
| High memory | less than 10% available (free + reclaimable cache) | 10m | warning |
| Network errors | more than 1 errored packet per second on an interface | 15m | warning |
| Container restarting | more than 2 restarts in 15 minutes | — | warning |

There is no network throughput rule: normal varies too much (backups and syncs use all the bandwidth they get). Each rule has a **`severity`** label for routing; alerts go to the default contact point until a policy says otherwise.

---

<a id="development"></a>

## 🛠️ 3. Development workflow

### 3.1 Directory map

```
.env.example                 every setting, documented (copy to .env)
compose.yaml                 includes every stack, defines the network
gateway/
  vpn/host/                  WireGuard server (server with the primaries)
  vpn/client/                WireGuard peer for replica-only servers
  http/                      nginx: conf.d/, certs/, internal-ca.sh
monitoring/
  pmm/                       PMM Server: dashboards/Custom/, alerting/ (Slack, rules/)
  client/                    PMM client, cAdvisor, custom-queries/
  logs/                      Dozzle
  portainer/                 Portainer
databases/
  mysql/
    master/                  primary (mysql-db): entrypoint, init script
    replica/                 replica (mysql-replica-db): clone + replication
    admin/                   phpMyAdmin
    backup/                  XtraBackup image, mysql-backup.sh, mysql-restore.sh
  postgres/
    master/                  primary (postgres-db): entrypoint, init script
    replica/                 replica (postgres-replica-db): clone + streaming
    admin/                   pgAdmin
    backup/                  pgBackRest image, postgres-backup.sh, postgres-restore.sh, certs/
sync/                        rclone image, sync.sh, rclone/ (remote config)
apps/
  java-service-example/      Java export + Linux JRE (source/, jre.tar.gz)
  angular-app-example/       Angular SSR build run by Node.js (source/)
  nodejs-app-example/        Node.js app, dependencies installed in the image (source/)
```

### 3.2 Repository conventions

- **Header on every file**: `Purpose`, `Role`, `Prerequisites`, `Variables` — keep it current when you change a file.
- **One service, one profile.** Add the profile to the tables in `.env.example` (section 2) and this tutorial.
- **Every setting comes from `.env`**, passed explicitly in `compose.yaml` and documented in `.env.example` with **Format** and **Default**. Nothing is hard-coded in Dockerfiles.
- **Storage is configurable**: mount `${<NAME>_VOLUME:-<volume>}:/path` and declare `<volume>` under `volumes:`.
- **No `depends_on` across stacks**: wait in the entrypoint instead.
- **LF line endings** everywhere (`.gitattributes`): CRLF breaks shell scripts and `.env` values.
- **Scripts** are Bash with `set -uo pipefail` (or `-euo`), log lines prefixed `[component]`, and a documented variable list.

### 3.3 Add an app

Each app is a folder in `apps/` with **`source/`** (the export, not committed), a **`Dockerfile`** (copies it in and runs it) and a **`compose.yaml`** (profile, variables, volumes).

1. Copy the example of the same type: `cp -r apps/nodejs-app-example apps/orders-api`.
2. Rename the service and profile in `apps/orders-api/compose.yaml` (`nodejs-app-example` → `orders-api`); for a Java app, also the launcher name in the `Dockerfile`.
3. Copy its variables in `.env.example` and `.env` with the new prefix (`ORDERS_API_PORT`, `ORDERS_API_NODE_ENV`, …).
4. Add `- path: ./orders-api/compose.yaml` to `apps/compose.yaml`.
5. Put the app in `source/`, then build and start it:

   ```bash
   docker compose --profile orders-api up -d --build
   docker compose logs -f orders-api
   ```

6. Publish it: `gateway/http/conf.d/orders-api.conf` with `proxy_pass http://orders-api:8080` ([2.6](#26-http-gateway)).

**Deploy a new version**: replace `source/` (and `jre.tar.gz`), then `docker compose up -d --build <app>`.

| App type | What goes in `source/` | Runtime notes |
|---|---|---|
| **Java** (`java-service-example`) | Linux export: launcher, `.ini`, `plugins/`, `configuration/`; JRE as `jre.tar.gz` with top folder `jre/` | Runs `./<launcher> -nosplash -consoleLog -data /data/workspace`. Listen on `0.0.0.0:<JAVA_SERVICE_EXAMPLE_PORT>`. JVM options in the `.ini` `-vmargs`. Headless: GUI apps need `libgtk-3-0 libxtst6`. Java is killed on stop without shutdown hooks. |
| **Angular SSR** (`angular-app-example`) | Content of `dist/<app>/` (`server/`, `browser/`) | Runs `node server/server.mjs` (Node.js 24). `ANGULAR_APP_EXAMPLE_ALLOWED_HOSTS=*`; the gateway controls domains. `TRUST_PROXY_HEADERS=x-forwarded-proto` for HTTPS awareness. |
| **Node.js** (`nodejs-app-example`) | `package.json`, `package-lock.json` and the code (compiled output for TypeScript) | `npm ci --omit=dev` in the image, runs `node .`. Listen on `process.env.PORT` on all interfaces. Runtime packages belong in `dependencies`. |

### 3.4 Add a monitoring item

- **Alert rule:** create it in the UI and export it (`GET /graph/api/v1/provisioning/alert-rules/<uid>`), or copy a file in `monitoring/pmm/alerting/rules/`, give it a new **`uid`**, and save it as a new `.json`. The metrics data source is **`PA58DA793C7250F1B`**. It is created on the next `pmm-server` start. Edit existing rules in the UI; to remove one, delete both the file and the rule.
- **Dashboard:** add JSON to `monitoring/pmm/dashboards/Custom/`; PMM re-reads it every 60 seconds.
- **Custom metric:** add a query to `monitoring/client/custom-queries/` (see `postgresql/replica-lag.yml`), then restart `pmm-client`.

### 3.5 Local overrides

A `compose.override.yaml` (not committed) publishes internal tools on `127.0.0.1` for local work:

```yaml
services:
  pmm-server:
    ports: ["127.0.0.1:8081:8080"]
  dozzle:
    ports: ["127.0.0.1:8082:8080"]
  portainer:
    ports: ["127.0.0.1:8083:8080"]
```

---

<a id="testing"></a>

## ✅ 4. Testing and validation

The repository is infrastructure as code: there is **no unit test suite or linter configuration**. Validate changes with these checks, in order.

**1. Configuration** — resolves every file, variable and profile:

```bash
docker compose config --quiet                  # this server's profiles
docker compose --profile '*' config --quiet    # every service
```

**2. Shell syntax and lint**:

```bash
for f in $(git ls-files '*.sh'); do bash -n "$f" || echo "FAIL $f"; done
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:v0.10.0 $(git ls-files '*.sh')
```

**3. Isolated integration run** — a throwaway project that never touches your volumes or network. Later `--env-file` values override earlier ones:

```bash
cat > /tmp/test.env <<'EOF'
PROJECT_NAME=bkptest
NETWORK_NAME=bkptest-net
NETWORK_SUBNET=172.29.0.0/16
VPN_DNS_IP=127.0.0.11
COMPOSE_PROFILES=mysql-primary,mysql-replica,mysql-backup-replica,postgres-primary,postgres-replica,postgres-backup-replica
EOF
docker compose --env-file .env.example --env-file /tmp/test.env up -d --build
docker compose -p bkptest ps                   # backup containers turn healthy after their first backup
PROJECT_NAME=bkptest bash databases/postgres/backup/postgres-restore.sh replica
docker compose --env-file .env.example --env-file /tmp/test.env --profile '*' down -v --rmi local
```

**4. Restore drill** — the real test of backups. Run it monthly in production ([5.1](#51-point-in-time-restore-after-a-bad-delete)).

**5. Alert rules** — after a `pmm-server` start, the log lists what was created:

```bash
docker compose logs pmm-server | grep 'alert rule'
```

---

<a id="examples"></a>

## 💡 5. Practical examples

### 5.1 Point-in-time restore after a bad `DELETE`

A table was emptied at 11:04:20 UTC. Restore to just before it, into a temporary server:

```bash
bash databases/mysql/backup/mysql-restore.sh replica "2026-10-15 11:04:18"
```

```text
[mysql-restore] preparing from services_mysql-replica-backup for 2026-10-15 11:04:18 UTC into volume mysql-restore
[mysql-restore] backups: 20261015-105957/20261015-105957-full 20261015-105957/20261015-110400-incr
[mysql-restore] starting temporary server mysql-restore
[mysql-restore] replaying binary logs of server 81762171-c887-11f1-92fe-8ac3a68eac8d from mysql-bin.000004 up to 2026-10-15 11:04:18 UTC
[mysql-restore] done. The temporary server mysql-restore holds the restored data:
```

Take the rows back, then remove the temporary server:

```bash
docker exec mysql-restore mysqldump -uroot -p shop orders > orders.sql
docker rm -f mysql-restore; docker volume rm mysql-restore
```

The PostgreSQL equivalent picks the right full + differential backup and stops before the bad transaction:

```bash
bash databases/postgres/backup/postgres-restore.sh replica "2026-10-15 10:51:34"
```

```text
[postgres-restore]   INFO: repo1: restore backup set 20261015-105000F_20261015-105100D, recovery will start at 2026-10-15 10:51:00
[postgres-restore]   LOG:  recovery stopping before commit of transaction 758, time 2026-10-15 10:51:37.395886+00
[postgres-restore]   LOG:  archive recovery complete
```

Without a time, both scripts restore everything up to the last copied change.

### 5.2 Check the backups

```bash
docker compose exec postgres-backup-replica pgbackrest info
```

```text
stanza: main
    status: ok

    db (current)
        wal archive min/max (17): 000000010000000000000003/000000010000000000000016

        full backup: 20261015-105000F
            timestamp start/stop: 2026-10-15 10:50:00+00 / 2026-10-15 10:50:04+00
            database size: 22.4MB, database backup size: 22.4MB
            repo1: backup set size: 2.6MB, backup size: 2.6MB
```

```bash
docker compose exec mysql-backup-replica ls /backups/chains/*
```

```text
/backups/chains/20261015-105957:
20261015-105957-full  20261015-110400-incr  server_uuid  started
```

### 5.3 Recover after losing a server

Bring the off-site copy back into a volume, then restore from it:

```bash
docker compose run --rm -v pg-offsite:/restore sync restore postgres-replica-backup
REPO_VOLUME=pg-offsite bash databases/postgres/backup/postgres-restore.sh

docker compose run --rm -v mysql-offsite:/restore sync restore mysql-replica-backup
BACKUP_VOLUME=mysql-offsite bash databases/mysql/backup/mysql-restore.sh
```

```text
[sync] restoring gdrive:backups/server-a/postgres-replica-backup into /restore
[postgres-restore]   INFO: repo1: restore backup set 20261015-110000F_20261015-110600D, recovery will start at 2026-10-15 11:06:00
[postgres-restore]   LOG:  archive recovery complete
```

---

<a id="troubleshooting"></a>

## 🧯 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `no service selected`, or settings from `.env` ignored | `COMPOSE_PROFILES` is empty, or **`COMPOSE_ENV_FILES`** is set in the shell | Set the profiles in `.env`; `unset COMPOSE_ENV_FILES` |
| PostgreSQL exits with `chmod: changing permissions of '/data/db': Operation not permitted` | `POSTGRES_*_DATA_VOLUME` points to a **Windows folder** | Keep PostgreSQL data in a volume on Docker Desktop (the default value) |
| A service with a folder path fails with `Permission denied` (Linux) | Docker created the folder **owned by root** | `sudo install -d -o <uid> -g <gid> <folder>` with the owner from [2.4](#24-storage), then restart it |

More cases:

| Symptom | Fix |
|---|---|
| `postgres-backup-replica` logs `waiting for ca.crt, client.crt and client.key` | Copy the three files from the primary's server ([2.8](#28-backups)) |
| `postgres-backup-replica` keeps retrying `stanza-create` | The repository belongs to another cluster (recreated primary): move or delete it ([section 7](#operations)) |
| The VPN client refuses to start | `NETWORK_SUBNET` overlaps the VPN host's: use another subnet (e.g. `172.31.0.0/16`) |
| A replica keeps restarting after its first start | The MySQL replica restarts once after cloning (normal); otherwise check that its passwords and `lower-case-table-names` match the primary |
| A database started later is missing in PMM | `docker compose restart pmm-client` |

---

<a id="operations"></a>

## 🔧 7. Operations

**Replication state**

```bash
docker compose exec mysql-replica-db mysql -uroot -p -e "SHOW REPLICA STATUS\G"
docker compose exec postgres-replica-db psql -U postgres -c "SELECT status, sender_host FROM pg_stat_wal_receiver"
docker compose exec postgres-db psql -U postgres -c "SELECT client_addr, state, replay_lag FROM pg_stat_replication"
```

**Rebuild a replica**

```bash
docker compose rm -sf mysql-replica-db
docker volume rm <PROJECT_NAME>_mysql-replica-data   # or empty its folder
docker compose up -d mysql-replica-db
docker compose restart pmm-client
```

Same for `postgres-replica-db` / `<PROJECT_NAME>_postgres-replica-data`.

**Turn a backup side off for good** — remove its profile. For PostgreSQL also delete its repository, or the server keeps archiving WAL into it:

```bash
docker compose rm -sf postgres-backup-primary postgres-db
docker volume rm <PROJECT_NAME>_postgres-primary-backup   # or empty its folder
docker compose up -d postgres-db
```

On the replica's server: `postgres-backup-replica`, `postgres-replica-db` and `<PROJECT_NAME>_postgres-replica-backup`.

**Copy off-site now**: `docker compose run --rm sync run`.

**Docker log rotation** (`/etc/docker/daemon.json`):

```json
{ "log-driver": "json-file", "log-opts": { "max-size": "50m", "max-file": "5" } }
```

## Production checklist

- [ ] Real passwords in `.env`; `VPN_HOST` set to the public IP or domain
- [ ] Firewall: only `51820/udp`, `80/tcp`, `443/tcp` open (replica servers: no inbound ports)
- [ ] No `compose.override.yaml` publishing internal tools
- [ ] Certificates in `gateway/http/certs/` for every public app
- [ ] Docker log rotation configured
- [ ] `COMPOSE_PROFILES` set to this server's roles; replication checked
- [ ] Storage chosen for every service (`*_DATA_VOLUME`, `*_BACKUP_VOLUME`), folders created with their owners, enough disk for backups
- [ ] Backup profiles on the chosen side(s), backup containers healthy, a test restore done (PostgreSQL replica side: `ca.crt`, `client.crt`, `client.key` copied)
- [ ] `sync` running on every server with backups, `SYNC_ENCRYPT_PASSWORD` set and stored safely, a restore from the off-site copy tested
- [ ] PMM contact points and notification policies configured and tested
- [ ] Apps: exports in `source/` (and JREs in `jre.tar.gz`), app variables in `.env`, apps running
