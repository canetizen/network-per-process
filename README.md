# network-per-process

Collects per-process network traffic in a multi-node cluster with eBPF and
exposes it as Prometheus metrics.

An eBPF program hooks into the kernel's socket send/receive paths and
accumulates byte counters keyed by `(pid, protocol, process name)`.
[`ebpf_exporter`](https://github.com/cloudflare/ebpf_exporter) reads these maps
on every scrape and converts them into Prometheus counters. Nothing else runs
on the nodes; your existing central Prometheus scrapes the nodes, and Grafana
displays the dashboard included in the package.

## Metrics

| Metric | Meaning |
|---|---|
| `ebpf_exporter_process_network_tx_bytes_total` | Bytes the process wrote to sockets |
| `ebpf_exporter_process_network_rx_bytes_total` | Bytes the process read from sockets |

Labels: `pid`, `comm` (process name), `cmdline` (first 64 bytes of the command
line, see below), `proto` (`tcp`/`udp`), plus `node`, `instance`, and `job`
which Prometheus adds during scraping.

```
ebpf_exporter_process_network_tx_bytes_total{comm="etcd",cmdline="/usr/local/bin/etcd --data-dir=/var/lib/etcd",pid="15866",proto="tcp"} 892341
ebpf_exporter_process_network_rx_bytes_total{comm="coredns",cmdline="/usr/local/bin/coredns -conf /etc/coredns/Corefile",pid="18246",proto="udp"} 1320
```

### What these numbers are, and what they are not

* **They are socket-layer payload bytes**, not wire bytes. IP/TCP headers,
  retransmissions, and TSO segmentation are not counted. Running somewhat
  lower than `node_exporter`'s interface counters is expected.
* `comm` is the name of the thread group leader. So all threads of a process
  are attributed to the process, not to individual workers.
* `cmdline` is the **first 64 bytes** of the full command line shown by
  `ps -ef` (argv, read from the `mm->arg_start`/`arg_end` range). Long commands
  are truncated at 64 bytes; this can be increased via the `CMDLINE_LEN`
  constant. Kernel threads (kworker, ksoftirqd, etc.) have no `mm`, so their
  `cmdline` is left empty.
* `pid` is the **on-node** thread group id. A restarted process gets a new
  pid, and therefore a new time series is created.
* Kernel traffic that has no user process context (forwarding, NAT, drops at
  softirq time) cannot be attributed to anyone and does not appear here.

## Directory layout

```
bpf/process-network.bpf.c        eBPF program: kprobes + per-process byte maps
config/process-network.yaml      ebpf_exporter config: map -> Prometheus metric mapping
build/Dockerfile                 builder image, produces dist/process-network.bpf.o
deploy/local/                    exporter + Prometheus + Grafana for trying it on a single machine
deploy/systemd/                  unit file + node install script for bare metal / VM nodes
deploy/central/install.sh        central install script (distributes to all nodes over SSH)
deploy/nodes.txt                  node list template
deploy/prometheus/               scrape_configs to be added to the central Prometheus
grafana/dashboard.json           dashboard (install.sh copies it into the Grafana directory)
```

## Requirements

On every node you want to monitor:

* BTF-enabled Linux 5.8+ — check with `ls /sys/kernel/btf/vmlinux`. Almost all
  recent distro kernels qualify. If a node lacks BTF, fetch that kernel's BTF
  from [btfhub-archive](https://github.com/aquasecurity/btfhub-archive) and
  pass it to the exporter with `--btf.path`.
* `x86_64` or `aarch64`.
* Port `9435` reachable from the Prometheus node.

On the machine where you build: Docker (`make build-docker`), or `clang`,
`bpftool`, and `libbpf-dev` (`make build`). The build machine needs internet
access; the target environment does not, see
[Air-gapped installation](#air-gapped-installation).

Nodes do **not** need a compiler or kernel headers. The eBPF object is
relocatable thanks to CO-RE: build it once and ship the same file everywhere.

## 1. Build

```bash
make build-docker
```

This produces `dist/process-network.bpf.o` and `dist/process-network.yaml`.
These two files are the only things the nodes need besides the exporter
binary.

Try it on your own machine before shipping it out:

```bash
make run-local
curl -s localhost:9435/metrics | grep process_network | head
```

### Full stack on a single machine

To bring up the exporter, Prometheus, and a provisioned Grafana with the
dashboard together (ports are shifted so they don't clash with an existing
Prometheus/Grafana):

```bash
cd deploy/local
docker compose up -d
```

* Grafana: <http://localhost:3301/d/ebpf-process-network> (anonymous, no login)
* Prometheus: <http://localhost:9091>
* Exporter: <http://localhost:9435/metrics>

Shut it down with `docker compose down`. This stack is for trying things out
only; the steps below apply for a real installation.

## 2. Install on the nodes

### Central installation (recommended)

Copy the package produced by `make bundle` to the central server (the machine
running Prometheus + Grafana), extract it, and list the nodes to monitor in
`nodes.txt` (`host` or `host:port` per line, default port 9435):

```bash
tar xzf bundle.tar.gz
cd bundle
$EDITOR nodes.txt
./install.sh /path/to/prometheus.yml /var/lib/grafana/dashboards
```

The script SSHes (key-based) to every node in the list as `root`, copies the
bundle into a staging directory, and runs `node-install.sh` there. If a node
fails it continues with the others and prints a summary at the end.

If the `ebpf-process-network` job does not exist in `prometheus.yml`, a
timestamped backup is taken and a new job populated with the targets from the
list is added under `scrape_configs`, after which Prometheus is restarted with
`sudo systemctl restart prometheus`. If the job already exists, `prometheus.yml`
is left untouched; the restart still happens.

If you pass the Grafana dashboards directory as the second argument,
`grafana/dashboard.json` is copied there as `dashboard.json` and the dashboard
shows up without a manual import. Choose the directory to match the dashboard
directory of your Grafana setup (e.g. a provisioned directory or
`/var/lib/grafana/dashboards`).

To remove:

```bash
./install.sh -remove
```

This stops the service and deletes the files on every node in the list; it
does not touch `prometheus.yml`.

### Manual install on a single node (systemd)

Copy the repo (or just the `dist/` and `deploy/systemd/` directories) to the
node and run:

```bash
sudo ./deploy/systemd/node-install.sh
```

The script installs the static `ebpf_exporter` binary into `/usr/local/bin`,
places the probe and config under `/etc/ebpf_exporter`, and enables and starts
`ebpf-exporter.service`. It looks for the binary in this order: the
`EXPORTER_BIN` variable, an `ebpf_exporter.<arch>` file next to itself, and as
a last resort downloading it from GitHub. For environments without internet
access, see the [Air-gapped installation](#air-gapped-installation) section.

The unit does not run as root, but under a `DynamicUser` with only the
`CAP_BPF` and `CAP_PERFMON` capabilities. Verify with:

```bash
systemctl status ebpf-exporter
curl -s localhost:9435/metrics | grep process_network | head
```

To pin a specific exporter version:
`EXPORTER_VERSION=v2.5.1 sudo -E ./deploy/systemd/node-install.sh`

## 3. Point Prometheus at the nodes

The central installation script (see
[Central installation](#central-installation-recommended)) does this step
automatically. To do it by hand, add the job from
[deploy/prometheus/scrape-config.yaml](deploy/prometheus/scrape-config.yaml)
to the `scrape_configs` section of your central Prometheus, substituting the
example hostnames, then run `sudo systemctl restart prometheus`.

The relabel rule derives the `node` label from the target address. The
dashboard filters on `node`, so keep this label if you change the job.

Confirm on the Prometheus targets page that all nodes are `UP`, then query
`ebpf_exporter_process_network_tx_bytes_total` in the expression browser.

## 4. Dashboard

The central installation script copies
[grafana/dashboard.json](grafana/dashboard.json) into the Grafana dashboards
directory if you pass it as a parameter. If it wasn't copied, import it
manually: Grafana → Dashboards → New → Import → upload the file → select your
Prometheus data source.

The dashboard has `Node`, `Process`, `Protocol`, and `Top N` variables, a
per-node throughput graph, stacked top-N sent/received graphs, a protocol
breakdown, and a sortable process table.

## Air-gapped installation

The flow above reaches the internet at several points: the builder image
downloads Debian packages, and `node-install.sh` pulls the binary from GitHub
releases. Into an environment without internet access you ship **the ready
artifact package, not the repo**.

### 1. Produce the package on a machine with internet access

```bash
make build-docker
make bundle
```

`bundle.tar.gz` (~51 MB) is produced. Contents:

```
process-network.bpf.o           compiled eBPF probe (CO-RE, runs on any kernel)
process-network.yaml            exporter config
ebpf_exporter.x86_64            static exporter binary
ebpf_exporter.aarch64           static exporter binary
ebpf-exporter.service           systemd unit
install.sh                      central install script (distributes to all nodes over SSH)
node-install.sh                 single-node install/remove script
nodes.txt                       node list template
prometheus/scrape-config.yaml
grafana/dashboard.json
sha256sums.txt
```

If you only need one architecture: `make bundle BUNDLE_ARCHS=x86_64`.

### 2. Ship and verify the package

```bash
tar xzf bundle.tar.gz
cd bundle
sha256sum -c sha256sums.txt
```

### 3. Install on the nodes

**Central installation (recommended)** — copy the package to the central
server, edit `nodes.txt`, then:

```bash
./install.sh /path/to/prometheus.yml /var/lib/grafana/dashboards
```

The script SSHes to every node and installs it, adds the scrape job to
`prometheus.yml`, restarts Prometheus with `sudo systemctl restart prometheus`,
and copies the dashboard into the Grafana directory. To remove,
`./install.sh -remove`.

**Manually on a single node** — copy the package to the node and run it from
there:

```bash
sudo OFFLINE=1 ./node-install.sh
```

`OFFLINE=1` disables downloading entirely; the script takes the binary from
inside the package. If it can't find one, it errors out instead of trying to
download.

### 4. Prometheus and Grafana

The central installation script already does these steps (adding the job +
restart, copying the dashboard into the Grafana directory). If you install
manually: add the contents of `prometheus/scrape-config.yaml` to the central
Prometheus, run `sudo systemctl restart prometheus`, and import
`grafana/dashboard.json` from the Grafana UI.

### Gotchas

* **Nodes without BTF.** The probe is CO-RE, so it runs on any kernel, but if
  the node has no `/sys/kernel/btf/vmlinux` file you must supply BTF from
  outside. In an air-gapped environment you also can't reach btfhub, so ship
  the kernel's BTF file together with the package and add
  `--btf.path=/etc/ebpf_exporter/vmlinux` to the unit's `ExecStart` line.
* **The `deploy/local` demo stack is not part of the package.** If you want to
  test in the air-gapped environment too, ship the Prometheus and Grafana
  images separately:
  `docker save prom/prometheus:v3.1.0 grafana/grafana:11.5.1 -o obs-images.tar`,
  then on the other side `docker load -i obs-images.tar`. Compose will not try
  to pull if the local image exists.
* **`make build` (host build) does not work in an air-gapped environment** —
  `clang`, `bpftool`, and `libbpf-dev` must be installed. It doesn't matter:
  the probe ships pre-compiled in the package.

## Cardinality

Every `(node, pid, comm, proto)` combination is a separate time series per
direction. `cmdline` is also part of the map key, but since a given `pid`'s
command line is constant it does not create new series; it only adds 64 bytes
per key. Nodes with high process churn — CI runners, short-lived jobs, services
that fork per request — can produce a large number of series. The kernel side
is bounded (LRU map of 16384 entries per direction, see
`MAX_TRACKED_PROCESSES` in
[bpf/process-network.bpf.c](bpf/process-network.bpf.c)), but Prometheus keeps
every series for the retention period.

Both levers act inside the exporter, so Prometheus never sees extra series.
The first is the `regexp` decoder on `comm`, which drops every label set whose
process name does not match:

```yaml
- name: comm
  size: 16
  decoders:
    - name: string
    - name: regexp
      regexps:
        - ^(etcd|kube-apiserver|nginx|postgres)$
```

The second is dropping `pid` entirely and aggregating by process name. Since
the key layout is fixed by the eBPF struct, this means removing the `u32 pid`
field from `struct process_key_t` in
[bpf/process-network.bpf.c](bpf/process-network.bpf.c), removing the
corresponding label from the YAML, and rebuilding.

## Overhead

Four kprobes on the socket send/receive paths; each one does a single map
lookup and one atomic add. No per-packet events are sent to user space, and
the exporter walks the maps only at scrape time. The cost is a few hundred
nanoseconds per `sendmsg`/`recvmsg` — no measurable impact outside of a hot
path that forwards packets.

## Extending

The probes live in [bpf/process-network.bpf.c](bpf/process-network.bpf.c) and
the metric definitions in
[config/process-network.yaml](config/process-network.yaml). The two must stay
in sync: the exporter slices raw map keys into the label sizes declared in the
YAML, so every change to `struct process_key_t` needs a corresponding entry in
the label list.

If you want to attribute traffic to containers instead of processes by adding
a `cgroup` label: add a `u64` cgroup id obtained with
`bpf_get_current_cgroup_id()` to the key, add a `cgroup` label with a decoder
to the YAML, and bind-mount the `/sys/fs/cgroup` directory into the exporter
so it can resolve the ids to paths.
