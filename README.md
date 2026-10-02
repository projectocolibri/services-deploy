# Services deploy

Docker Compose deployment of shared infrastructure: MySQL (Percona Server) and
PostgreSQL (Percona Distribution), each with a read-only replica, a VPN and an
HTTP gateway, and monitoring (PMM, Dozzle and Portainer). It also runs the company's apps:
Java services with their own JRE and Angular apps with server-side
rendering.

Everything runs on **one server**, as one Compose project (`PROJECT_NAME`,
default `services`) brought up by a single `docker compose up -d`. The only
ports open to the outside are the VPN and the HTTP gateway; every other service
is internal and reached through the VPN.

```
                           Internet
                  ┌───────────┴───────────┐
              UDP 51820              TCP 80 / 443
                  │                       │
            ┌─────▼─────┐           ┌─────▼─────┐
            │    VPN    │           │   HTTP    │
            │ WireGuard │           │   nginx   │
            └─────┬─────┘           └─────┬─────┘
                  │ admins                │ public apps
 ─────────────────┴──── internal network (NETWORK_SUBNET) ─┴──────────────────
  mysql-primary     ── replication ────►  mysql-replica     (read only)
  postgres-primary  ── streaming ──────►  postgres-replica  (read only)
  PMM, Dozzle, Portainer, admin panels
```

## Requirements

- Docker Engine with Docker Compose v2.24 or later
- Linux server (Docker Desktop works for development)
- 2+ CPU cores and 4+ GB RAM for PMM Server

## Quick start

```sh
git clone <repository> services-deploy
cd services-deploy

cp .env.example .env

docker compose up -d
docker compose ps
```

The replicas clone their primary on the first start, so give them a minute
(the MySQL replica restarts once after cloning). Before deploying to a real
server, change the default passwords and set `VPN_HOST` in `.env`.

`.env` is the only settings file. Compose loads it automatically, so
`COMPOSE_ENV_FILES` must not be set in the shell (if it is, Compose reads the
files it names instead of `.env`).

## Repository layout

```
.env.example                 every setting, documented (copy to .env)
compose.yaml                 includes every stack, defines the network
gateway/
  vpn/host/                  WireGuard VPN server (server with the primaries)
  vpn/client/                WireGuard peer for replica-only servers
  http/                      nginx for public apps and internal sites
                             (conf.d/, certs/, internal-ca.sh)
monitoring/
  pmm/                       PMM Server, custom dashboards, Slack alerts
  client/                    PMM client and cAdvisor
  logs/                      Dozzle
  portainer/                 Portainer (container management)
databases/
  mysql/
    master/                  primary, read/write (mysql-db)
    replica/                 read-only replica (mysql-replica-db)
    admin/                   phpMyAdmin
    backup/                  XtraBackup, binary log stream, restore script
  postgres/
    master/                  primary, read/write (postgres-db)
    replica/                 read-only replica (postgres-replica-db)
    admin/                   pgAdmin
    backup/                  pg_basebackup, WAL stream, restore script
apps/
  java-service-example/      Java app export + Linux JRE (source/, jre.tar.gz)
  angular-app-example/       Angular SSR build run by Node.js (source/)
  nodejs-app-example/        Node.js app, dependencies installed in the image (source/)
```

Every folder with a `compose.yaml` is a stack. Stacks list their sub-stacks
with `include`, and every stack is always included: what runs on a server is
chosen by its roles (see [Server roles](#server-roles)). No service depends on
another stack: each one waits for what it needs by itself.

## Server roles

Every service has its own Compose profile. `COMPOSE_PROFILES` in `.env` lists
the services of **this** server, and `docker compose up -d` starts exactly
those. Every server runs the same committed files; only its `.env` differs.

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
| | `mysql-backup` | XtraBackup + binary log stream (next to the replica) |
| | `mysql-admin` | phpMyAdmin |
| PostgreSQL | `postgres-primary` | Primary, read/write |
| | `postgres-replica` | Read-only hot standby |
| | `postgres-backup` | pg_basebackup + WAL stream (next to the replica) |
| | `postgres-admin` | pgAdmin |
| Apps | `java-service-example` | Java service example |
| | `angular-app-example` | Angular SSR app example |
| | `nodejs-app-example` | Node.js app example |

The apps are not in the default list: add them where they run, e.g.
`COMPOSE_PROFILES=http,java-service-example`.

```env
# One server with everything (default in .env.example)
COMPOSE_PROFILES=vpn-host,http,pmm,metrics,logs,portainer,mysql-primary,mysql-replica,mysql-backup,mysql-admin,postgres-primary,postgres-replica,postgres-backup,postgres-admin
MYSQL_BACKUP_DIR=/srv/backups/mysql
POSTGRES_BACKUP_DIR=/srv/backups/postgres

# Two servers: the primaries...
COMPOSE_PROFILES=vpn-host,http,pmm,metrics,logs,portainer,mysql-primary,mysql-admin,postgres-primary,postgres-admin

# ...and the replicas with their backups
COMPOSE_PROFILES=vpn-client,mysql-replica,mysql-backup,postgres-replica,postgres-backup
MYSQL_BACKUP_DIR=/srv/backups/mysql
POSTGRES_BACKUP_DIR=/srv/backups/postgres

# Only MySQL, with backups
COMPOSE_PROFILES=mysql-primary,mysql-replica,mysql-backup
MYSQL_BACKUP_DIR=/srv/backups/mysql
```

After changing the roles, `docker compose up -d` starts the new services.
Commands only see the active profiles, so stop services of a removed role
explicitly, e.g. `docker compose --profile mysql-admin down`, or all of them with
`docker compose --profile '*' down`. With no profile set, Compose starts
nothing (`no service selected`).

## Configuration

All settings live in one file, `.env` at the root, which Compose loads
automatically and passes to every stack. It is not committed: each server has
its own. `.env.example` is the committed template, with development defaults
and a comment explaining every variable, in this order:

| Section | Contents |
|---|---|
| 1. Project | `PROJECT_NAME`: prefix of containers and volumes. Renaming it orphans existing volumes. |
| 2. Profiles | `COMPOSE_PROFILES`: what this server runs (see [Server roles](#server-roles)) |
| 3. Network | `NETWORK_NAME`, `NETWORK_SUBNET` (also routed through the VPN), `VPN_DNS_IP` (DNS for service names across servers) |
| 4. Services | `TZ`, then one block per service: VPN host, VPN client, HTTP, PMM Server, PMM client, Dozzle, Portainer, MySQL, PostgreSQL (each with its own backup settings), apps |

When `.env.example` gets a new variable, copy it to each server's `.env`.
Compare the two with `diff .env.example .env`.

UTC is recommended for `TZ`: PMM, Grafana and Dozzle show times in the
browser's time zone anyway. pmm-client, cAdvisor and Dozzle have no time zone
data and stay on UTC, and PostgreSQL keeps the zone it was initialized with.

Production values to set in `.env`:

| Service | Variables |
|---|---|
| Gateway | `VPN_HOST`, `VPN_PEERS` |
| MySQL | `MYSQL_ROOT_PASSWORD`, `MYSQL_USER`, `MYSQL_USER_PASSWORD`, `MYSQL_REPLICATION_PASSWORD`, `MYSQL_MONITOR_PASSWORD`, `MYSQL_DATABASES` |
| PostgreSQL | `POSTGRES_PASSWORD`, `POSTGRES_REPLICATION_PASSWORD`, `POSTGRES_MONITOR_PASSWORD`, `POSTGRES_APP_USER`, `POSTGRES_APP_PASSWORD`, `POSTGRES_DATABASES`, `POSTGRES_ADMIN_EMAIL`, `POSTGRES_ADMIN_PASSWORD` |
| Monitoring | `PMM_ADMIN_PASSWORD`, `PORTAINER_ADMIN_PASSWORD`, `SMTP_*`, `SLACK_WEBHOOK_URL` |
| Backups | `MYSQL_BACKUP_DIR`, `POSTGRES_BACKUP_DIR` |

The PMM client connects to the databases with the same `MYSQL_MONITOR_*` and
`POSTGRES_MONITOR_*` accounts the primaries create, so they are set once.

For local tests, a `compose.override.yaml` (not committed) can publish internal
tools on `127.0.0.1`:

```yaml
services:
  pmm-server:
    ports: ["127.0.0.1:8081:8080"]
  dozzle:
    ports: ["127.0.0.1:8082:8080"]
  portainer:
    ports: ["127.0.0.1:8083:8080"]
```

## Gateway

### VPN host (WireGuard)

Private access to every internal service. Clients resolve Docker service names.

1. Set `VPN_HOST` (public IP or domain) and list the users in `VPN_PEERS`
   (comma separated, letters and digits only).
2. Start the stack. Each user gets a config and a QR code in
   `gateway/vpn/host/config/peer_<name>/`.
3. Import `peer_<name>.conf` into the WireGuard app, or scan `peer_<name>.png`.

Only the VPN subnet and the internal network are routed through the tunnel.
After changing `VPN_HOST`, delete `gateway/vpn/host/config/peer_*` so the
client configs are regenerated.

### VPN client (replica on another server)

A server running only replicas joins the VPN host as a peer. The client brings
the tunnel up on that server's host network, so its containers reach the
primaries' network with no other change.

On the **VPN host** (server with the primaries):

1. Add a peer for the new server in `.env`, e.g.
   `VPN_PEERS=admin,replica1`, and run `docker compose up -d vpn`.
2. Copy `gateway/vpn/host/config/peer_replica1/peer_replica1.conf` to the new
   server (it contains that server's private key).

On the **replica server** (clone of this repository):

1. Save the file as `gateway/vpn/client/config/peer.conf`.
2. Copy `.env.example` to `.env`. In it, use a different subnet than the VPN host, e.g.
   `NETWORK_SUBNET=172.31.0.0/16`. The client refuses to start if a tunnel
   route overlaps a local one.
3. Set the profiles in `.env`:
   `COMPOSE_PROFILES=vpn-client,mysql-replica,mysql-backup,postgres-replica,postgres-backup`
   and `MYSQL_BACKUP_DIR` / `POSTGRES_BACKUP_DIR`. On the VPN host, remove the `*-replica` and `*-backup`
   profiles from its list.
4. Use the same database passwords and `VPN_DNS_IP` as the VPN host.
5. `docker compose up -d`, then check `docker compose ps vpn-client` is
   healthy and the replication state (see [Databases](#databases)).

Service names work across servers. The VPN host container has a fixed address
(`VPN_DNS_IP`, default `172.30.255.2`) where its DNS server answers with the
VPN host's service names. Replicas use it as their DNS server (`dns:`): Docker
DNS still answers names on their own server first, and forwards the rest, such
as `mysql-primary` on the VPN host, through the tunnel. The replica server
needs no open inbound port.

Not covered yet: the VPN host's admin panels and PMM cannot reach containers
on the replica server, and `pmm-client-register.sh` only registers databases
on its own network.

### HTTP (nginx)

The single entry point for web traffic: public apps and internal sites (apps
and admin tools on internal host names). TLS ends here; every service behind
it serves plain HTTP on the port set in its `*_PORT` variable in `.env`
(**8080** for all by default). Requests for unknown hosts are refused.

**Public app**

1. Copy `gateway/http/conf.d/app.conf.example` to `<app>.conf` and set the
   domain and upstream (`proxy_pass http://<service>:<port>`).
2. Put the certificate in `gateway/http/certs/<domain>/fullchain.pem` and
   `privkey.pem`.
3. Reload: `docker compose exec http nginx -s reload`.

**Internal sites** (e.g. `https://pmm.monitor.example.lan`)

1. Copy `gateway/http/conf.d/internal.conf.example` to `<name>.conf` and
   replace `example.lan` with your internal domain. Its map lists one host
   name per service, on port 8080; change a line if you changed that
   service's `*_PORT` (nginx does not read `.env`).
2. Issue a certificate from the internal CA (created on the first run):

   ```sh
   cd gateway/http
   ./internal-ca.sh example.lan '*.apps.example.lan' '*.mysql.example.lan' \
     '*.postgres.example.lan' '*.monitor.example.lan'
   ```

   Install `gateway/http/certs/internal-ca/ca.crt` as a trusted root CA on
   every client. Never share `ca.key`.
3. Point the names at this server in your internal DNS (LAN DNS, or the VPN
   clients' hosts file).
4. Reload: `docker compose exec http nginx -s reload`.

Only private networks (LAN, VPN, Docker) are allowed. VPN clients can still
reach the containers directly by service name (`http://<service>:<port>`).

## Databases

| Engine | Primary (read/write) | Replica (read only) |
|---|---|---|
| MySQL (Percona Server 8.4) | `mysql-primary:3306` | `mysql-replica:3306` |
| PostgreSQL (Percona Distribution 17) | `postgres-primary:5432` | `postgres-replica:5432` |

Apps connect by role alias (`*-primary`, `*-replica`), never by service name.

- **MySQL**: the replica clones the primary on its first start
  (`CLONE INSTANCE`), then follows it with GTID replication under
  `super_read_only`.
- **PostgreSQL**: the replica clones the primary on its first start
  (`pg_basebackup`), then streams its WAL as a hot standby.
- Replication is asynchronous. The replica is for read queries and reporting:
  it is not a backup (see [Backups](#backups)).

Replication state:

```sh
docker compose exec mysql-replica-db mysql -uroot -p -e "SHOW REPLICA STATUS\G"
docker compose exec postgres-replica-db psql -U postgres -c "SELECT status, sender_host FROM pg_stat_wal_receiver"
docker compose exec postgres-db psql -U postgres -c "SELECT client_addr, state, replay_lag FROM pg_stat_replication"
```

### Application databases

Naming databases in these variables has the primary create them on every
start, so a new server needs no manual `CREATE DATABASE`. Existing databases
and roles are never changed or dropped: removing a name only stops creating
it, and a new password does not change a role that already exists. The
replicas get the databases through replication.

| | MySQL | PostgreSQL |
|---|---|---|
| Databases | `MYSQL_DATABASES` (empty: nothing is created) | `POSTGRES_DATABASES` (empty: nothing is created) |
| Owner / grants | all privileges to `MYSQL_USER` | owned by `POSTGRES_APP_USER` (`POSTGRES_APP_PASSWORD`), created if missing |
| Names | lowercase letters, digits and `_`; a name with `%` is a grant-only pattern (`app%`), so the app can create matching databases itself | lowercase letters, digits and `_` |

Two settings are fixed when the primary's data volume is initialized and need
a new volume to change:

- MySQL runs with `--lower-case-table-names=1` (names stored lowercase and
  matched case-insensitively) on both primary and replica, which must match or
  the clone is refused.
- PostgreSQL is initialized with `--encoding=UTF8 --locale=C.UTF-8`
  (`POSTGRES_INITDB_ARGS`) instead of the image's `SQL_ASCII`.

### Admin panels

phpMyAdmin (`http://mysql-admin:8080`) and pgAdmin
(`http://postgres-admin:8080`), or their internal sites through the HTTP
gateway, list the servers in `MYSQL_ADMIN_HOSTS` / `POSTGRES_ADMIN_HOSTS`
(labels in `*_ADMIN_HOSTS_LABELS`).

### Backups

The `mysql-backup` and `postgres-backup` profiles run on the server with the
replicas and write to `MYSQL_BACKUP_DIR` and `POSTGRES_BACKUP_DIR` there.
Full backups are taken from the replicas (no load on the primaries); the
primaries' logs are streamed continuously for point-in-time recovery.

| | MySQL (`databases/mysql/backup`) | PostgreSQL (`databases/postgres/backup`) |
|---|---|---|
| Container | `mysql-backup` | `postgres-backup` |
| Daily backup | Percona XtraBackup of the replica, zstd | `pg_basebackup` of the standby, lz4 |
| Verification | Decompress and prepare a copy after every backup | `pg_verifybackup` against the manifest |
| Point in time | Binary logs streamed from the primary (in the background, same container) | WAL streamed from the primary through a replication slot (in the background, same container) |
| Directory | `MYSQL_BACKUP_DIR` (default `./backups/mysql`): `full/`, `binlog/` | `POSTGRES_BACKUP_DIR` (default `./backups/postgres`): `base/`, `wal/` |
| Schedule (cron) | `MYSQL_BACKUP_SCHEDULE` (UTC), default `0 2 * * *` | `POSTGRES_BACKUP_SCHEDULE` (`TZ`), default `30 2 * * *` |
| Retention | `MYSQL_BACKUP_RETENTION`, default `7d` | `POSTGRES_BACKUP_RETENTION`, default `7d` |

- A backup is written to `<timestamp>.partial` and renamed only when complete
  and verified; failures leave `<timestamp>.failed.log`. Without any backup
  (first start) a backup runs at once; a failed backup is retried within the
  hour.
- Schedule: standard 5-field cron (`minute hour day month weekday`), e.g.
  `0 */6 * * *` every 6 hours or `0 3 * * 0` on Sundays. No cron daemon: the
  backup container computes the next run itself.
- Retention (`*_BACKUP_RETENTION`: `36h`, `7d`, `2w`, `1M`, `1y`) removes older
  backups but never the newest. Logs are kept only back to the oldest
  remaining backup, since older ones cannot be replayed; logs moved aside
  after a primary change are removed once past the retention too.
- Health checks: a backup container turns unhealthy when its log stream stops,
  the last backup failed, or a scheduled backup is over an hour overdue.
- New primary: the stream records the primary's identity (MySQL
  `server_uuid`, PostgreSQL system identifier). If the primary's data volume
  is recreated, the old logs are moved to `binlog.<id>.<date>` /
  `wal.<id>.<date>` (kept; delete them when no longer needed), streaming
  starts fresh and a new full backup is taken at once, so the logs of two
  servers are never mixed.
- Backup files are readable only by root. Use a separate disk in production
  (e.g. `MYSQL_BACKUP_DIR=/srv/backups/mysql`,
  `POSTGRES_BACKUP_DIR=/srv/backups/postgres`).
- The primary keeps WAL for the PostgreSQL stream while it is down, up to
  `POSTGRES_MAX_SLOT_WAL_KEEP_SIZE` (default 10GB). If backups are removed for
  good, drop the slot:
  `docker compose exec postgres-db psql -U postgres -c "SELECT pg_drop_replication_slot('backup_wal')"`.

Backups on the replica server survive the loss of the primary server, but not
of both servers. For that, also copy the backup directories off-site (e.g.
encrypted object storage).

#### Restore

Both scripts restore the newest backup into a **temporary server** (separate
container and volume; production is never touched), optionally to a point in
time in **UTC**. Run them on the server with the backups:

```sh
# Everything up to the last received change
bash databases/mysql/backup/mysql-restore.sh
bash databases/postgres/backup/postgres-restore.sh

# Up to a moment, e.g. just before a bad DROP TABLE
bash databases/mysql/backup/mysql-restore.sh "2026-09-16 11:30:17"
bash databases/postgres/backup/postgres-restore.sh "2026-09-16 11:30:17"
```

Then take what you need from the temporary server and remove it:

```sh
docker exec mysql-restore mysqldump -uroot -p <database> [table] > dump.sql
docker exec postgres-restore pg_dump -U postgres [-t table] <database> > dump.sql

docker rm -f mysql-restore; docker volume rm mysql-restore
docker rm -f postgres-restore; docker volume rm postgres-restore
```

Run a restore regularly (e.g. monthly) to prove the backups work.

## Apps

Each app is a folder in `apps/` with three parts:

| File | Purpose |
|---|---|
| `source/` | The app export (not committed) |
| `Dockerfile` | Copies the export into the image and runs it |
| `compose.yaml` | The service: profiles, environment variables, volumes |

An app's environment variables are set in `.env` (`<APP>_*`, section 4.11 of
`.env.example`) and passed by its `compose.yaml`; the Dockerfiles set none. Apps are
internal; publish them through the HTTP gateway (see
[HTTP (nginx)](#http-nginx)) or reach them through the VPN.

```sh
docker compose --profile java-service-example up -d --build   # or add it to COMPOSE_PROFILES
docker compose logs -f java-service-example
```

- **Deploy a new version**: replace the files in `source/` (and `jre.tar.gz`) and
  rebuild: `docker compose up -d --build <app>`.
- **Add an app**: copy the example of the same type to `apps/<app>`, rename
  the service in its `compose.yaml` (and the launcher in the Java
  service `Dockerfile`), copy its variables in `.env` with the new prefix, and
  include it in `apps/compose.yaml`.

### Java service (`java-service-example`)

1. Export the app for Linux (e.g. x86_64) into
   `apps/java-service-example/source/`: the launcher `java-service-example`,
   `java-service-example.ini`, `plugins/`, `configuration/`, ...
2. Put a Linux JRE of the same architecture, e.g. Java 8 for older apps, as
   `apps/java-service-example/jre.tar.gz`, with everything under a top
   folder `jre/` (`jre/bin/java`). The build extracts it to `/app/jre`.
3. `docker compose up -d --build java-service-example`.

The Dockerfile copies `source/` to `/app` and the JRE to `/app/jre`, with
executable permissions (they are lost when the export passes through Windows),
and runs:

```sh
./java-service-example -nosplash -consoleLog -data /data/workspace
```

The app serves HTTP on `JAVA_SERVICE_EXAMPLE_PORT` (default **8080**), inside
the Docker network only. Publish it through the HTTP gateway: in
`gateway/http/conf.d/<app>.conf` use
`proxy_pass http://java-service-example:<port>`. Through the VPN it is at
`http://java-service-example:<port>`.

- Configure the app's HTTP server to listen on `0.0.0.0` and on the same port
  as `JAVA_SERVICE_EXAMPLE_PORT`: the variable only tells Docker and the
  health check which port to use, it does not change the app. A server bound
  to `localhost` is unreachable from other containers.
- The container is healthy once the port accepts connections (2 minutes of
  start time allowed).
- The launcher finds the JRE in `/app/jre` by itself: no `-vm` needed.
- `JAVA_SERVICE_EXAMPLE_LANG=C.UTF-8`: older JVMs take `file.encoding` from
  the locale.
- JVM options (memory, system properties) go in the `-vmargs` of the exported
  `.ini`.
- The workspace (`-data`) and the user's home (`/data`) are in the
  `java-service-example-data` volume, so they survive new versions.
- The app's log goes to `docker compose logs` (`-consoleLog`).
- It runs headless, with no GUI libraries installed. An app that loads a
  GUI toolkit needs `libgtk-3-0 libxtst6` added to the `apt-get install` in the Dockerfile.
- The launcher starts Java as a child process: on `docker compose stop` Java
  is killed without running its shutdown hooks.

### Angular app (`angular-app-example`)

1. Build the Angular SSR app (`ng build`) and copy the content of
   `dist/<app>/` (`server/`, `browser/`) into
   `apps/angular-app-example/source/`. The server bundle already contains
   Express and Angular: no `node_modules`.
2. `docker compose up -d --build angular-app-example`.
3. Publish it: in `gateway/http/conf.d/<app>.conf` use
   `proxy_pass http://angular-app-example:8080`.

The Dockerfile copies `source/` to `/app` and runs `node server/server.mjs`
(Node.js 24). Settings, in `.env`:

- `ANGULAR_APP_EXAMPLE_PORT` (8080): port of the SSR server.
- `ANGULAR_APP_EXAMPLE_NODE_ENV` (`production`).
- `ANGULAR_APP_EXAMPLE_ALLOWED_HOSTS=*` (`NG_ALLOWED_HOSTS`) lets Angular
  render for any host. Access is controlled by the HTTP gateway: only the
  domains in its `server_name` reach the app.
- `ANGULAR_APP_EXAMPLE_TRUST_PROXY_HEADERS=x-forwarded-proto`
  (`NG_TRUST_PROXY_HEADERS`) lets pages rendered behind the HTTP gateway know
  they are served over HTTPS.

### Node.js app (`nodejs-app-example`)

1. Copy the app into `apps/nodejs-app-example/source/`: `package.json`,
   `package-lock.json` and the code, ready to run (for TypeScript or bundled
   apps, the compiled output). `node_modules` is not needed.
2. `docker compose up -d --build nodejs-app-example`.
3. Publish it: in `gateway/http/conf.d/<app>.conf` use
   `proxy_pass http://nodejs-app-example:8080`.

The Dockerfile installs the production dependencies with
`npm ci --omit=dev` (for Linux, with build tools for native addons in a
separate stage), copies `source/` to `/app` and runs `node .` (Node.js 24),
which starts the file in `"main"` of `package.json`.

- The app must listen on `process.env.PORT` (`NODEJS_APP_EXAMPLE_PORT`, 8080)
  on all interfaces: a server bound to `localhost` is unreachable from other
  containers.
- `NODEJS_APP_EXAMPLE_NODE_ENV=production`. Other settings: add a
  `NODEJS_APP_EXAMPLE_*` variable to `.env` and pass it in `compose.yaml`; a
  local `.env` in `source/` is not copied into the image.
- `devDependencies` are not installed: anything needed at runtime belongs in
  `dependencies`.

## Monitoring

| Tool | What it shows | URL (through the VPN) |
|---|---|---|
| **PMM** | Server resources, MySQL / PostgreSQL dashboards and replication, Query Analytics, per-container metrics, alerts | `http://pmm-server:8080` (user `admin`) |
| **Dozzle** | Live logs of every container | `http://dozzle:8080` |
| **Portainer** | Containers, images, volumes and networks; start / stop / restart, console, stats | `http://portainer:8080` (user `admin`) |

- The PMM client registers the server as a node named after its hostname, and
  its cAdvisor as `cadvisor-<hostname>`.
- With `MONITOR_DATABASES=true` it also registers whichever databases are
  running. Restart `pmm-client` to register a database started later.
- Portainer has full control of Docker on the server. Use it to inspect and
  operate containers; change the deployment itself in this repository, since
  `docker compose up -d` replaces containers edited in Portainer. The `admin`
  password comes from `PORTAINER_ADMIN_PASSWORD` on the first start only
  (at least 12 characters); later, change it in the UI.

### Custom dashboards

**Databases Overview** and **Containers Overview**, under
**Dashboards → Custom**, are provisioned from
`monitoring/pmm/dashboards/Custom/`. PMM re-reads that folder every 60 seconds,
so edit the JSON files rather than the UI.

PostgreSQL replica lag comes from a custom query
(`monitoring/client/custom-queries/postgresql/replica-lag.yml`, metric
`pg_replica_lag_seconds`): 0 when the replica has replayed everything it
received, so it stays at 0 while the primary has no writes. Restart
`pmm-client` after changing it.

### Alerts

Configured in the PMM UI (**Alerting**): contact points, alert rules and
notification policies. They are stored in the `pmm-data` volume. Two channels
are set up from `.env`:

| Channel | `.env` | Result |
|---|---|---|
| Email | `ALERT_EMAIL_ENABLED=true` and `SMTP_*` | PMM can send email; create an email contact point in the UI |
| Slack | `ALERT_SLACK_ENABLED=true` and `SLACK_WEBHOOK_URL` | Contact point **Slack** created on start (`monitoring/pmm/alerting/slack.yaml`) |

Restart `pmm-server` after changing them (`docker compose up -d pmm-server`).
Then choose which alerts go where in **Alerting → Notification policies**, and
use **Test** on the contact point to check it. The Slack contact point is
read-only in the UI. Before setting `ALERT_SLACK_ENABLED=false`, remove Slack
from the notification policies; otherwise it is kept and `pmm-server` logs a
warning.

Cap Docker log size on the server in `/etc/docker/daemon.json`:

```json
{ "log-driver": "json-file", "log-opts": { "max-size": "50m", "max-file": "5" } }
```

## Operations

### Rebuild a replica

```sh
docker compose rm -sf mysql-replica-db
docker volume rm <PROJECT_NAME>_mysql-replica-data
docker compose up -d mysql-replica-db
docker compose restart pmm-client
```

Same for `postgres-replica-db` / `<PROJECT_NAME>_postgres-replica-data`.

## Production checklist

- [ ] Real passwords in `.env`
- [ ] `VPN_HOST` set to the server's public IP or domain
- [ ] Firewall: only `51820/udp`, `80/tcp` and `443/tcp` open (replica
      servers: no inbound ports)
- [ ] No `compose.override.yaml` publishing internal tools
- [ ] Certificates in `gateway/http/certs/` for every public app
- [ ] Docker log rotation configured
- [ ] Replication checked
- [ ] PMM alert rules and contact points configured and tested
- [ ] `COMPOSE_PROFILES` set to this server's roles
- [ ] `MYSQL_BACKUP_DIR` / `POSTGRES_BACKUP_DIR` on a separate disk, backup
      services healthy, and a test restore done
- [ ] Off-site copy of the backup directories
- [ ] Apps: exports in `source/` (and JREs in `jre.tar.gz`), app variables
      in `.env`, apps running
