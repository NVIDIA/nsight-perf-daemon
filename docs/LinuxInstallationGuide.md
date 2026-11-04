# NVIDIA Nsight Perf Daemon — Linux Installation Guide

This guide covers deploying `nvidia-nsight-perf` as a multi-user systemd
service. For interactive single-user use, run `nvidia-nsight-perf` with
no flags (user-local mode, no installation needed). Application
developers: see the [SDK README](https://github.com/NVIDIA/nsight-perf-sdk-for-ai/blob/main/README.md). The rest of this
document is for the deployer.

## Quickstart

Run the installer commands below from the daemon repository root. See the
[installation script](../scripts/install_nvidia_nsight_perf.sh).

Install (one positional argument — the binary path). The path must be
reachable by the `nvidia-nsight-perf` service account. The installer also
requires `nvidia-modprobe`, which usually comes with the NVIDIA driver; with
distribution driver packages, install the `nvidia-modprobe` package first.

```shell
sudo ./scripts/install_nvidia_nsight_perf.sh /path/to/nvidia-nsight-perf
```

Verify (separate option-style invocation):

```shell
sudo ./scripts/install_nvidia_nsight_perf.sh --status
journalctl -u nvidia-nsight-perf.service -f
```

Uninstall:

```shell
sudo ./scripts/install_nvidia_nsight_perf.sh --uninstall
```

> **Re-installing.** Running the install command a second time while
> the unit is already in place is treated as an accident and refused
> (you'll see an "NVIDIA Nsight Perf service appears to be installed" error). Pass
> `--force` to overwrite the unit and bounce the service:
> `sudo ./scripts/install_nvidia_nsight_perf.sh /path/... --force`.
> `--uninstall` and `--status` are always idempotent and don't need
> `--force`.

**Expected result.** `systemctl is-active nvidia-nsight-perf.service` reports
`active`, the journal shows providers initializing without
`NVPA_STATUS_INSUFFICIENT_PRIVILEGE`, and consumer processes admitted by
the shipped default `securityPolicy` (world-open `/everyone`) can connect
to the sockets. If the journal shows the privilege error, see
[GPU profiling permissions](#gpu-profiling-permissions). If a consumer
can't connect, see [Troubleshooting](#troubleshooting).

## How it works

The installer creates the dedicated system account `nvidia-nsight-perf`,
ships `/usr/lib/tmpfiles.d/nvidia-nsight-perf.conf` so systemd-tmpfiles
creates `/run/nvidia/nsight-perf/` (owner `nvidia-nsight-perf`, mode
`0755`) on every boot and before every service start, and writes a systemd unit
(`/etc/systemd/system/nvidia-nsight-perf.service`) that runs the daemon as
that account with `AmbientCapabilities=CAP_PERFMON` (so it can read GPU
performance counters). The daemon binds three sockets —
`router.provider/.sock`, `router.observer/.sock`,
`router.controller/.sock` — under `/run/nvidia/nsight-perf/`.

Who may `connect(2)` and what they may do after connecting are both
driven by the YAML `securityPolicy:` authorized-client lists (see
[Socket endpoint permissions](#socket-endpoint-permissions)).

GPU profiling access is granted to the daemon via one of three
mechanisms: **Group permissions** (CUDA 13.3 / R610+), **`CAP_PERFMON`**
(installer default, works on all CUDA 13.x drivers), or the legacy
**RegKey** (kernel-wide; deprecated). See [GPU profiling
permissions](#gpu-profiling-permissions) for the trade-offs.

---

## Details

### Deployment scopes

| Scope | Flag | Socket location | Visible to |
|---|---|---|---|
| **User-local** (default) | (none) | `$XDG_RUNTIME_DIR/nvidia/nsight-perf/router.<endpoint>/.sock` | Only the launching user |
| **Global** | `--global` (always on for root) | `/run/nvidia/nsight-perf/router.<endpoint>/.sock` | Users admitted by `securityPolicy` |

A user process's ability to communicate with NVIDIA Nsight Perf is gated by the
endpoint ACLs derived from `securityPolicy` (and, for the directory
itself, by the write-restricted `/run/nvidia/nsight-perf/` ownership).
**Clients of NVIDIA Nsight Perf do not need `CAP_PERFMON` or any GPU profiling
permission.** `CAP_PERFMON` and the GPU profiling permission tiers
(below) apply only to the NVIDIA Nsight Perf daemon itself.

**Root always runs in global scope.** Root has no user-local scope:
its `$XDG_RUNTIME_DIR` is usually unset, and under `sudo -E` it is the
invoking user's. A daemon started as root therefore serves the global
scope even without `--global`, and root clients look for it only there.
It shares the single-instance lock with the installed service, so only
one of them runs at a time. Two daemons also cannot both own GPU PM
counters on the same GPU — the hardware allows one owner per GPU.
**Recommendation:** for any multi-user deployment, install via
`--global` through the script above; reserve user-local mode for
single-user interactive sessions.

**Non-root user-local mode** requires `$XDG_RUNTIME_DIR` to be set in
the launching environment (systemd-logind sets it for interactive
sessions to `/run/user/<uid>`). Cron, non-logind ssh, and many
container runtimes won't have it; either set it explicitly or use
`--global`.

### Runtime directory (systemd-tmpfiles)

Because `/run` is tmpfs (wiped each boot), the installer ships
`/usr/lib/tmpfiles.d/nvidia-nsight-perf.conf`:

```text
d /run/nvidia              0755 root               root               -
d /run/nvidia/nsight-perf  0755 nvidia-nsight-perf nvidia-nsight-perf -
d /run/nvidia/nvtx         0755 nvidia-nsight-perf nvidia-nsight-perf -
z /run/nvidia/nsight-perf/router.* -    nvidia-nsight-perf nvidia-nsight-perf -
```

The third line is the directory for the `--global` NVTX marker
(`nvtx-cuda.yaml`). The service account cannot create it under
root-owned `/run/nvidia`.

The fourth line returns the `router.lock` and `router.*/` entries a
root-run daemon leaves behind to the service account, which could not
reopen them otherwise. It is not recursive; the service replaces a stale
socket itself.

`systemd-tmpfiles-setup` applies the fragment at boot. The installer and
the unit's `ExecStartPre` also run
`systemd-tmpfiles --create nvidia-nsight-perf.conf`, so the directory is
provisioned before every `systemctl start`, not only after reboot. The
fragment is passed by basename, which allows a same-name
`/etc/tmpfiles.d/` override to take precedence.
`Wants=`/`After=systemd-tmpfiles-setup.service` provide boot ordering only.

Only the service account may create sockets in this directory; that write
restriction is the Router's anti-spoofing boundary on Linux.

Admins may override the owner, group, or mode in
`/etc/tmpfiles.d/nvidia-nsight-perf.conf`. A same-name `/etc` file replaces
the shipped `/usr/lib` fragment wholesale rather than merging with it, so
every line must be copied. The installer and `ExecStartPre` then apply
that override, not the shipped fragment.

Overrides **must** keep the directory:

- **Writable only by the service account** — group write access would allow
  members to unlink and re-bind the fixed-path sockets, enabling Router
  spoofing.
- **World-traversable (`0755`)** — removing traversal access causes
  directory `EACCES` at clients, which can look like a policy denial and
  divert admitted users to their user-scoped Routers.

`--uninstall` removes the unit, the `/usr/lib` tmpfiles fragment created
by this installer, stale `router.lock` / `router.*/` entries under
`/run/nvidia/nsight-perf`, and a stale
`/run/nvidia/nvtx/nvtx-cuda.yaml`. It leaves the `nvidia-nsight-perf`
account, any fragment owned by another package, any `/etc` override, and
the runtime directories themselves, which live on tmpfs and disappear on
reboot.

`tmpfiles` `d` does not touch directory contents, so uninstall removes a
leftover marker the same way it removes `router.lock`.

### Socket endpoint permissions

Under `/run/nvidia/nsight-perf/` the daemon creates one directory per
endpoint and binds a `.sock` file inside each (plus a `router.lock`
arbitration file):

| Socket | Used by |
|---|---|
| `router.provider/.sock` | CUDA applications self-announcing trace data |
| `router.observer/.sock` | Consumer processes (snapshot / streaming / continuous) |
| `router.controller/.sock` | Out-of-band control-plane operations |

**Connect-time admission** comes from the three `securityPolicy`
authorized-client lists (one per endpoint):

| List | Endpoint |
|---|---|
| `authorizedProviderClients` | provider |
| `authorizedObserverClients` | observer |
| `authorizedControllerClients` | controller |

On Linux, `/everyone` in a list opens that endpoint world-accessible
(`chmod 0777`); named users/groups are applied as a POSIX ACL. If
`setxattr` returns `ENOTSUP` (no POSIX ACLs on that filesystem), the
daemon falls back to `chmod 0700` — owner-only — so listed users fail
`connect(2)` even though the YAML admits them. `/everyone` never hits
that path. Root/admin is an implicit full member of all three lists.
Under `--global` (this packaging), the service account
(`nvidia-nsight-perf`) is injected on the **provider** list only —
enough for the Router's in-process provider client — not as an implicit
observer/controller. The shipped default configuration lists `/everyone`
on all three lists, so out of the box endpoints stay world-connectable.
Lock the Router down by restricting those lists to specific
users/groups in the YAML — there is no separate Unix access-group gate.

**User-local scope (no `--global`, non-root).** Sockets live under
`$XDG_RUNTIME_DIR/nvidia/nsight-perf/` as the same
`router.<endpoint>/.sock` layout. The launching user is an implicit full
member of all three lists; privacy comes from the user-local directory,
not from ignoring the YAML lists.

**Data-layer authorization.** After a peer `connect(2)`s, the service
identifies it via `SO_PEERCRED` + `SO_PEERGROUPS` and applies the same
`securityPolicy:` grants to decide what that consumer can see and do.
`authorizedObserverClients` entries carry optional `processes` /
`gpus` grants; `authorizedControllerClients` entries carry
optional `gpus` grants. A bare principal admits the client
with self-observation of its own processes (and system providers) only.
Group-based principals match against supplemental groups snapshotted at
connect time — adding a user to a group after they've already connected
does not re-evaluate the policy for that open session.

**OS-level GPU access (Linux).** YAML `gpus` is an upper bound. The client's
effective GPU set is that grant intersected with the GPUs its own process can
open read-write (the access required to use a GPU). A process that cannot
open a GPU's device node that way neither sees that GPU in notifications nor
can lock it for profiling, even when `gpus: all` is listed. `/dev/nvidia*`
permissions, cgroup device limits, and container GPU visibility (for example
`NVIDIA_VISIBLE_DEVICES`) therefore also bound what a consumer can reach.
If the client proves no GPU access, it sees none.

The Router derives the set from the client's own open device nodes rather
than from GPU identifiers the client claims. On Windows there is no
equivalent per-GPU object, so the YAML policy alone applies.

Like group membership, OS access is proven when the client declares it, not
continuously. The SDK does this on connect. Widening a running client's
reach — relaxing device-node permissions, or adding a GPU to its container —
takes effect once that client re-declares, which it can do without
reconnecting; newly reached GPUs then appear in its notifications. Narrowing
does not affect an open session: access already proven is held until the
client disconnects.

A caller denied at a global endpoint gets a permission error
distinguishable from Router absence; clients fall back to a user-scoped
Router. See the SDK README's
[daemon configuration](../README.md#configuration)
section for the full default config and rule syntax.

### SLURM cluster integration

Job users need to be admitted by `securityPolicy` the same way any other
client is — list the relevant users or OS groups as principals in the
authorized-client lists (or keep the shipped `/everyone` default).

Per-job scoping is no longer possible. The previous access-group design
could add a job user for the duration of a SLURM prolog/epilog; YAML
`securityPolicy` is read at start and is not reloaded on SIGHUP, so
admitting a job user means editing the config and restarting the
service. Prefer principals that already match how jobs are accounted
(SLURM accounts mapped to OS groups, shared job-user groups, etc.).

### GPU profiling permissions

The NVIDIA kernel module gates GPU performance counters; without
authorization, the service hits `NVPA_STATUS_INSUFFICIENT_PRIVILEGE`.
Three mechanisms grant access, listed below by name along with the
driver-version range each one works on. They are not mutually
exclusive: the kernel-side check is a chain of ORs (access is granted
if **any** of the three is satisfied).

| Mechanism | Driver range | Status |
|---|---|---|
| **Group permissions** (NVIDIA capabilities) | CUDA 13.3 / R610+ | Recommended going forward |
| **`CAP_PERFMON`** (Linux ambient capability) | CUDA 13.x (R580+); installer default | Works across the supported driver range |
| **RegKey** (`NVreg_RestrictProfilingToAdminUsers=0`) | All current drivers | Deprecated; will be removed in a future release |

#### Group permissions (CUDA 13.3 / R610+)

R610+ introduces an **NVIDIA-specific capability system** (unrelated
to Linux's native capabilities like `CAP_PERFMON`). Each profiling
capability is exposed as a device node under `/dev/nvidia-caps/`, and
access is gated by ordinary filesystem permissions — chmod / setfacl
/ group ownership — on those nodes. This is the per-group access
model R610+ supports natively.

Three NVIDIA capabilities are relevant to NVIDIA Nsight Perf:

| Capability | What it grants |
|---|---|
| `profiler-device` | Profiling at both intra-context and device-level scope. Required by `GpuPmCounterProvider`. Includes the `profiler-context` permission set. |
| `profiler-context` | Intra-context profiling only (subset of `profiler-device`). |
| `trace-device` | GPU HW tracing at device-level scope. Required by `GpuHwTraceProvider`. |

One-time setup (as root). Use this sequence: **enable modify → run
`nvidia-modprobe` → lock with modify=0**. Reversing it can fail because
`nvidia-modprobe` won't (re)create the device node if `DeviceFileModify`
is already locked to 0.


```shell
# 1. For each capability NVIDIA Nsight Perf needs, briefly enable DeviceFileModify
#    so nvidia-modprobe can create the device node, then lock it.
for cap in profiler-device trace-device; do
    echo "DeviceFileModify: 1" | \
        sudo tee /proc/driver/nvidia/capabilities/$cap >/dev/null
    sudo nvidia-modprobe -f /proc/driver/nvidia/capabilities/$cap
    echo "DeviceFileModify: 0" | \
        sudo tee /proc/driver/nvidia/capabilities/$cap >/dev/null
done

# 2. Create the NVIDIA Nsight Perf profiler-access group and grant it read access
#    to the cap nodes.
sudo groupadd -r nvidia-nsight-perf-profilers
for cap in profiler-device trace-device; do
    minor=$(awk -v c="$cap" '$1==c{print $2}' /proc/driver/nvidia-caps/sys-minors)
    sudo chown root:nvidia-nsight-perf-profilers /dev/nvidia-caps/nvidia-cap${minor}
    sudo chmod g+r /dev/nvidia-caps/nvidia-cap${minor}
done

# 3. Add nvidia-nsight-perf (and any direct-profiler users) to the group,
#    then restart the daemon so it picks up the new supplemental group.
sudo usermod -aG nvidia-nsight-perf-profilers nvidia-nsight-perf
sudo systemctl restart nvidia-nsight-perf.service
```

Notes:

- **Locking via `DeviceFileModify: 0` matters.** With it left at `1`,
  the next time any nvidia-smi-class tool runs, the kernel module may
  recreate the device node with the default mode and your
  `chmod`/`chown` is lost. The repo's helper script applies the same
  lock for the same reason.
- Profiling capabilities are **system-wide**, not per-GPU. They don't
  extend existing GPU access; the user still needs read access to the
  GPU device file itself for any actual profiling.
- Granting NVIDIA-capability access does **not** automatically
  obviate `AmbientCapabilities=CAP_PERFMON` on the daemon. They cover
  overlapping but distinct surfaces — `CAP_PERFMON` also grants access
  to Linux `perf_event_open(2)` and CPU performance counters, well
  beyond GPU profiling. If you specifically don't want the daemon to
  hold that broader access, clear those keys in a drop-in (empty
  assignment; see [Configuration](#configuration)). If you don't care
  about the surface expansion, leaving them in is fine.

Reference: [Permission issue with Performance Counters](https://developer.nvidia.com/nvidia-development-tools-solutions-err_nvgpuctrperm-permission-issue-performance-counters).

#### `CAP_PERFMON` (CUDA 13.x / R580+, installer default)

The installer sets `AmbientCapabilities=CAP_PERFMON` on the systemd
unit; the capability is granted only to `nvidia-nsight-perf`. Verify:

```shell
systemctl show nvidia-nsight-perf.service -p AmbientCapabilities
# Expected: AmbientCapabilities=cap_perfmon
```

Works across all CUDA 13.x kernel drivers — including pre-R610
deployments where Group permissions aren't yet available. Note that
`CAP_PERFMON` is a **Linux** ambient capability and grants the daemon
process access to more than just GPU counters (also Linux perf,
CPU performance counters). That's the trade-off vs. Group permissions:
broader surface, but works on every supported driver. Other users
running their own profilers (not via the NVIDIA Nsight Perf service) still need
their own access path.

#### RegKey (legacy, deprecated)

The blunt instrument: open GPU counters to *every* local user via the
legacy module parameter. Appropriate for trusted single-user
workstations, not for shared production hosts. **Per the NVIDIA
permissions reference, this regkey-based method will be removed in a
future driver release in favor of the Group permissions model above.**
Plan to migrate once you're on R610+.

```shell
echo "options nvidia NVreg_RestrictProfilingToAdminUsers=0" | \
    sudo tee /etc/modprobe.d/nvidia-profiling.conf
sudo systemctl stop nvidia-nsight-perf.service
sudo modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia
sudo modprobe nvidia nvidia_uvm nvidia_modeset nvidia_drm
sudo systemctl start nvidia-nsight-perf.service

# Verify (the param surfaces as RmProfilingAdminOnly):
grep RmProfilingAdminOnly /proc/driver/nvidia/params
# Expected: RmProfilingAdminOnly: 0
```

The three mechanisms compose by OR — the kernel-side check grants
access if `RmProfilingAdminOnly==0` **OR** the calling process holds
`CAP_PERFMON` **OR** the process satisfies the Group permission on
the relevant `/dev/nvidia-caps/` node. You can layer them if it suits
your deployment, with the caveat about `CAP_PERFMON`'s broader Linux
surface noted above.

### Configuration

The service resolves its YAML config in this order (first match wins):

1. `$NVIDIA_NSIGHT_PERF_CONFIG_PATH` environment variable
2. The path passed via `--config /path/to/config.yaml`
3. `nvidia-nsight-perf.yaml` next to the `nvidia-nsight-perf` binary
4. The compiled-in default

(See the SDK README's
[daemon configuration](../README.md#configuration)
section for the full default config and rule syntax. An explicit path —
`$NVIDIA_NSIGHT_PERF_CONFIG_PATH` or `--config` — that cannot be read is an
error, not a fall-through to the next source.)

The installed service reaches only items 3 and 4 on its own: the
installer writes `/etc/systemd/system/nvidia-nsight-perf.service` with
`ExecStart` of the binary plus `--global` (no `--config`, no
`Environment=`). A `securityPolicy:` written under
`/etc/nvidia-nsight-perf/` is ignored on restart — the service never
reads that path — and the compiled-in `/everyone` default stays in
effect.

Point the unit at that YAML with a drop-in rather than by editing it
directly. `--force` rewrites the unit; drop-ins survive:

```shell
sudo systemctl edit nvidia-nsight-perf.service
```

```ini
[Service]
Environment=NVIDIA_NSIGHT_PERF_CONFIG_PATH=/etc/nvidia-nsight-perf/config.yaml
```

Nothing ships that YAML — create it yourself — then
`sudo systemctl restart nvidia-nsight-perf.service`.

Drop-ins merge with the unit, so clearing `CAP_PERFMON` is empty
assignment — not omitting the key:

```ini
[Service]
AmbientCapabilities=
```

Do not add `NoNewPrivileges=` or `CapabilityBoundingSet=` in a drop-in.
Either one stops CUDA from creating the GPU device nodes, and the service
then fails after every reboot.

Notable sections sysadmins typically tune:

- **`securityPolicy:`** — connect-time admission and data-layer grants
  (see [Socket endpoint permissions](#socket-endpoint-permissions)).
- **`GpuPmCounters:`** — chip support list (e.g. `GB20x` for
  Blackwell) and update interval.

No SIGHUP reload — config is read once at startup. To re-read,
`sudo systemctl restart nvidia-nsight-perf.service`.

### Restart policy

The unit sets `Restart=on-abnormal`, so the daemon is restarted 1 s after a
crash — killed by a fatal signal such as `SIGFPE`. A clean non-zero exit is
deliberately *not* restarted: `cuInit` failure, a bad config, and a socket bind
failure all exit 1 and leave the unit `failed` so the cause stays visible
instead of flapping.

There is no cap on how many times (`StartLimitIntervalSec=0`), so a daemon that
keeps crashing keeps being restarted every 1 s indefinitely rather than giving
up; `sudo systemctl stop nvidia-nsight-perf.service` breaks that loop. A
recovered crash leaves the unit `active (running)` and
`systemctl status` has no restart-count field, so check it explicitly — a
climbing `NRestarts` means the daemon is looping:

```shell
systemctl show -p Restart -p NRestarts nvidia-nsight-perf.service
```

A restart does not restore an in-flight session. A provider hands its
shared-memory buffers to the router once, at provider init, and is never
notified that the service went away, so the restarted daemon comes back with
previously attached providers missing. Restart the profiled application to
re-attach it.

## Troubleshooting

### Service starts but providers immediately fail

```shell
journalctl -u nvidia-nsight-perf.service -n 200 --no-pager
```

`NVPA_STATUS_INSUFFICIENT_PRIVILEGE` from
`NVPW_GPU_PeriodicSampler_BeginSession_V2` → GPU profiling permission
tier isn't set up. See [GPU Profiling
Permissions](#gpu-profiling-permissions).

### Consumer connects but sees no GPUs

On Linux, YAML `gpus` is intersected with OS-level GPU access. If the
consumer cannot open `/dev/nvidia*` read-write (device-node permissions,
cgroup limits, or container `NVIDIA_VISIBLE_DEVICES`), it will not see
those GPUs even with `gpus: all`. See [Socket endpoint
permissions](#socket-endpoint-permissions).

### Consumer fails with "Failed to connect to router"

Common causes:

- The service isn't running. Check `systemctl status nvidia-nsight-perf.service`.
- User-local case: your `XDG_RUNTIME_DIR` doesn't match the daemon's.
- Global case: your identity is not admitted by `securityPolicy` for
  that endpoint. With the shipped default (`/everyone`), any local user
  can connect; a locked-down policy must list the user or a group they
  belong to. Verify the live sockets (mode bits and ACLs) with
  `sudo ./scripts/install_nvidia_nsight_perf.sh --status` and the YAML
  loaded by the service. Group membership is snapshotted at connect time —
  re-login (or start a new process) after group changes. If `--status`
  shows `srwx------` with no named ACL, the filesystem rejected POSIX
  ACLs (`ENOTSUP`) and the daemon fell back to owner-only.
- `/run/nvidia/nsight-perf` missing or not owned by `nvidia-nsight-perf`
  mode `0755`. Confirm tmpfiles with `--status`; re-run
  `sudo systemd-tmpfiles --create nvidia-nsight-perf.conf`
  if needed.
- The **parent**, `/run/nvidia`, is not traversable. Easy to miss: the
  daemon's own `/run/nvidia/nsight-perf` looks correct, while a `0700`
  parent refuses every non-root client, which then reports a policy
  denial. The global service refuses to start in this state; if the
  parent is tightened after it started, those client denials are the
  only symptom. It needs `0755`, and `--status`
  shows it under `=== runtime directory ===`. Fix with
  `sudo systemd-tmpfiles --create nvidia-nsight-perf.conf`, or
  `sudo systemctl start nvidia-nsight-perf.service`, which applies the
  fragment first.

### Service exits 1 with only `Failed to create NVIDIA Nsight Perf service`

The daemon prints `Initializing CUDA...`, `Creating NVIDIA Nsight Perf
service...`, then that line, and the unit goes to `failed`. If the same
binary starts fine under `sudo`, the cause is almost always
`/run/nvidia/nvtx`: the account needs to own the directory *and* must not
find a marker there owned by someone else. Check both with `--status`
under `=== nvtx marker ===`. Fix with

```shell
sudo rm -f /run/nvidia/nvtx/nvtx-cuda.yaml
sudo systemd-tmpfiles --create nvidia-nsight-perf.conf
```

A root-owned marker is left behind by a `--global` daemon run by hand and
killed before cleanup, so it is common on a machine used for both.
Note the daemon logs the underlying errno through `NVLOG` only, which
release builds do not emit, so `strace -f` on the failing start is the
only way to see it directly.

### Module reload fails: `Module nvidia_uvm is in use`

Common holders: `nvidia-nsight-perf.service` itself (`systemctl stop`),
`nvidia-persistenced` (`systemctl stop`), active CUDA applications
(find with `sudo fuser -v /dev/nvidia*`). Stop them, retry the reload.
If something still holds it, reboot.
