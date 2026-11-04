#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# install_nvidia_nsight_perf.sh — install nvidia-nsight-perf as a systemd unit with
# CAP_PERFMON ambient capability, so the service can run as the dedicated
# nvidia-nsight-perf system account on a shared box.
#
# Usage:
#   sudo ./install_nvidia_nsight_perf.sh /path/to/nvidia-nsight-perf       # install
#   sudo ./install_nvidia_nsight_perf.sh /path/... --force                 # re-install over existing
#   sudo ./install_nvidia_nsight_perf.sh --uninstall                       # uninstall
#   sudo ./install_nvidia_nsight_perf.sh --status                          # status
# end-usage
#
# Pass the absolute path to the nvidia-nsight-perf binary directly. The
# NvPerf libs have to sit beside it, as they do in the SDK's
# nsight-perf-daemon/bin/. The script doesn't care about the layout above that.
#
# Re-running with the binary path while the service is already installed
# (i.e. the unit file at /etc/systemd/system/nvidia-nsight-perf.service
# exists) is treated as an accident and refused. Pass --force to override
# and rewrite the unit. --uninstall and --status are always idempotent and
# do not require --force.
#
# Connect admission is the Router's YAML securityPolicy, not OS groups.
# --uninstall removes the unit, this script's tmpfiles fragment, and stale
# router.lock / router.*/ under /run/nvidia/nsight-perf plus a stale
# /run/nvidia/nvtx/nvtx-cuda.yaml; it leaves the nvidia-nsight-perf account, any
# /etc/tmpfiles.d override, and the runtime directories themselves.

set -euo pipefail

SERVICE_NAME="nvidia-nsight-perf"
SERVICE_USER="nvidia-nsight-perf"
SERVICE_GROUP="nvidia-nsight-perf"
SERVICE_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
RUNTIME_DIR="/run/nvidia/nsight-perf"
# Global-scope NVTX marker; CreateNvtxCudaYaml treats a failed write as fatal.
NVTX_RUNTIME_DIR="/run/nvidia/nvtx"
NVTX_MARKER="$NVTX_RUNTIME_DIR/nvtx-cuda.yaml"
TMPFILES_CONF="/usr/lib/tmpfiles.d/${SERVICE_NAME}.conf"
TMPFILES_OVERRIDE="/etc/tmpfiles.d/${SERVICE_NAME}.conf"
TMPFILES_OWNED_HEADER="# Created by install_nvidia_nsight_perf.sh"

# Pull --force out of the args before dispatch so it can sit anywhere
# on the command line. Other flags are processed positionally below.
FORCE=0
_filtered_args=()
for _arg in "$@"; do
    case "$_arg" in
        --force) FORCE=1 ;;
        *)       _filtered_args+=("$_arg") ;;
    esac
done
set -- "${_filtered_args[@]+"${_filtered_args[@]}"}"
unset _filtered_args _arg

usage() {
    sed -n '/^# Usage:/,/^# end-usage$/p' "$0" | sed '/^# end-usage$/d; s/^# \{0,1\}//'
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: this script must be run as root (use sudo)." >&2
        exit 1
    fi
}

# tmpfiles 'd' does not touch contents; stale owners persist until reboot.
# Callers must stop the service first.
clear_runtime_contents() {
    if [[ -d "$RUNTIME_DIR" ]]; then
        echo "Clearing stale entries under $RUNTIME_DIR..."
        rm -rf "$RUNTIME_DIR"/router.lock "$RUNTIME_DIR"/router.*/
    fi
    # tmpfiles 'd' will not re-own a leftover marker (often root from a hand-run daemon).
    if [[ -e "$NVTX_MARKER" || -L "$NVTX_MARKER" ]]; then
        echo "Clearing stale $NVTX_MARKER..."
        rm -f "$NVTX_MARKER" || true
    fi
}

cmd_status() {
    echo "=== systemd unit ==="
    if [[ -e "$SERVICE_UNIT" || -L "$SERVICE_UNIT" ]]; then
        systemctl status "${SERVICE_NAME}.service" --no-pager || true
        # status omits the restart count, so a daemon that crashed and came back looks healthy.
        systemctl show -p Restart -p NRestarts "${SERVICE_NAME}.service" || true
    else
        echo "(not installed: $SERVICE_UNIT missing)"
    fi
    echo
    echo "=== service user ==="
    if id "$SERVICE_USER" &>/dev/null; then
        id "$SERVICE_USER"
    else
        echo "(user $SERVICE_USER does not exist)"
    fi
    echo
    echo "=== tmpfiles ==="
    if [[ -e "$TMPFILES_CONF" || -L "$TMPFILES_CONF" ]]; then
        echo "# $TMPFILES_CONF"
        cat "$TMPFILES_CONF" || true
    else
        echo "(not installed: $TMPFILES_CONF missing)"
    fi
    if [[ -e "$TMPFILES_OVERRIDE" || -L "$TMPFILES_OVERRIDE" ]]; then
        echo
        echo "# $TMPFILES_OVERRIDE (takes precedence)"
        cat "$TMPFILES_OVERRIDE" || true
    fi
    echo
    echo "=== runtime directory ==="
    local nvidia_dir
    nvidia_dir="$(dirname "$RUNTIME_DIR")"
    stat -c '%A %a %U:%G %n' "$nvidia_dir" 2>/dev/null || echo "(not present: $nvidia_dir)"
    # Checked by mode, not with -x: root can enter a 0700 directory, so -x would hide the problem under sudo.
    local nvidia_mode
    nvidia_mode="$(stat -c '%a' "$nvidia_dir" 2>/dev/null || echo 755)"
    if (( (8#$nvidia_mode & 1) == 0 )); then
        echo "($nvidia_dir is mode $nvidia_mode, so non-root clients are refused at the directory and report it as a policy denial)"
    fi
    if [[ -d "$RUNTIME_DIR" ]]; then
        stat -c '%A %a %U:%G %n' "$RUNTIME_DIR" || true
        echo
        echo "=== sockets ==="
        local sock_found=0
        local have_getfacl=0
        command -v getfacl >/dev/null 2>&1 && have_getfacl=1
        local sock
        for sock in \
            "$RUNTIME_DIR/router.provider/.sock" \
            "$RUNTIME_DIR/router.observer/.sock" \
            "$RUNTIME_DIR/router.controller/.sock"; do
            if [[ -e "$sock" ]]; then
                if [[ "$sock_found" -eq 0 && "$have_getfacl" -eq 0 ]]; then
                    echo "(getfacl not found; install the acl package to show named-principal socket ACLs)"
                fi
                sock_found=1
                if [[ "$have_getfacl" -eq 1 ]]; then
                    getfacl -p "$sock" || true
                else
                    stat -c '%A %a %U:%G %n' "$sock" || true
                fi
            fi
        done
        if [[ "$sock_found" -eq 0 ]]; then
            echo "(no router.*/.sock present — is the service running?)"
        fi
    elif [[ -d "$nvidia_dir" && ! -x "$nvidia_dir" ]]; then
        echo "(cannot inspect $RUNTIME_DIR from here)"
    else
        echo "(not present: $RUNTIME_DIR — created by systemd-tmpfiles)"
    fi
    echo
    echo "=== nvtx marker ==="
    if [[ -d "$NVTX_RUNTIME_DIR" ]]; then
        stat -c '%A %a %U:%G %n' "$NVTX_RUNTIME_DIR" || true
        if [[ -e "$NVTX_MARKER" || -L "$NVTX_MARKER" ]]; then
            stat -c '%A %a %U:%G %n' "$NVTX_MARKER" || true
        else
            echo "(no marker at $NVTX_MARKER — expected unless a global Router is running)"
        fi
    else
        echo "(not present: $NVTX_RUNTIME_DIR — created by systemd-tmpfiles)"
    fi
}

cmd_uninstall() {
    require_root
    if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        echo "Stopping ${SERVICE_NAME}.service..."
        systemctl stop "${SERVICE_NAME}.service"
    fi
    if [[ -e "$SERVICE_UNIT" || -L "$SERVICE_UNIT" ]]; then
        echo "Disabling ${SERVICE_NAME}.service..."
        systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
        rm -f "$SERVICE_UNIT"
        systemctl daemon-reload
        echo "Removed $SERVICE_UNIT"
    else
        echo "$SERVICE_UNIT not present; nothing to remove."
    fi
    # Install created these, so uninstall clears them; leaving them behind is
    # what makes the next install fail on a stale owner.
    clear_runtime_contents
    if [[ -e "$TMPFILES_CONF" || -L "$TMPFILES_CONF" ]]; then
        if [[ "$(head -n 1 "$TMPFILES_CONF")" == "$TMPFILES_OWNED_HEADER" ]]; then
            echo "Removing $TMPFILES_CONF..."
            rm -f "$TMPFILES_CONF"
        else
            echo "Leaving $TMPFILES_CONF in place (not created by this script)."
        fi
    fi
    if id "$SERVICE_USER" &>/dev/null; then
        echo "Leaving service user $SERVICE_USER in place; remove by hand if unused."
    fi
    echo "Uninstall complete. Note: $RUNTIME_DIR and $NVTX_RUNTIME_DIR persist until reboot (tmpfs)."
}

cmd_install() {
    local arg="$1"
    require_root

    # Second-invocation guard. If anything already exists at the unit
    # path this is almost certainly a re-run by accident; bail
    # before rewriting. --force overrides that. A directory is always a
    # hard error: we cannot write a unit file over it.
    if [[ -d "$SERVICE_UNIT" ]]; then
        echo "ERROR: $SERVICE_UNIT is a directory; refusing to install over it." >&2
        exit 1
    fi
    if [[ ( -e "$SERVICE_UNIT" || -L "$SERVICE_UNIT" ) && "$FORCE" -ne 1 ]]; then
        echo "ERROR: $SERVICE_UNIT already exists; NVIDIA Nsight Perf service appears to be installed." >&2
        echo "       Re-run with --force to overwrite the unit, or --uninstall first." >&2
        echo "       Use --status to inspect the current installation." >&2
        exit 1
    fi

    # Accept either a path to the binary itself or a directory containing it.
    # If a directory is passed, try a couple of well-known SDK sub-paths; refuse
    # if none match (so the systemd unit's ExecStart never ends up pointing at
    # a directory by accident).
    local binary=""
    local candidate
    if [[ -f "$arg" ]]; then
        binary="$arg"
    elif [[ -d "$arg" ]]; then
        for candidate in \
            "$arg/nvidia-nsight-perf" \
            "$arg/nsight-perf-daemon/bin/nvidia-nsight-perf" \
            "$arg/bin/nvidia-nsight-perf"; do
            if [[ -f "$candidate" ]]; then
                binary="$candidate"
                break
            fi
        done
    fi

    if [[ ! -f "$binary" || ! -x "$binary" ]]; then
        echo "ERROR: could not locate an executable nvidia-nsight-perf binary at or under '$arg'." >&2
        echo "       Pass the absolute path to the binary itself, e.g.:" >&2
        echo "         sudo $0 /path/to/SDK/nsight-perf-daemon/bin/nvidia-nsight-perf" >&2
        exit 1
    fi

    # Resolve to absolute path so the systemd unit ExecStart is correct
    # regardless of where the script was invoked from.
    binary="$(readlink -f -- "$binary")"

    # The service resolves its default metric document beside its own binary. A binary copied away from
    # that document starts cleanly and then collects nothing, which is only visible in the service log.
    local metricConfigDocument="$(dirname -- "$binary")/ReducedOverview.config"
    if [[ ! -f "$metricConfigDocument" ]]; then
        echo "ERROR: '$metricConfigDocument' is missing." >&2
        echo "       The service reads it for its default GPU PM metric sets, and collects nothing" >&2
        echo "       without it. Install the binary from the SDK layout rather than copying it alone." >&2
        exit 1
    fi

    # The unit's ExecStartPre line needs an absolute path, so resolve it before
    # anything is written and fail here rather than at first start.
    local tmpfiles_bin
    tmpfiles_bin="$(command -v systemd-tmpfiles || true)"
    if [[ "$tmpfiles_bin" != /* ]]; then
        echo "ERROR: could not find systemd-tmpfiles on PATH." >&2
        echo "       It provisions $RUNTIME_DIR before every start." >&2
        exit 1
    fi

    # cuInit execs this hardcoded path and loads nvidia_uvm through it. Distribution driver packages create
    # the nodes from udev instead, too late for a service that starts at boot.
    local -r nvidia_modprobe_path=/usr/bin/nvidia-modprobe
    if [[ ! -u "$nvidia_modprobe_path" || "$(stat -c %u -- "$nvidia_modprobe_path")" != 0 ]]; then
        echo "ERROR: $nvidia_modprobe_path is missing or not setuid root." >&2
        echo "       CUDA runs it to create the GPU device nodes, and without it the service fails after every reboot." >&2
        echo "       Install the nvidia-modprobe package, or the driver with the NVIDIA .run installer." >&2
        exit 1
    fi

    if ! getent group "$SERVICE_GROUP" >/dev/null; then
        echo "Creating system group $SERVICE_GROUP..."
        groupadd --system "$SERVICE_GROUP"
    fi
    if ! id "$SERVICE_USER" &>/dev/null; then
        echo "Creating system user $SERVICE_USER..."
        useradd --system --gid "$SERVICE_GROUP" --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER"
    else
        echo "Service user $SERVICE_USER already exists."
    fi

    # Fail now rather than writing a unit that cannot exec the binary.
    if ! command -v runuser >/dev/null 2>&1; then
        echo "ERROR: runuser not found; install util-linux." >&2
        exit 1
    fi
    if ! runuser -u "$SERVICE_USER" -- test -x "$binary"; then
        echo "ERROR: $SERVICE_USER cannot execute $binary." >&2
        echo "       Every directory on the path must be traversable by the service account." >&2
        echo "       Copy the binary and its sibling libraries somewhere world-reachable," >&2
        echo "       e.g. /opt/nvidia/nsight-perf/, and pass that path." >&2
        exit 1
    fi
    # Existing is not enough: the service reads it as its own account, and a root-only document would
    # pass the check above and then leave the service collecting nothing.
    if ! runuser -u "$SERVICE_USER" -- test -r "$metricConfigDocument"; then
        echo "ERROR: $SERVICE_USER cannot read $metricConfigDocument." >&2
        echo "       The service reads it for its default GPU PM metric sets." >&2
        exit 1
    fi

    # Last of the checks that can bail, so nothing below takes down a working
    # service and then fails. The cleanup cannot run under a live daemon.
    if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        echo "Stopping ${SERVICE_NAME}.service..."
        systemctl stop "${SERVICE_NAME}.service"
    fi
    clear_runtime_contents

    # Skip a tmpfiles fragment we did not write (e.g. a future Nsight package).
    if [[ ( -e "$TMPFILES_CONF" || -L "$TMPFILES_CONF" ) && "$(head -n 1 "$TMPFILES_CONF")" != "$TMPFILES_OWNED_HEADER" ]]; then
        echo "Leaving $TMPFILES_CONF in place (not created by this script)."
    else
        echo "Writing $TMPFILES_CONF..."
        {
            echo "$TMPFILES_OWNED_HEADER"
            printf 'd %-24s 0755 %-19s %-19s -\n' "$(dirname "$RUNTIME_DIR")" root root
            printf 'd %-24s 0755 %-19s %-19s -\n' "$RUNTIME_DIR" "$SERVICE_USER" "$SERVICE_GROUP"
            # Parent is root-owned; the service account cannot mkdir this itself.
            printf 'd %-24s 0755 %-19s %-19s -\n' "$NVTX_RUNTIME_DIR" "$SERVICE_USER" "$SERVICE_GROUP"
            # Hands back what a root-run daemon left behind, which the service could not reopen otherwise.
            printf 'z %-24s -    %-19s %-19s -\n' "$RUNTIME_DIR/router.*" "$SERVICE_USER" "$SERVICE_GROUP"
        } > "$TMPFILES_CONF"
    fi
    echo "Creating runtime directory via systemd-tmpfiles..."
    if [[ -e "$TMPFILES_OVERRIDE" || -L "$TMPFILES_OVERRIDE" ]]; then
        echo "NOTE: $TMPFILES_OVERRIDE takes precedence over $TMPFILES_CONF; it must name $SERVICE_USER and include every line."
    fi
    # By basename, not path, so an operator's /etc copy wins over ours in /usr/lib.
    "$tmpfiles_bin" --create "$(basename "$TMPFILES_CONF")"

    # If anything pre-existed at the unit path (we got here only because
    # --force was passed), remove it first. Without this, a masked unit
    # — i.e. $SERVICE_UNIT is a symlink to /dev/null — would silently
    # absorb the write below and leave the system without our unit.
    rm -f "$SERVICE_UNIT"

    echo "Writing $SERVICE_UNIT..."
    cat > "$SERVICE_UNIT" <<EOF
[Unit]
Description=NVIDIA Nsight Perf profiling service
# Boot ordering only. tmpfiles-setup is Type=oneshot RemainAfterExit=yes, so
# pulling it in is a no-op once it has run; ExecStartPre below is what
# guarantees the runtime directory on a start after boot.
Wants=systemd-tmpfiles-setup.service
After=nvidia-persistenced.service systemd-tmpfiles-setup.service
# Set to 0 so there is no limit on how many times the daemon may be restarted.
# Deleting the line is not the same: systemd then defaults to 5 starts per 10 seconds.
StartLimitIntervalSec=0

[Service]
Type=simple
# on-abnormal covers a signal death (e.g. SIGFPE in PerfWorks); cuInit, bad config
# and bind failures exit 1, which stays failed instead of flapping.
Restart=on-abnormal
RestartSec=1
User=$SERVICE_USER
Group=$SERVICE_GROUP
# No NoNewPrivileges or CapabilityBoundingSet: cuInit creates the GPU device nodes and loads
# nvidia_uvm through the setuid nvidia-modprobe, which either one would leave without privilege.
AmbientCapabilities=CAP_PERFMON
# '+' runs this as root; $SERVICE_USER cannot create directories under /run.
ExecStartPre=+"$tmpfiles_bin" --create $(basename "$TMPFILES_CONF")
ExecStart="$binary" --global

[Install]
WantedBy=multi-user.target
EOF

    echo "Reloading systemd..."
    systemctl daemon-reload

    # Always enable (idempotent). A plain start suffices because the unit was
    # stopped before the runtime directory was touched, so there is no running
    # daemon left on the pre-rewrite unit.
    echo "Enabling ${SERVICE_NAME}.service..."
    systemctl enable "${SERVICE_NAME}.service"
    echo "Starting ${SERVICE_NAME}.service..."
    systemctl start "${SERVICE_NAME}.service"

    sleep 1
    echo
    echo "=== Result ==="
    systemctl status "${SERVICE_NAME}.service" --no-pager || true

    # Type=simple: `systemctl start` can succeed before daemon initialization
    # completes, so the sleep above is what gives it time to fail before this check.
    if ! systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        echo
        echo "ERROR: ${SERVICE_NAME}.service failed to start; see journalctl -u ${SERVICE_NAME}.service" >&2
        exit 1
    fi

    echo
    echo "Tail logs with: journalctl -u ${SERVICE_NAME}.service -f"
}

if [[ $# -gt 1 ]]; then
    echo "ERROR: unexpected extra argument '$2'." >&2
    usage
    exit 1
fi

case "${1:-}" in
    --uninstall)  cmd_uninstall ;;
    --status)     cmd_status ;;
    -h|--help)    usage; exit 0 ;;
    "")           usage; exit 1 ;;
    -*)           echo "ERROR: unknown option $1" >&2; usage; exit 1 ;;
    *)            cmd_install "$1" ;;
esac
