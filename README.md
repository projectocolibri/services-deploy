# Colibri services deploy

Docker Compose deployment of the Colibri infrastructure: MySQL and PostgreSQL
(master, replica, backups, admin panels), a VPN and an HTTP gateway, and
monitoring.

Everything runs as one Compose project (`colibri-services`). The only ports
open to the outside are the VPN and the HTTP gateway; every other service is
internal and reached through the VPN.

```
                    Internet
             ┌──────────┴──────────┐
         UDP 51820            TCP 80 / 443
             │                     │
       ┌─────▼─────┐         ┌─────▼─────┐
       │    VPN    │         │   HTTP    │
       │ WireGuard │         │   nginx   │
       └─────┬─────┘         └─────┬─────┘
             │ admins              │ public apps
   ──────────┴──── internal network 172.30.0.0/16 ─────────
     MySQL · PostgreSQL · phpMyAdmin · pgAdmin · Netdata · Dozzle
```

## Requirements

- Docker Engine with Docker Compose v2.24 or later
- Linux server (Docker Desktop works for development)

## Quick start

```sh
git clone <repository> colibri-services-deploy
cd colibri-services-deploy

# every stack needs a local .env file (not committed, can be empty)
touch gateway/.env monitoring/.env databases/mysql/.env databases/postgres/.env

docker compose up -d
docker compose ps
```

Before deploying to a real server, change the default passwords and set
`VPN_HOST` (see [Configuration](#configuration)).

## Repository layout

```
compose.yaml                 root: includes every stack, fixes the internal network
gateway/
  vpn/                       WireGuard VPN
  http/                      nginx for public apps (conf.d/, certs/)
monitoring/
  netdata/                   metrics, databases, uptime checks, alerts
  logs/                      Dozzle log viewer
databases/
  mysql/                     Percona Server: master, replica, backup, admin
  postgres/                  Percona PostgreSQL: master, replica, backup, admin
```

Every folder with a `compose.yaml` is a stack. Stacks with sub-stacks list them
with `include`: **comment out an entry to leave that part out** (for example the
replica, or the whole monitoring stack). No service depends on another stack;
each one waits for what it needs by itself.

## Configuration

Each stack loads two env files, in order:

| File | Committed | Purpose |
|---|---|---|
| `.env.dev` | yes | Defaults for development |
| `.env` | no | Local overrides and secrets (wins over `.env.dev`) |

Put production values in `.env` on each server. The most important ones:

| Stack | Variables |
|---|---|
| `gateway` | `VPN_HOST` (public IP / domain), `VPN_PEERS` |
| `databases/mysql` | `MASTER_MYSQL_ROOT_PASSWORD`, `MASTER_MYSQL_USER_PASSWORD`, `MASTER_REPLICATION_PASSWORD` |
| `databases/postgres` | `MASTER_POSTGRES_PASSWORD`, `MASTER_REPLICATION_PASSWORD`, `ADMIN_PASSWORD` |
| `monitoring` | `MONITOR_*_PASSWORD`, SMTP and Slack settings |

For local tests only, `compose.override.yaml` (not committed) can publish
internal tools on `127.0.0.1`:

```yaml
services:
  netdata:
    ports: ["127.0.0.1:19999:19999"]
  dozzle:
    ports: ["127.0.0.1:8888:8080"]
```

## Gateway

### VPN (WireGuard)

Private access to every internal service. Clients resolve Docker service names,
so tools are reached by name.

1. List the users in `VPN_PEERS` (comma separated) and set `VPN_HOST`.
2. Start the stack. Each user gets a config file and a QR code in
   `gateway/vpn/config/peer_<name>/` (never commit this folder).
3. Import `peer_<name>.conf` into the WireGuard app, or scan `peer_<name>.png`.

Only the VPN subnet and the internal network are routed through the tunnel.
After changing `VPN_HOST`, delete `gateway/vpn/config/peer_*` so the client
configs are regenerated.

### HTTP (nginx)

Public web apps. Requests for unknown hosts are refused.

1. Copy `gateway/http/conf.d/app.conf.example` to `<app>.conf` and adjust the
   domain and upstream (`proxy_pass http://<service>:<port>`).
2. Put the certificate in `gateway/http/certs/<domain>/fullchain.pem` and
   `privkey.pem` (never committed).
3. Reload: `docker compose exec http nginx -s reload`.

## Databases

MySQL (Percona Server 8.0) and PostgreSQL (Percona Distribution 17) follow the
same structure:

| Sub-stack | MySQL | PostgreSQL |
|---|---|---|
| master | `mysql-db` | `postgres-db` |
| replica | `mysql-replica`: clones the master (`CLONE INSTANCE`), then GTID replication | `postgres-replica`: clones the master (`pg_basebackup`), then streaming replication |
| backup | Percona XtraBackup | `pg_basebackup` |
| admin | phpMyAdmin (`mysql-admin`) | pgAdmin (`postgres-admin`) |

The replica sets itself up on its first start; the master only needs to be
reachable. A fresh volume is required to re-clone a replica.

### Backups

Both backup services take a **full backup once a day and incremental backups
every `BACKUP_INTERVAL`** on top of it. Failed backups are deleted so they never
become the base of the next one.

| Variable | Description |
|---|---|
| `BACKUP_HOST` | Database to back up (master or replica) |
| `BACKUP_HOST_USER` / `BACKUP_HOST_PASSWORD` | Account used for the backup |
| `BACKUP_HOST_VOLUME` | MySQL only: data volume of `BACKUP_HOST` |
| `BACKUP_INTERVAL` | Time between backups (`30m`, `4h`, `1d`) |

Backups are written to `databases/<engine>/backup/backups/<engine>/<host>/<date>/`
(`full/`, then `incHHMMSS/`), with a `.log` per day.

Restore:

- **MySQL**: `xtrabackup --prepare --apply-log-only` on `full`, then on each
  `incHHMMSS` in order with `--incremental-dir`, then a final `--prepare`.
- **PostgreSQL**: `pg_combinebackup full inc... -o <restore dir>`.

## Monitoring

| Tool | What it shows | URL (through the VPN) |
|---|---|---|
| **Netdata** | Host and per-container CPU, memory, disk I/O and network; MySQL and PostgreSQL metrics including replication lag; HTTP / TCP uptime checks; alerts | `http://netdata:19999` |
| **Dozzle** | Live logs of every container, searchable per container | `http://dozzle:8080` |

Configuration lives in `monitoring/netdata/config/`:

- `go.d/mysql.conf`, `go.d/postgres.conf`: databases to monitor
- `go.d/httpcheck.conf`, `go.d/portcheck.conf`: uptime checks
- `health_alarm_notify.conf`: notification channels

Alerts are sent by email and Slack once enabled in `monitoring/.env`:

```env
ALERT_EMAIL_ENABLED=YES
ALERT_EMAILS=team@example.com
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USER=...
SMTP_PASSWORD=...
SMTP_FROM=netdata@example.com

ALERT_SLACK_ENABLED=YES
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...
SLACK_CHANNEL=#alerts
```

Dozzle reads the logs Docker keeps. On a server, cap their size in
`/etc/docker/daemon.json`:

```json
{ "log-driver": "json-file", "log-opts": { "max-size": "50m", "max-file": "5" } }
```

## Service addresses

Through the VPN:

| Service | Address |
|---|---|
| phpMyAdmin | `http://mysql-admin` |
| pgAdmin | `http://postgres-admin` |
| Netdata | `http://netdata:19999` |
| Dozzle | `http://dozzle:8080` |
| MySQL master / replica | `mysql-db:3306` / `mysql-replica:3306` |
| PostgreSQL master / replica | `postgres-db:5432` / `postgres-replica:5432` |

## Production checklist

- [ ] Real passwords in every `.env` (none of the `.env.dev` defaults)
- [ ] `VPN_HOST` set to the server's public IP or domain
- [ ] Firewall: only `51820/udp`, `80/tcp` and `443/tcp` open
- [ ] No `compose.override.yaml` publishing internal tools
- [ ] Certificates in `gateway/http/certs/` for every public app
- [ ] Docker log rotation configured
- [ ] Alerts enabled and tested (email and Slack)
- [ ] A backup restored at least once
