# tmp

Temporary repo to collect GitHub Actions runner system tuning flags via `scripts/collect-sysctl.sh`.

Covers: sysctl/ulimit, self-cgroup walk, Docker/runtime, block I/O queues,
Azure/virt + clock/entropy, network (ethtool/conntrack/DNS), LSM/hardening,
memory reclaim/THP, CPU topology, time/services, runner session env.

## Workflow

`Collect system tuning flags` runs on `push` to `main` and `workflow_dispatch`.
