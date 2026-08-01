#!/usr/bin/env bash
# Collect system tuning flags/values on a GitHub Actions runner.
# Expects passwordless sudo (available on GHA hosted runners).
set -euo pipefail

section() {
  printf '\n========== %s ==========\n' "$1"
}

kv() {
  local label="$1"
  shift
  printf '%-48s ' "$label"
  if "$@" 2>/dev/null; then
    :
  else
    echo "(unavailable)"
  fi
}

read_file() {
  local f="$1"
  if [[ -r "$f" ]]; then
    tr -d '\n' <"$f"
    echo
  elif sudo test -r "$f" 2>/dev/null; then
    sudo cat "$f" | tr -d '\n'
    echo
  else
    echo "(unavailable)"
  fi
}

echo "collect-sysctl.sh starting at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "hostname=$(hostname)"
echo "whoami=$(whoami)"
echo "id=$(id)"
echo "uname=$(uname -a)"

section "sudo check"
if sudo -n true 2>/dev/null; then
  echo "passwordless sudo: YES"
else
  echo "passwordless sudo: NO (some values may be missing)"
fi

section "OS / runner identity"
kv "os-release" bash -c 'cat /etc/os-release 2>/dev/null || true'
kv "IMAGE_OS" bash -c 'echo "${ImageOS:-unset}"'
kv "RUNNER_OS" bash -c 'echo "${RUNNER_OS:-unset}"'
kv "RUNNER_ARCH" bash -c 'echo "${RUNNER_ARCH:-unset}"'
kv "RUNNER_NAME" bash -c 'echo "${RUNNER_NAME:-unset}"'
kv "RUNNER_ENVIRONMENT" bash -c 'echo "${RUNNER_ENVIRONMENT:-unset}"'

section "CPU"
kv "nproc" nproc
kv "lscpu (model)" bash -c "lscpu 2>/dev/null | grep -E 'Model name|Architecture|CPU\\(s\\)|Thread|Core|Socket|MHz|Vendor' || true"
kv "cpuinfo flags (first cpu)" bash -c "grep -m1 '^flags' /proc/cpuinfo || true"
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [[ -e "$gov" ]] || continue
  echo "governor $(basename "$(dirname "$(dirname "$gov")")"): $(read_file "$gov")"
  break
done
if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
  kv "scaling_min_freq" bash -c "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 2>/dev/null || true"
  kv "scaling_max_freq" bash -c "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || true"
  kv "scaling_cur_freq" bash -c "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || true"
  kv "scaling_driver" bash -c "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || true"
fi

section "Memory"
kv "free -h" free -h
kv "MemTotal" bash -c "awk '/MemTotal/ {print \$2, \$3}' /proc/meminfo"
kv "SwapTotal" bash -c "awk '/SwapTotal/ {print \$2, \$3}' /proc/meminfo"
kv "HugePages_Total" bash -c "awk '/HugePages_Total/ {print \$2}' /proc/meminfo"
kv "Hugepagesize" bash -c "awk '/Hugepagesize/ {print \$2, \$3}' /proc/meminfo"
kv "AnonHugePages" bash -c "awk '/AnonHugePages/ {print \$2, \$3}' /proc/meminfo"
if [[ -r /sys/kernel/mm/transparent_hugepage/enabled ]]; then
  kv "transparent_hugepage/enabled" cat /sys/kernel/mm/transparent_hugepage/enabled
  kv "transparent_hugepage/defrag" cat /sys/kernel/mm/transparent_hugepage/defrag
fi

section "ulimit (soft/hard)"
ulimit -a || true
echo "---"
kv "nofile soft" bash -c 'ulimit -Sn'
kv "nofile hard" bash -c 'ulimit -Hn'
kv "nproc soft" bash -c 'ulimit -Su'
kv "nproc hard" bash -c 'ulimit -Hu'
kv "stack soft" bash -c 'ulimit -Ss'
kv "memlock soft" bash -c 'ulimit -Sl'
kv "core soft" bash -c 'ulimit -Sc'

section "key sysctl (sysctl -a filtered)"
# Broad dump of tuning-relevant knobs; ignore permission errors.
{
  sudo sysctl -a 2>/dev/null || sysctl -a 2>/dev/null || true
} | grep -E '^(kernel\.(pid_max|threads-max|randomize_va_space|core_pattern|hostname|osrelease|printk|sched_|numa_balancing|yama)|vm\.(swappiness|dirty_|overcommit_|min_free_kbytes|vfs_cache_pressure|max_map_count|nr_hugepages|zone_reclaim_mode|panic_on_oom)|fs\.(file-max|nr_open|inotify|aio-max-nr|pipe-)|net\.(core\.(somaxconn|netdev_max_backlog|rmem_|wmem_|default_qdisc)|ipv4\.(ip_local_port_range|tcp_fin_timeout|tcp_tw_reuse|tcp_max_syn_backlog|tcp_keepalive_|tcp_fastopen|tcp_congestion_control|tcp_rmem|tcp_wmem|tcp_syncookies|ip_forward)|ipv6\.conf\.all\.disable_ipv6))' \
  | sort || true

section "explicit /proc/sys reads"
PROCS=(
  kernel/pid_max
  kernel/threads-max
  kernel/randomize_va_space
  kernel/core_pattern
  kernel/sched_autogroup_enabled
  kernel/numa_balancing
  vm/swappiness
  vm/dirty_ratio
  vm/dirty_background_ratio
  vm/dirty_expire_centisecs
  vm/dirty_writeback_centisecs
  vm/overcommit_memory
  vm/overcommit_ratio
  vm/min_free_kbytes
  vm/vfs_cache_pressure
  vm/max_map_count
  vm/nr_hugepages
  vm/zone_reclaim_mode
  fs/file-max
  fs/nr_open
  fs/inotify/max_user_watches
  fs/inotify/max_user_instances
  fs/aio-max-nr
  fs/pipe-max-size
  net/core/somaxconn
  net/core/netdev_max_backlog
  net/core/rmem_max
  net/core/wmem_max
  net/core/default_qdisc
  net/ipv4/ip_local_port_range
  net/ipv4/tcp_fin_timeout
  net/ipv4/tcp_tw_reuse
  net/ipv4/tcp_max_syn_backlog
  net/ipv4/tcp_keepalive_time
  net/ipv4/tcp_keepalive_intvl
  net/ipv4/tcp_keepalive_probes
  net/ipv4/tcp_fastopen
  net/ipv4/tcp_congestion_control
  net/ipv4/tcp_syncookies
  net/ipv4/ip_forward
)
for p in "${PROCS[@]}"; do
  printf '%-48s ' "/proc/sys/$p"
  read_file "/proc/sys/$p"
done

section "current file-nr / inode-nr"
kv "fs.file-nr" bash -c 'cat /proc/sys/fs/file-nr'
kv "fs.inode-nr" bash -c 'cat /proc/sys/fs/inode-nr 2>/dev/null || true'

section "sysctl.conf / drop-ins"
for f in /etc/sysctl.conf /etc/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf; do
  [[ -e "$f" ]] || continue
  echo "--- $f ---"
  cat "$f" 2>/dev/null || sudo cat "$f" 2>/dev/null || true
done

section "limits.d / security limits"
for f in /etc/security/limits.conf /etc/security/limits.d/*; do
  [[ -e "$f" ]] || continue
  echo "--- $f ---"
  cat "$f" 2>/dev/null || sudo cat "$f" 2>/dev/null || true
done

section "systemd default limits (if present)"
for f in /etc/systemd/system.conf /etc/systemd/user.conf /usr/lib/systemd/system.conf.d/*.conf /etc/systemd/system.conf.d/*.conf; do
  [[ -e "$f" ]] || continue
  echo "--- $f (Limit* / DefaultLimit*) ---"
  grep -E '^(#)?DefaultLimit|^Limit' "$f" 2>/dev/null || true
done

section "cgroup / pressure (if available)"
kv "cgroup mount" bash -c 'mount | grep -E cgroup || true'
if [[ -r /sys/fs/cgroup/cgroup.controllers ]]; then
  kv "cgroup.controllers" cat /sys/fs/cgroup/cgroup.controllers
fi
if [[ -r /proc/pressure/cpu ]]; then
  kv "pressure/cpu" cat /proc/pressure/cpu
  kv "pressure/memory" cat /proc/pressure/memory
  kv "pressure/io" cat /proc/pressure/io
fi

section "disk / mount options (tuning-relevant)"
kv "df -h" df -h
kv "mount (noatime/discard/etc)" bash -c "mount | grep -E 'ext4|xfs|btrfs|overlay' || true"

section "irq / softirq hints"
kv "smp_affinity (irq 0 if any)" bash -c 'cat /proc/irq/0/smp_affinity 2>/dev/null || true'
kv "softirqs (header+first)" bash -c 'head -3 /proc/softirqs 2>/dev/null || true'

section "kernel cmdline"
kv "cmdline" cat /proc/cmdline

section "done"
echo "collect-sysctl.sh finished at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
