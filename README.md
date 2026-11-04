# NVIDIA Nsight Perf Daemon

The NVIDIA Nsight Perf daemon hosts the out-of-process service used by NvTrace clients and tools to collect performance data.

The service executable is `nvidia-nsight-perf`. It collects GPU-level data, coordinates target-side providers, and publishes provider buffers to authorized clients.

## Service scope


Without `--global`, the service has user-local scope and publishes its endpoint under `$XDG_RUNTIME_DIR/nvidia/nsight-perf/`. It serves only the launching user and does not require process capabilities. Root has no user-local scope, so a service started as root always runs as if `--global` were given.

With `--global`, it publishes under `/run/nvidia/nsight-perf/` and serves principals admitted by the YAML `securityPolicy`. The service account must be able to create the endpoint there. Grant `CAP_PERFMON` to the service when GPU performance-counter permissions require it.

Consumers need no scope option. They try the global endpoint first and then the current user's endpoint.

GPU PM counters are exclusive per GPU. For shared GPUs, run one global service rather than competing user-local services.

## Linux installation

For a multi-user systemd deployment, follow the
[Linux installation guide](docs/LinuxInstallationGuide.md) and use the
[installation script](scripts/install_nvidia_nsight_perf.sh). Run the script
from this repository root with the path to the separately supplied daemon binary.

## Starting the service

Start a user-local service:

```shell
./nvidia-nsight-perf
```

Start a global service after provisioning its runtime directory and permissions:

```shell
./nvidia-nsight-perf --global
```

Use [`nvtrace_poll_until_service_ready`](https://github.com/NVIDIA/nvtrace-tools/blob/main/PollUntilServiceReady/README.md) before starting a workload that must not run ahead of profiling initialization.

## Containers

The service, the workload, and the consumer can each run on the host or in a container, provided
all three resolve the socket directory to the same path on the node.

## Cluster profiling

For a multi-process job, start one service per node and let all tasks on that node share it. The following Slurm pattern starts the service and consumer on local rank zero:

```shell
srun \
    --nodes=1 \
    --ntasks-per-node=4 \
    --gres=gpu:4 \
    bash -c "
        if [ \${SLURM_LOCALID} == 0 ]; then
            \${NSIGHT_PERF_BIN_PATH}/nvidia-nsight-perf &
        fi
        \${NSIGHT_PERF_BIN_PATH}/nvtrace_poll_until_service_ready
        python \${CWD}/train.py &
        if [ \${SLURM_LOCALID} == 0 ]; then
            \${NSIGHT_PERF_BIN_PATH}/nvtrace_streaming_consumer \
                --output-dir \${CWD} --duration-ms 10000
        fi
    "
```

`NSIGHT_PERF_BIN_PATH` names the directory containing the service and tools, and `CWD` names the workload directory.

## Configuration

The service searches for YAML configuration in this order:

1. The file named by `NVIDIA_NSIGHT_PERF_CONFIG_PATH`.
2. The path passed with `--config`.
3. `/etc/nvidia-nsight-perf/nvidia-nsight-perf.yaml`
4. `nvidia-nsight-perf.yaml` beside the service executable.
5. The built-in default.

An explicitly selected file that cannot be read is an error; the service does not silently fall back to another configuration. Ensure the service account can read operator-managed configuration.

Export the built-in configuration with:

```shell
./nvidia-nsight-perf --export-default-config-only /path/to/nvidia-nsight-perf.yaml
```

The exported configuration may reference a metric document through `{ServiceBinaryDirectory}`. Copy that document with the YAML file or replace the reference with inline `metricConfig.content`.

### Disabling GPU providers

GPU PM counters and GPU hardware trace are enabled by default:

| Provider | Environment variable | Readiness name |
| --- | --- | --- |
| GPU PM counters | `NSIGHT_PERF_GPU_PM_ENABLE` | `gpu_pm` |
| GPU hardware trace | `NSIGHT_PERF_GPU_HW_TRACE_ENABLE` | `gpu_hwt` |

When disabling a provider, also exclude it from the readiness check:

```shell
NSIGHT_PERF_GPU_PM_ENABLE=0 ./nvidia-nsight-perf &
./nvtrace_poll_until_service_ready --ignore gpu_pm
```

```shell
NSIGHT_PERF_GPU_PM_ENABLE=0 \
NSIGHT_PERF_GPU_HW_TRACE_ENABLE=0 \
./nvidia-nsight-perf &
./nvtrace_poll_until_service_ready --ignore gpu_pm,gpu_hwt
```

### Router options

The `Router` section controls maximum provider, observer, controller, GPU-partition, process, provider-type, and provider counts.

`securityPolicy` controls connect-time admission:

- `authorizedProviderClients` controls who may publish provider data.
- `authorizedObserverClients` controls who may observe and which processes and GPUs they may see.
- `authorizedControllerClients` controls who may acquire profiling locks and on which GPUs.

On Linux, root is implicitly granted full access. A YAML GPU grant is an upper bound: device-node permissions, cgroup device limits, and container GPU visibility can narrow effective access further.


### GPU PM-counter options

Important `GpuPmCounters` settings include:

- `pmSampleRateHz`: counter sampling frequency.
- `updateIntervalNsec`: interval at which the CPU copies counter values.
- `readbackHoldoffNsec`: extra delay before hardware samples are read.
- `keepLatest`: overwrite the oldest records when the hardware buffer fills.
- `maxHistoryDurationMsec`: retained history per GPU; `0` selects the built-in default.
- `architectures`: inline per-architecture metric selections.
- `metricConfig` or `metricConfigs`: one or more external or inline MetricConfig v7 documents.
- `chipRegex`: regular expression selecting the GPUs to which an entry applies.
- `metricsToConfigure`: metrics collected for online or offline evaluation.
- `metricsToEvaluate`: configured metrics also evaluated in real time.

`metricConfig` and `metricConfigs` are mutually exclusive. A successfully resolved MetricConfig set takes precedence over the legacy `architectures` entry for that chip.

#### GPU power metrics

GPU power metering requires a kernel-mode driver from R615 or newer. The [SDK prerequisites](https://github.com/NVIDIA/nsight-perf-sdk-for-ai/blob/main/README.md#prerequisites), including the R620 release baseline, also apply. The CUDA Compatibility package updates user-mode components; it does not enable power metering on a kernel-mode driver older than R615.

Total GPU power is supported on Rubin GPUs. `gpu__power.avg` reports approximate total GPU power in milliwatts, averaged over the configured sampling interval.

The supplied [ReducedOverviewPlus.config](https://github.com/NVIDIA/nsight-perf-daemon/blob/main/metric-configs/ReducedOverviewPlus.config) is an opt-in profile that preserves the counters in `ReducedOverview.config` and adds total GPU power, NVLink bandwidth, and CPU/GPU C2C bandwidth where supported. C2C metrics use the `ctc` prefix. For Rubin, both profiles provide the same overview of clocks, GPU activity, compute throughput, DRAM bandwidth, occupancy, and PCIe traffic. The expanded profile adds total power and NVLink bandwidth.

Export the default configuration, then set `GpuPmCounters.metricConfig.file` to select the expanded profile for offline evaluation:

```shell
./nvidia-nsight-perf --export-default-config-only /path/to/nvidia-nsight-perf.yaml
```

```yaml
GpuPmCounters:
    metricConfig:
        file: '{ServiceBinaryDirectory}/ReducedOverviewPlus.config'
```

The YAML above shows the profile selection in the exported file. Keep the other `GpuPmCounters` settings and provider sections. The metric document is supplied beside the service executable; if it is stored elsewhere, use its absolute path. To evaluate power in real time as well, add `gpu__power.avg` to `GpuPmCounters.metricConfig.metricsToEvaluateOnline` while retaining any existing entries.

Use [configuration validation](#validate-configuration) for the target chip and check diagnostics for unavailable metrics. Each selected set must fit in one collection pass. Unavailable metrics are skipped while the other available metrics in the set continue collecting. The profile does not change the default metric selection unless explicitly selected.

#### MetricConfig compatibility

NVIDIA Nsight Perf reads `NV::MetricConfig` version 7 and rejects other versions. Nsight Systems version-5 files must be converted. The PerfWorks `MetricConfigurations` v1.0.0 authoring format is a different format and is not accepted as MetricConfig.

Each selected metric set must identify its hardware through `architecture`. A `chips` field alone is not consumed by the shared reader.

A document can be supplied by absolute `file` path or inline `content`, but not both. Relative file paths resolve against the service working directory. Prefix a colocated file with `{ServiceBinaryDirectory}` and place that token in a single-quoted YAML scalar.

For multiple GPU families:

```yaml
GpuPmCounters:
    metricConfigs:
        - chipRegex: GB20x
          file: /etc/nvidia-nsight-perf/metric_configs/gb20x.yaml
          setSpecifier: Default
        - chipRegex: GB10x
          file: /etc/nvidia-nsight-perf/metric_configs/gb10x.yaml
        - chipRegex: .*
          file: /etc/nvidia-nsight-perf/metric_configs/generic.yaml
```

The first matching `chipRegex` entry is selected; selection does not continue to later MetricConfig entries. If that document resolves no set for the chip, the provider falls back to a matching legacy `architectures` entry when one exists and logs a warning. If multiple sets claim an architecture, selection uses the configured `setSpecifier`, then a set whose specifier is `default`; otherwise the MetricConfig selection is rejected.

NVIDIA Nsight Perf rejects a MetricConfig when:

- its version is not 7 or it cannot be parsed;
- both or neither of `content` and `file` are supplied;
- a requested `setSpecifier` is absent or ambiguous;
- a `keepInstancesFile` cannot be read;
- a `chipRegex` is invalid or omitted from a `metricConfigs` entry;
- both `metricConfig` and `metricConfigs` are present.

When a MetricConfig entry claims a chip but resolves no set for it, the provider can fall back to a matching legacy `architectures` entry. Configuration parse and validation errors remain errors. A metric set requiring more than one collection pass is skipped because continuous sampling cannot replay the workload for later passes.

MetricConfig `customMetricDefinitions` are rendered as a PerfWorks user-defined metrics script and registered before metric names are resolved. If PerfWorks rejects those definitions, provider initialization fails; the service does not silently drop the custom definitions and collect a partial set.

#### Per-instance metric values

MetricConfig does not carry the NvTrace `keepInstances` choice. Supply full metric names alongside the selected document:

```yaml
GpuPmCounters:
    metricConfig:
        file: /etc/nvidia-nsight-perf/metric_configs/gb20x.yaml
        keepInstancesFile: /etc/nvidia-nsight-perf/metric_configs/keep_instances.txt
        keepInstancesOverrides:
            - sm__cycles_active.avg.pct_of_peak_sustained_elapsed
```

`keepInstancesFile` contains one metric name per line; blank lines and lines beginning with `#` are ignored. Entries in either source must be complete metric names, including suffixes. Unknown names are reported instead of being matched by stem. Duplicate entries have no additional cost.

#### Scheduling hints

MetricConfig `schedulingHints` assign raw counters to named counter domains before metrics are scheduled. The hint keys are raw-counter names, not metric names. Invalid domains and contradictory hints are reported during conversion. Domain resolution requires the PerfWorks host library; without it, validation reports that the check was skipped.

#### Validate configuration

Validate syntax and selection without initializing CUDA:

```shell
./nvidia-nsight-perf --config /path/to/config.yaml --validate-config
```

Validate coverage and single-pass scheduling for a chip:

```shell
./nvidia-nsight-perf --config /path/to/config.yaml \
    --validate-config --chip GB202
```

Scheduling-domain checks require the PerfWorks host library. If it cannot be loaded, those checks are reported as informational and do not make validation fail.

Validation diagnostics use these severities:

- `error`: the described block cannot collect as configured; exit status is nonzero.
- `warning`: part of the requested configuration will not take effect; exit status is nonzero.
- `info`: input was unused without losing requested behavior; exit status remains zero.

#### Size the PM-counter history

Use:

```text
sampleCount = pmSampleRateHz * (maxHistoryDurationMsec / 1000)

maxHistoryDurationMsec >=
    updateIntervalNsec / 1,000,000
    + 2
    + consumer_read_interval_ms
    + 200
```

The built-in 402 ms history covers the default 100 ms update interval, 2 ms hardware-pipeline holdoff, a 100 ms consumer interval, and 200 ms scheduling margin. A consumer polling once per second needs approximately 1302 ms of history. Buffer overrun drops the oldest samples.

### CUDA API trace options

The `CudaApiTrace` section provides:

- `maxThreadCount` and `circularFifoEntriesPerThread` for traced-call history;
- `maxContextCount`, `maxStreamCount`, `maxModuleCount`, and `maxFunctionCount` for CUDA objects and names;
- `maxGraphExecCount` and `maxGraphNodeCount` for CUDA graph state;
- `chunkCount` and `sizeofChunk` for event storage;
- `maxStringTableEntries`, `sizeofStringTableData`, and `maxStringTableEntryLength` for names;
- `maxObjectLifetimeEventCells` for object creation and destruction history;
- `traceRuntimeApiCalls` to enable CUDA Runtime API tracing.

Increase the relevant object or string-table limit when a trace omits objects, graph launches, or kernel names.

#### CUDA API tracing firewall

Use `CudaApiTrace.driverApiTraceFirewall` to select which CUDA Driver API calls are traced. Filtering frequent, low-interest calls can reduce trace volume and tracing overhead.

Rules apply when `traceRuntimeApiCalls` is `false`. They are ignored when CUDA Runtime API tracing is enabled.

Each rule specifies a `firewallOp` and optional matching conditions:

| Field | Matches |
|---|---|
| `cudaApiCategories` | API categories, such as `Getters`, `Setters`, `Actions`, or `Synchronization`. |
| `cudaApiModules` | API groups, such as `MemoryManagement`, `StreamManagement`, or `GraphManagement`. |
| `cudaApiNameContains` | Case-insensitive substrings of API function names. |

Values within a field are combined with **OR**. Different fields are combined with **AND**. Omitted or empty fields impose no restriction; a rule without matching conditions matches every API.

CUDA API categories are defined as follows. Categories are assigned explicitly to each API; an API's category cannot always be inferred from its name.

| Category | Meaning |
|---|---|
| `Initialization` | Initialize CUDA or profiling facilities. |
| `Getters` | Retrieve properties, attributes, handles, or configuration. |
| `Setters` | Modify configuration, bindings, or current state. |
| `Actions` | Execute or enqueue operations. |
| `Query` | Query execution status or event timing. |
| `Synchronization` | Record dependencies, coordinate execution, or wait for completion. |
| `MemoryAllocation` | Allocate, free, map, or otherwise manage memory backing. |
| `Resource` | Create, destroy, load, unload, or register resources. |
| `Setup` | Configure execution settings and launch parameters. |

Rules are evaluated from top to bottom:

| Operation | Effect on matching APIs |
|---|---|
| `include` | Enable tracing and continue evaluating rules. |
| `exclude` | Disable tracing and continue evaluating rules. |
| `accept` | Enable tracing and stop evaluating rules. |
| `reject` | Disable tracing and stop evaluating rules. |

The default configuration excludes the `Getters` and `Setters` categories. An empty rule list traces all Driver APIs.

### NVTX and thread-event options

The `NvtxTrace` section provides:

- `registeredStringArenaSize` and `maxRegisteredStringRecordPayloadSize`;
- `maxDomainCount`;
- `maxStateChunkPoolCountLog2` and `maxStateChunkCountPerPool`;
- `maxPushPopRangePoolCountLog2`, `maxPushPopRangeCountPerPool`, and `minPushPopRangeInlineMessageSize`;
- `maxStackGroupPoolCountLog2`, `maxStackGroupCountPerPool`, and `minStackGroupInlineStackRefCount`.

The `ThreadEvent` section provides `maxThreadCount`, `circularFifoEntriesPerThread`, `chunkCount`, `sizeofChunk`, and `maxSourceProviderCount`. Increase the corresponding storage limit when NVTX names or events are dropped.

## Compatibility

The NVIDIA Nsight Perf service and service-connected NvTrace consumers are compatible across SDK releases in both directions. A newer consumer can connect to an older service, and an older consumer can connect to a newer service.

Only features understood by both versions are available in a cross-version combination.

## Known limitations

- Each GPU can be initialized by only one service instance at a time.
- For CUDA applications in containers, run the service in the host PID namespace, either on the host or in a container started with `--pid=host`. The target PID namespace must be the service namespace or its descendant.
- The service learns a target's host PID from peer credentials and correlates it with driver records while retaining the target's namespace PID. Equal namespace PIDs in different containers remain distinguishable by host PID or process LUID.
- A service in a sibling, parent, or otherwise unrelated PID namespace cannot reliably correlate driver host PIDs with target processes.
- Traces expose the host PID used for correlation. Consider that information when sharing traces across trust boundaries.
- GPU PM-counter sets that require more than one collection pass are not collected.
- MetricConfig display metadata such as row names, grouping, and units is not yet reflected in exported traces.

### GPU GR-context tracing and CUDA forward compatibility

- GPU GR-context tracing requires the CUDA user-mode driver (`libcuda.so`) loaded by the service to be revision-matched to the installed host kernel-mode driver. This trace path does not participate in CUDA forward compatibility, so a newer compatibility user-mode driver can run CUDA workloads successfully against an older kernel-mode driver while GR-context tracing fails.
- A driver mismatch can cause the diagnostic `GPU GR Context Trace provider failed to initialize the RM event buffer.` CUDA API launches and raw GPU hardware events may still be captured, but correlation to the originating CUDA workload and named kernel GPU timings may be incomplete or unavailable.
- For a containerized service, the relevant kernel-mode driver is the one installed on the host. Verify which `libcuda.so` the service actually loads; installing a matching library in the container alone does not satisfy this requirement.
- A suggested mitigation is to run the service with a host-matched `libcuda.so` while the workload keeps its newer compatibility user-mode driver. The service and workload are separate processes and can load different libraries. This mitigation requires validation in the affected deployment: confirm the library loaded by the service, successful GR-context trace initialization, and GPU-event correlation before relying on named kernel GPU timings.

## Contributions

Contributions require signed-off commits and the Developer Certificate of Origin. See [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a change.

## Security

Do not report potential security vulnerabilities through public GitHub issues. Follow the private reporting process in [SECURITY.md](SECURITY.md).

## License

Repository-authored documentation and packaging material are licensed under Apache-2.0; see [LICENSE](LICENSE). The separately distributed daemon executable is proprietary and governed by the Nsight Perf SDK EULA. See [LICENSING.md](LICENSING.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

### External materials

NOTICE AND DISCLAIMER: This software automatically retrieves, accesses or interacts with external materials.  Those retrieved materials are not distributed with this software and are governed solely by separate terms, conditions and licenses.  You are solely responsible for finding, reviewing and complying with all applicable terms, conditions, and licenses, and for verifying the security, integrity and suitability of any retrieved materials for your specific use case. This software is provided "AS IS", without warranty of any kind. The author makes no representations or warranties regarding any retrieved materials, and assumes no liability for any losses, damages, liabilities or legal consequences from your use or inability to use this software or any retrieved materials. Use this software and the retrieved materials at your own risk.
