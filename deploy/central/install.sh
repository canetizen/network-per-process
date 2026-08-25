#!/usr/bin/env bash
#
# Description: Central installer: deploys the ebpf_exporter node agent to every node in nodes.txt over SSH and registers the scrape job in the central Prometheus.
# Created by: Mustafa Can Caliskan
# Date: 2026-08-24
#
# Run this on the machine that hosts the central Prometheus (and Grafana),
# from an unpacked bundle:
#
#   ./install.sh /path/to/prometheus.yml [grafana-dashboards-dir]
#   ./install.sh -remove
#
# For each node in nodes.txt the script connects as root (key based), copies
# the bundle into a staging directory and runs node-install.sh there. Failures
# on one node do not stop the rest; a summary is printed at the end.
#
# Unless -remove is given, the prometheus.yml path is required. If the file
# does not already contain a job named ebpf-process-network, a timestamped
# backup is made and a new job with all listed targets is appended to
# scrape_configs. An existing job is left untouched. The job is activated by
# restarting the prometheus systemd unit (sudo systemctl restart prometheus).
#
# If the grafana dashboards directory is given as the second argument,
# grafana/dashboard.json is copied there so the dashboard shows up without a
# manual import.
#
# SSH_USER overrides the remote user (default root).
# SSH_PORT overrides the SSH port (default 22).
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODES_FILE="${SCRIPT_DIR}/nodes.txt"
PROMETHEUS_YML=""
GRAFANA_DIR=""
REMOVE=0
JOB_NAME="ebpf-process-network"
SSH_USER="${SSH_USER:-root}"
SSH_PORT="${SSH_PORT:-22}"

usage() {
    echo "usage: $0 <prometheus.yml> [grafana-dashboards-dir] | $0 -remove" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -remove)
            REMOVE=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "unknown option: $1" >&2
            usage
            exit 1
            ;;
        *)
            if [[ -z "${PROMETHEUS_YML}" ]]; then
                PROMETHEUS_YML="$1"
            elif [[ -z "${GRAFANA_DIR}" ]]; then
                GRAFANA_DIR="$1"
            else
                echo "unexpected argument: $1" >&2
                usage
                exit 1
            fi
            ;;
    esac
    shift
done

if [[ "${REMOVE}" == "0" && -z "${PROMETHEUS_YML}" ]]; then
    usage
    exit 1
fi

if [[ ! -f "${NODES_FILE}" ]]; then
    echo "nodes file not found: ${NODES_FILE}" >&2
    exit 1
fi

# host:port -> host
node_host() { printf '%s\n' "$1" | cut -d: -f1; }

# host:port -> port (default 9435)
node_port() {
    local entry="$1"
    if [[ "${entry}" == *:* ]]; then
        printf '%s\n' "${entry##*:}"
    else
        echo 9435
    fi
}

# Prints the node entries, one per line, skipping blanks and comments.
read_nodes() {
    awk '!/^[[:space:]]*(#|$)/ { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }' "${NODES_FILE}"
}

mapfile -t NODES < <(read_nodes)
if [[ ${#NODES[@]} -eq 0 ]]; then
    echo "no nodes listed in ${NODES_FILE}" >&2
    exit 1
fi

if ! command -v ssh >/dev/null; then
    echo "ssh is not installed on this machine" >&2
    exit 1
fi

# Note: ssh takes the port with -p, so it is passed at each call site.
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new)

# Copies the bundle into the node's staging directory over a single ssh
# connection. scp is avoided: since OpenSSH 9.0 it uses the SFTP protocol,
# which rejects the "dir/." source form.
copy_bundle() {
    local host="$1" staging="$2"
    tar -cf - -C "${SCRIPT_DIR}" . | ssh -p "${SSH_PORT}" "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "tar -xf - -C '${staging}'"
}

# Copies the bundle to the node's staging directory and runs node-install.sh.
install_node() {
    local entry="$1"
    local host port staging
    host="$(node_host "${entry}")"
    port="$(node_port "${entry}")"
    staging="$(ssh -p "${SSH_PORT}" "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "mktemp -d /var/tmp/ebpf-exporter-install.XXXXXX")" || return 1

    echo "==> ${entry} (staging ${staging})"
    if ! copy_bundle "${host}" "${staging}"; then
        ssh -p "${SSH_PORT}" "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "rm -rf '${staging}'" || true
        return 1
    fi
    if ! ssh -p "${SSH_PORT}" "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "OFFLINE=1 bash '${staging}/node-install.sh'"; then
        ssh -p "${SSH_PORT}" "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "rm -rf '${staging}'" || true
        return 1
    fi
    ssh -p "${SSH_PORT}" "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "rm -rf '${staging}'"
    return 0
}

# Stops the unit and removes all installed files on the node.
remove_node() {
    local entry="$1"
    local host staging
    host="$(node_host "${entry}")"
    echo "==> ${entry}"
    # Stage the bundle so node-install.sh is available, then uninstall.
    staging="$(ssh -p "${SSH_PORT}" "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "mktemp -d /var/tmp/ebpf-exporter-install.XXXXXX")" || return 1
    if ! copy_bundle "${host}" "${staging}"; then
        ssh -p "${SSH_PORT}" "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "rm -rf '${staging}'" || true
        return 1
    fi
    if ! ssh -p "${SSH_PORT}" "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "REMOVE=1 bash '${staging}/node-install.sh'"; then
        ssh -p "${SSH_PORT}" "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "rm -rf '${staging}'" || true
        return 1
    fi
    ssh -p "${SSH_PORT}" "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "rm -rf '${staging}'"
    return 0
}

ok=()
failed=()
for entry in "${NODES[@]}"; do
    if [[ "${REMOVE}" == "1" ]]; then
        if remove_node "${entry}"; then
            ok+=("${entry}")
        else
            failed+=("${entry}")
        fi
    else
        if install_node "${entry}"; then
            ok+=("${entry}")
        else
            failed+=("${entry}")
        fi
    fi
done

echo
echo "summary: ${#ok[@]} ok, ${#failed[@]} failed"
for entry in "${failed[@]}"; do
    echo "  failed: ${entry}"
done
if [[ ${#failed[@]} -gt 0 ]]; then
    exit 1
fi

if [[ "${REMOVE}" == "1" ]]; then
    echo "nodes cleaned; prometheus.yml was left untouched"
    exit 0
fi

# ---------------------------------------------------------------- prometheus

if [[ ! -f "${PROMETHEUS_YML}" ]]; then
    echo "prometheus config not found: ${PROMETHEUS_YML}" >&2
    exit 1
fi

if grep -qE "^[[:space:]]*-?[[:space:]]*job_name:[[:space:]]*${JOB_NAME}[[:space:]]*$" "${PROMETHEUS_YML}"; then
    echo "job ${JOB_NAME} already present in ${PROMETHEUS_YML}; leaving it untouched"
else
    backup="${PROMETHEUS_YML}.$(date +%Y%m%d-%H%M%S).bak"
    cp "${PROMETHEUS_YML}" "${backup}"
    echo "backup written: ${backup}"

    # The job block is indented to match the existing scrape_configs entries.
    indent="    "
    if grep -qE '^[[:space:]]*scrape_configs:' "${PROMETHEUS_YML}"; then
        first_entry_indent="$(awk '
            /^[[:space:]]*scrape_configs:/ { found=1; next }
            found && /^[[:space:]]*-[[:space:]]/ { match($0, /^[[:space:]]*/); print substr($0, 1, RLENGTH); exit }
        ' "${PROMETHEUS_YML}")"
        if [[ -n "${first_entry_indent}" ]]; then
            indent="${first_entry_indent}"
        fi
    fi

    job="${indent}- job_name: ${JOB_NAME}"$'\n'
    job+="${indent}  scrape_interval: 15s"$'\n'
    job+="${indent}  static_configs:"$'\n'
    job+="${indent}    - targets:"$'\n'
    for entry in "${NODES[@]}"; do
        job+="${indent}      - $(node_host "${entry}"):$(node_port "${entry}")"$'\n'
    done
    job+="${indent}  relabel_configs:"$'\n'
    job+="${indent}    - source_labels: [__address__]"$'\n'
    job+="${indent}      regex: '([^:]+)(:[0-9]+)?'"$'\n'
    job+="${indent}      target_label: node"$'\n'
    job+="${indent}      replacement: '\${1}'"$'\n'

    if grep -qE '^[[:space:]]*scrape_configs:' "${PROMETHEUS_YML}"; then
        tmp="${PROMETHEUS_YML}.tmp.$$"
        awk -v job="${job}" '
            { print }
            /^[[:space:]]*scrape_configs:/ && !done { print job; done=1 }
        ' "${PROMETHEUS_YML}" > "${tmp}"
        mv "${tmp}" "${PROMETHEUS_YML}"
        echo "job ${JOB_NAME} appended to ${PROMETHEUS_YML}"
    else
        {
            echo "scrape_configs:"
            printf '%s' "${job}" | sed 's/^    //'
        } >> "${PROMETHEUS_YML}"
        echo "scrape_configs: created in ${PROMETHEUS_YML}"
    fi

    # Restart prometheus so the new job is picked up.
    if sudo systemctl restart prometheus; then
        echo "prometheus restarted"
    else
        echo "could not restart prometheus (sudo systemctl restart prometheus); do it yourself" >&2
        exit 1
    fi
fi

# ------------------------------------------------------------- grafana

if [[ -n "${GRAFANA_DIR}" ]]; then
    if [[ ! -d "${GRAFANA_DIR}" ]]; then
        echo "grafana dashboards directory not found: ${GRAFANA_DIR}" >&2
        exit 1
    fi
    install -m 0644 "${SCRIPT_DIR}/grafana/dashboard.json" "${GRAFANA_DIR}/dashboard.json"
    echo "dashboard copied to ${GRAFANA_DIR}/dashboard.json"
fi

echo
echo "done."
