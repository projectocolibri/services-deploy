#!/usr/bin/env python3
# ============================================================================
# Docker API Prometheus exporter
#
# Purpose:       Exposes per-container Docker Engine statistics to Prometheus.
# Role:          Replaces cAdvisor where Docker's overlayfs runtime prevents
#                cAdvisor from discovering individual containers.
# Prerequisites: Docker API socket mounted at /var/run/docker.sock
# Variables:     None.
# ============================================================================

import http.client
import json
import socket
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import quote


SOCKET_PATH = "/var/run/docker.sock"
CACHE = b""
CACHE_LOCK = threading.Lock()


class DockerConnection(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(SOCKET_PATH)


def docker_get(path):
    connection = DockerConnection("localhost", timeout=2)
    connection.request("GET", path)
    response = connection.getresponse()
    body = response.read()
    connection.close()
    if response.status >= 400:
        raise RuntimeError(f"Docker API returned HTTP {response.status}")
    return json.loads(body)


def escape_label(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def metric(name, labels, value):
    rendered = ",".join(
        f'{key}="{escape_label(value)}"' for key, value in labels.items()
    )
    return f"{name}{{{rendered}}} {value}\n"


def started_timestamp(value):
    if not value:
        return 0
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def collect_container(container):
    lines = []
    container_id = container["Id"]
    name = container["Names"][0].lstrip("/")
    labels = {"name": name, "id": container_id}
    stats = docker_get(f"/containers/{quote(container_id)}/stats?stream=false")
    cpu = stats.get("cpu_stats", {})
    previous_cpu = stats.get("precpu_stats", {})
    cpu_delta = cpu.get("cpu_usage", {}).get("total_usage", 0) - previous_cpu.get(
        "cpu_usage", {}
    ).get("total_usage", 0)
    system_delta = cpu.get("system_cpu_usage", 0) - previous_cpu.get(
        "system_cpu_usage", 0
    )
    online_cpus = cpu.get("online_cpus", 1) or 1
    cpu_value = cpu_delta / system_delta * online_cpus if system_delta > 0 else 0
    lines.append(metric("container_cpu_usage_seconds_total", labels, cpu_value))

    memory = stats.get("memory_stats", {})
    lines.append(
        metric("container_memory_working_set_bytes", labels, memory.get("usage", 0))
    )

    for interface in stats.get("networks", {}).values():
        lines.append(
            metric(
                "container_network_receive_bytes_total",
                labels,
                interface.get("rx_bytes", 0),
            )
        )
        lines.append(
            metric(
                "container_network_transmit_bytes_total",
                labels,
                interface.get("tx_bytes", 0),
            )
        )

    for entry in stats.get("blkio_stats", {}).get("io_service_bytes_recursive", []) or []:
        if entry.get("op", "").lower() == "read":
            lines.append(
                metric("container_fs_reads_total", labels, entry.get("value", 0))
            )
        elif entry.get("op", "").lower() == "write":
            lines.append(
                metric("container_fs_writes_total", labels, entry.get("value", 0))
            )

    inspection = docker_get(f"/containers/{quote(container_id)}/json?size=1")
    lines.append(
        metric(
            "container_fs_usage_bytes",
            labels,
            inspection.get("SizeRw", 0) or 0,
        )
    )
    lines.append(
        metric(
            "container_start_time_seconds",
            labels,
            started_timestamp(inspection.get("State", {}).get("StartedAt")),
        )
    )
    return "".join(lines)


def collect():
    containers = docker_get("/containers/json?all=0")
    with ThreadPoolExecutor(max_workers=8) as executor:
        results = executor.map(collect_container, containers)
    return "".join(results).encode()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_error(404)
            return
        with CACHE_LOCK:
            body = CACHE
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        return


def refresh_cache():
    global CACHE
    while True:
        try:
            body = collect()
            with CACHE_LOCK:
                CACHE = body
        except (OSError, ValueError, KeyError, RuntimeError):
            pass
        time.sleep(15)


threading.Thread(target=refresh_cache, daemon=True).start()
HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
