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

The replicas clone their primary on the first start: allow a minute (the MySQL replica restarts once after cloning). Before going to production, replace every default password in `.env` and set **`VPN_HOST`**.

## 🧭 Next steps

| Read | For |
|---|---|
| [TUTORIAL.md](TUTORIAL.md) | Architecture, every setting, multi-server setup, backups and restores, monitoring, adding apps, troubleshooting |
| [.env.example](.env.example) | The full, commented list of settings |
| [TUTORIAL.md — Production checklist](TUTORIAL.md#production-checklist) | What to check before going live |
