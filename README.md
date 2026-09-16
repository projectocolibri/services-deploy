# Services deploy

Docker Compose deployment of shared infrastructure: MySQL (Percona Server) and
PostgreSQL (Percona Distribution), each with a read-only replica, a VPN and an
HTTP gateway, and monitoring (PMM and Dozzle).

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
  PMM, Dozzle, admin panels
```

## Requirements

- Docker Engine with Docker Compose v2.24 or later
- Linux server (Docker Desktop works for development)
- 2+ CPU cores and 4+ GB RAM for PMM Server

## Quick start

```sh
git clone <repository> services-deploy
cd services-deploy

touch .env gateway/.env monitoring/.env databases/mysql/.env databases/postgres/.env

export COMPOSE_ENV_FILES=.env.dev,.env

docker compose up -d
docker compose ps
```

The replicas clone their primary on the first start, so give them a minute
(the MySQL replica restarts once after cloning). Before deploying to a real
server, change the default passwords and set `VPN_HOST`.

`COMPOSE_ENV_FILES` makes Compose load the global `.env.dev` and `.env`. Set it
once per machine instead of in every shell: add the `export` line to
`~/.bashrc` on Linux, or run `setx COMPOSE_ENV_FILES ".env.dev,.env"` on
Windows and open a new terminal. Without it, Compose stops with
`project name must not be empty`.

## Repository layout

```
.env.dev                     global: project name, network, time zone
compose.yaml                 includes every stack, defines the network
gateway/
  vpn/host/                  WireGuard VPN server (server with the primaries)
  vpn/client/                WireGuard peer for replica-only servers
  http/                      nginx for public apps (conf.d/, certs/)
monitoring/
  pmm/                       PMM Server and custom dashboards
  client/                    PMM client and cAdvisor
  logs/                      Dozzle
databases/
  mysql/
    master/                  primary, read/write (mysql-db)
    replica/                 read-only replica (mysql-replica-db)
    admin/                   phpMyAdmin
  postgres/
    master/                  primary, read/write (postgres-db)
    replica/                 read-only replica (postgres-replica-db)
    admin/                   pgAdmin
```

Every folder with a `compose.yaml` is a stack. Stacks list their sub-stacks
with `include`; remove an entry to leave that part out. No service depends on
another stack: each one waits for what it needs by itself.

## Configuration

The root and every stack load two env files, in order:

| File | Committed | Purpose |
|---|---|---|
| `.env.dev` | yes | Development defaults |
| `.env` | no | Local overrides and secrets (wins over `.env.dev`) |

The root files are global: they are loaded through `COMPOSE_ENV_FILES`, reach
every stack and win over the stack files for the same key.

| Global variable | Default | Purpose |
|---|---|---|
| `PROJECT_NAME` | `services` | Prefix of containers and volumes. Renaming it orphans existing volumes. |
| `NETWORK_NAME` | `services-internal-network` | Internal Docker network |
| `NETWORK_SUBNET` | `172.30.0.0/16` | Its subnet, also routed through the VPN |
| `VPN_DNS_IP` | `172.30.255.2` | Fixed address of the VPN host container, DNS for service names across servers |
| `TZ` | `Etc/UTC` | Time zone of every container |

UTC is recommended for `TZ`: PMM, Grafana and Dozzle show times in the
browser's time zone anyway. pmm-client, cAdvisor and Dozzle have no time zone
data and stay on UTC, and PostgreSQL keeps the zone it was initialized with.

Production values to set:

| Stack | Variables |
|---|---|
| `gateway` | `VPN_HOST`, `VPN_PEERS` |
| `databases/mysql` | `MYSQL_ROOT_PASSWORD`, `MYSQL_USER`, `MYSQL_USER_PASSWORD`, `MYSQL_REPLICATION_PASSWORD`, `MYSQL_MONITOR_PASSWORD` |
| `databases/postgres` | `POSTGRES_PASSWORD`, `POSTGRES_REPLICATION_PASSWORD`, `POSTGRES_MONITOR_PASSWORD`, `ADMIN_EMAIL`, `ADMIN_PASSWORD` |
| `monitoring` | `PMM_ADMIN_PASSWORD`, `MONITOR_MYSQL_PASSWORD`, `MONITOR_POSTGRES_PASSWORD`, `SMTP_*` |

The `MONITOR_*` credentials must match the `*_MONITOR_*` values of the database
stacks.

For local tests, a `compose.override.yaml` (not committed) can publish internal
tools on `127.0.0.1`:

```yaml
services:
  pmm-server:
    ports: ["127.0.0.1:8443:8443"]
  dozzle:
    ports: ["127.0.0.1:8888:8080"]
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

1. Add a peer for the new server in `gateway/.env`, e.g.
   `VPN_PEERS=admin,replica1`, and run `docker compose up -d vpn`.
2. Copy `gateway/vpn/host/config/peer_replica1/peer_replica1.conf` to the new
   server (it contains that server's private key).

On the **replica server** (clone of this repository):

1. Save the file as `gateway/vpn/client/config/peer.conf`.
2. In the root `.env`, use a different subnet than the VPN host, e.g.
   `NETWORK_SUBNET=172.31.0.0/16`. The client refuses to start if a tunnel
   route overlaps a local one.
3. In `gateway/compose.yaml`, comment out `vpn/host` and uncomment
   `vpn/client`. Remove the monitoring stack from `compose.yaml`, and include
   only `replica/` in `databases/mysql/compose.yaml` and
   `databases/postgres/compose.yaml`.
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

Public web apps. Requests for unknown hosts are refused.

1. Copy `gateway/http/conf.d/app.conf.example` to `<app>.conf` and set the
   domain and upstream (`proxy_pass http://<service>:<port>`).
2. Put the certificate in `gateway/http/certs/<domain>/fullchain.pem` and
   `privkey.pem`.
3. Reload: `docker compose exec http nginx -s reload`.

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
  it runs on the same machine and is not a backup.

Replication state:

```sh
docker compose exec mysql-replica-db mysql -uroot -p -e "SHOW REPLICA STATUS\G"
docker compose exec postgres-replica-db psql -U postgres -c "SELECT status, sender_host FROM pg_stat_wal_receiver"
docker compose exec postgres-db psql -U postgres -c "SELECT client_addr, state, replay_lag FROM pg_stat_replication"
```

### Admin panels

phpMyAdmin (`http://mysql-admin`) and pgAdmin (`http://postgres-admin`) list
the servers in `ADMIN_HOSTS` / `ADMIN_HOSTS_LABELS`.

## Monitoring

| Tool | What it shows | URL (through the VPN) |
|---|---|---|
| **PMM** | Server resources, MySQL / PostgreSQL dashboards and replication, Query Analytics, per-container metrics, alerts | `https://pmm-server:8443` (user `admin`) |
| **Dozzle** | Live logs of every container | `http://dozzle:8080` |

- The PMM client registers the server as a node named after its hostname, and
  its cAdvisor as `cadvisor-<hostname>`.
- With `MONITOR_DATABASES=true` it also registers whichever databases are
  running. Restart `pmm-client` to register a database started later.

### Custom dashboards

**Databases Overview** and **Containers Overview**, under
**Dashboards → Custom**, are provisioned from
`monitoring/pmm/dashboards/Custom/`. PMM re-reads that folder every 60 seconds,
so edit the JSON files rather than the UI.

### Alerts

Configured in the PMM UI (**Alerting**): contact points (email needs
`ALERT_EMAIL_ENABLED=true` and the `SMTP_*` settings), alert rules and
notification policies. They are stored in the `pmm-data` volume.

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

- [ ] Real passwords in every `.env`
- [ ] `VPN_HOST` set to the server's public IP or domain
- [ ] Firewall: only `51820/udp`, `80/tcp` and `443/tcp` open (replica
      servers: no inbound ports)
- [ ] No `compose.override.yaml` publishing internal tools
- [ ] Certificates in `gateway/http/certs/` for every public app
- [ ] Docker log rotation configured
- [ ] Replication checked
- [ ] PMM alert rules and contact points configured and tested
- [ ] Backups configured
