#!/usr/bin/env bash
#
# Description: Installs ebpf_exporter plus the per-process network probe on a node as a systemd unit.
# Created by: Mustafa Can Caliskan
# Date: 2026-08-23
#
# Runs on a single node. To install a list of nodes at once, use the central
# installer (deploy/central/install.sh) from the bundle instead.
#
# Works both from a checked out repo (artifacts in dist/) and from an unpacked
# offline bundle (artifacts next to this script). The exporter binary is taken
# from EXPORTER_BIN, then from a bundled ebpf_exporter.<arch>, and only as a
# last resort downloaded from GitHub. Set OFFLINE=1 to forbid the download.
#
# With REMOVE=1 the unit is stopped and disabled and all installed files are
# removed; the central installer runs this over SSH to uninstall a node.
#

set -euo pipefail

EXPORTER_VERSION="${EXPORTER_VERSION:-v2.5.1}"
CONFIG_DIR="${CONFIG_DIR:-/etc/ebpf_exporter}"
BIN_PATH="${BIN_PATH:-/usr/local/bin/ebpf_exporter}"
EXPORTER_BIN="${EXPORTER_BIN:-}"
OFFLINE="${OFFLINE:-0}"
REMOVE="${REMOVE:-0}"
UNIT_PATH="/etc/systemd/system/ebpf-exporter.service"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Candidate locations for the compiled probe and its config, in priority order.
SEARCH_DIRS=(
    "${SCRIPT_DIR}"
    "${SCRIPT_DIR}/../../dist"
)

# Prints the full path of the first candidate directory holding the given file.
find_artifact() {
    local name="$1" dir
    for dir in "${SEARCH_DIRS[@]}"; do
        if [[ -f "${dir}/${name}" ]]; then
            (cd "${dir}" && printf '%s/%s\n' "$(pwd)" "${name}")
            return 0
        fi
    done
    return 1
}

if [[ ${EUID} -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
fi

if [[ "${REMOVE}" == "1" ]]; then
    systemctl disable --now ebpf-exporter.service 2>/dev/null || true
    systemctl daemon-reload
    rm -f "${UNIT_PATH}"
    rm -f "${BIN_PATH}"
    rm -rf "${CONFIG_DIR}"
    echo "removed"
    exit 0
fi

arch="$(uname -m)"
case "${arch}" in
    x86_64 | aarch64) ;;
    *)
        echo "unsupported architecture: ${arch}" >&2
        exit 1
        ;;
esac

if [[ ! -r /sys/kernel/btf/vmlinux ]]; then
    echo "kernel BTF is missing, CO-RE programs cannot be loaded on this node" >&2
    echo "supply a matching BTF file and add --btf.path to the unit's ExecStart" >&2
    exit 1
fi

if ! probe="$(find_artifact process-network.bpf.o)"; then
    echo "process-network.bpf.o not found in ${SEARCH_DIRS[*]}" >&2
    echo "run 'make build-docker' on a machine with internet, or unpack the bundle" >&2
    exit 1
fi

if ! probe_config="$(find_artifact process-network.yaml)"; then
    echo "process-network.yaml not found in ${SEARCH_DIRS[*]}" >&2
    exit 1
fi

if ! unit="$(find_artifact ebpf-exporter.service)"; then
    echo "ebpf-exporter.service not found in ${SEARCH_DIRS[*]}" >&2
    exit 1
fi

if [[ -z "${EXPORTER_BIN}" ]]; then
    EXPORTER_BIN="$(find_artifact "ebpf_exporter.${arch}" || true)"
fi

if [[ -n "${EXPORTER_BIN}" ]]; then
    echo "using bundled exporter binary ${EXPORTER_BIN}"
    install -m 0755 "${EXPORTER_BIN}" "${BIN_PATH}"
elif [[ "${OFFLINE}" == "1" ]]; then
    echo "no exporter binary found and OFFLINE=1, refusing to download" >&2
    exit 1
else
    url="${EXPORTER_BASE_URL:-https://github.com/cloudflare/ebpf_exporter/releases/download/${EXPORTER_VERSION}}/ebpf_exporter.${arch}"
    echo "downloading ebpf_exporter ${EXPORTER_VERSION} for ${arch}"
    curl -sfL --retry 3 -o "${BIN_PATH}.tmp" "${url}"
    chmod 0755 "${BIN_PATH}.tmp"
    mv "${BIN_PATH}.tmp" "${BIN_PATH}"
fi

install -d -m 0755 "${CONFIG_DIR}"
install -m 0644 "${probe}" "${CONFIG_DIR}/process-network.bpf.o"
install -m 0644 "${probe_config}" "${CONFIG_DIR}/process-network.yaml"
install -m 0644 "${unit}" "${UNIT_PATH}"

systemctl daemon-reload
systemctl enable ebpf-exporter.service
# Restart so an existing installation picks up the new probe and config.
systemctl restart ebpf-exporter.service

echo "installed; metrics at http://$(hostname -f):9435/metrics"
