#!/usr/bin/env bash
# Collect system tuning flags/values on a GitHub Actions runner.
# Expects passwordless sudo (available on GHA hosted runners).
# Broad inventory: sysctl/ulimit, self-cgroup, docker, block I/O, virt,
# network, LSM, memory reclaim, CPU topology, time/services, runner env.
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

# Multi-line command output under a label.
dump() {
  local label="$1"
  shift
  echo "--- $label ---"
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
    sudo cat "$f" 2>/dev/null | tr -d '\n'
    echo
  else
    echo "(unavailable)"
  fi
}

read_file_nl() {
  local f="$1"
  if [[ -r "$f" ]]; then
    cat "$f"
  elif sudo test -r "$f" 2>/dev/null; then
    sudo cat "$f" 2>/dev/null || echo "(unavailable)"
  else
    echo "(unavailable)"
  fi
}

# Print key=value for selected files under a directory.
dump_sysfs_keys() {
  local dir="$1"
  shift
  local key
  [[ -d "$dir" ]] || { echo "(no dir $dir)"; return 0; }
  for key in "$@"; do
    printf '%-48s ' "$dir/$key"
    if [[ -e "$dir/$key" ]]; then
      read_file "$dir/$key"
    else
      echo "(missing)"
    fi
  done
}

# Walk current process cgroup and dump controller limit files.
dump_self_cgroup() {
  local cg_path line controller relpath abs
  if [[ ! -r /proc/self/cgroup ]]; then
    echo "(no /proc/self/cgroup)"
    return 0
  fi
  dump "/proc/self/cgroup" cat /proc/self/cgroup
  # cgroup v2 unified: 0::/path
  cg_path="$(awk -F: '$1=="0" {print $3; exit}' /proc/self/cgroup 2>/dev/null || true)"
  if [[ -n "${cg_path:-}" ]]; then
    abs="/sys/fs/cgroup${cg_path}"
    echo "self cgroup v2 path: $abs"
    while [[ -n "$abs" && "$abs" == /sys/fs/cgroup* ]]; do
      echo "--- cgroup dir: $abs ---"
      for f in cgroup.controllers cgroup.subtree_control memory.max memory.high memory.low \
        memory.min memory.swap.max memory.current memory.peak memory.events \
        cpu.max cpu.weight cpu.weight.nice cpu.pressure \
        cpuset.cpus cpuset.cpus.effective cpuset.mems cpuset.mems.effective \
        pids.max pids.current io.max io.weight io.pressure \
        memory.pressure hugetlb.2MB.max hugetlb.1GB.max; do
        if [[ -e "$abs/$f" ]]; then
          printf '  %-40s ' "$f"
          tr -d '\n' <"$abs/$f" 2>/dev/null || true
          echo
        fi
      done
      [[ "$abs" == /sys/fs/cgroup ]] && break
      abs="$(dirname "$abs")"
    done
  fi
  # Also list any hybrid/v1 paths briefly
  while IFS= read -r line; do
    controller="$(echo "$line" | cut -d: -f2)"
    relpath="$(echo "$line" | cut -d: -f3)"
    [[ -z "$controller" || "$controller" == "" ]] && continue
    [[ "$line" == 0::* ]] && continue
    echo "cgroup v1-ish: controllers=$controller path=$relpath"
  done < /proc/self/cgroup
}

echo "collect-sysctl.sh starting at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "hostname=$(hostname)"
echo "whoami=$(whoami)"
echo "id=$(id)"
echo "uname=$(uname -a)"
echo "script_pid=$$"
echo "ppid=$PPID"

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
kv "GITHUB_ACTIONS" bash -c 'echo "${GITHUB_ACTIONS:-unset}"'
kv "CI" bash -c 'echo "${CI:-unset}"'
kv "RUNNER_TRACKING_ID" bash -c 'echo "${RUNNER_TRACKING_ID:-unset}"'

# ---------------------------------------------------------------------------
# 4. Virtualization / Azure guest
# ---------------------------------------------------------------------------
section "virtualization / guest"
kv "systemd-detect-virt" systemd-detect-virt
kv "virt-what" bash -c 'command -v virt-what >/dev/null && sudo virt-what || echo "(no virt-what)"'
kv "DMI product_name" bash -c 'cat /sys/class/dmi/id/product_name 2>/dev/null || sudo cat /sys/class/dmi/id/product_name 2>/dev/null || true'
kv "DMI sys_vendor" bash -c 'cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true'
kv "DMI product_version" bash -c 'cat /sys/class/dmi/id/product_version 2>/dev/null || true'
kv "DMI chassis_vendor" bash -c 'cat /sys/class/dmi/id/chassis_vendor 2>/dev/null || true'
kv "hypervisor type (cpuinfo)" bash -c "grep -m1 -E 'hypervisor|Hypervisor' /proc/cpuinfo || true"
dump "lsmod (hv_|hyperv|azure|dxg)" bash -c "lsmod 2>/dev/null | grep -iE 'hv_|hyperv|azure|dxg|vmbus' || echo '(none matched)'"
dump "dmesg virt/azure/balloon (last matches)" bash -c "sudo dmesg -T 2>/dev/null | grep -iE 'Hyper-V|hv_|Azure|balloon|steal|KVM|QEMU|xen' | tail -n 40 || true"
dump "clocksource" bash -c 'cat /sys/devices/system/clocksource/clocksource0/current_clocksource 2>/dev/null; echo available:; cat /sys/devices/system/clocksource/clocksource0/available_clocksource 2>/dev/null || true'
kv "entropy_avail" bash -c 'cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || true'
kv "random poolsize" bash -c 'cat /proc/sys/kernel/random/poolsize 2>/dev/null || true'
kv "random.uuid" bash -c 'cat /proc/sys/kernel/random/uuid 2>/dev/null || true'
dump "rng devices" bash -c 'ls -la /dev/hwrng /dev/random /dev/urandom 2>/dev/null; ls /sys/class/misc/hw_random 2>/dev/null || true'
kv "rngd active?" bash -c 'systemctl is-active rngd 2>/dev/null || systemctl is-active rng-tools 2>/dev/null || echo inactive/missing'

# ---------------------------------------------------------------------------
# 5. CPU scheduling & topology
# ---------------------------------------------------------------------------
section "CPU topology / scheduling"
kv "nproc" nproc
dump "lscpu" lscpu
dump "lscpu -e" lscpu -e
dump "lscpu vulnerabilities" bash -c "lscpu --extended=CPU,CORE,SOCKET,NODE,ONLINE 2>/dev/null; lscpu 2>/dev/null | grep -A50 '^Vulnerabilities:' || true"
kv "cpuinfo flags (first cpu)" bash -c "grep -m1 '^flags' /proc/cpuinfo || true"
dump "online/possible/present CPUs" bash -c 'echo online: $(cat /sys/devices/system/cpu/online); echo possible: $(cat /sys/devices/system/cpu/possible); echo present: $(cat /sys/devices/system/cpu/present)'
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [[ -e "$gov" ]] || continue
  echo "governor $(basename "$(dirname "$(dirname "$gov")")"): $(read_file "$gov")"
done
if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
  dump_sysfs_keys /sys/devices/system/cpu/cpu0/cpufreq \
    scaling_min_freq scaling_max_freq scaling_cur_freq scaling_driver scaling_available_governors energy_performance_preference
fi
kv "cmdline isolcpus/nohz/etc" bash -c "grep -oE '(isolcpus|nohz_full|rcu_nocbs|nvidia|processor|maxcpus|nr_cpus|smt|nosmt)=[^ ]+' /proc/cmdline || echo '(none of isolcpus/nohz_full/...)'"
if command -v numactl >/dev/null 2>&1; then
  dump "numactl -H" numactl -H
else
  echo "numactl: (not installed)"
  dump "NUMA nodes sysfs" bash -c 'ls /sys/devices/system/node 2>/dev/null; for n in /sys/devices/system/node/node*; do echo $n cpulist=$(cat $n/cpulist 2>/dev/null) meminfo_MemTotal=$(grep MemTotal $n/meminfo 2>/dev/null); done'
fi
dump "/proc/interrupts (head)" bash -c 'head -n 40 /proc/interrupts'
dump "/proc/softirqs" cat /proc/softirqs
kv "smp_affinity irq0" bash -c 'cat /proc/irq/0/smp_affinity 2>/dev/null || true'
dump "sched_domain cpu0 (names)" bash -c 'ls /sys/kernel/debug/sched/domains/cpu0 2>/dev/null || ls /proc/sys/kernel/sched_domain/cpu0 2>/dev/null || echo "(no sched_domain debug)"'
# CFS / RT related already partly in sysctl; add loadavg / schedstat sample
kv "loadavg" cat /proc/loadavg
kv "sched_debug present?" bash -c 'test -r /proc/sched_debug && echo yes || echo no'

# ---------------------------------------------------------------------------
# 6. Memory reclaim & policy
# ---------------------------------------------------------------------------
section "Memory / reclaim / THP"
dump "free -h" free -h
dump "/proc/meminfo (full)" cat /proc/meminfo
dump "/proc/buddyinfo" cat /proc/buddyinfo
dump "/proc/pagetypeinfo (head)" bash -c 'head -n 60 /proc/pagetypeinfo 2>/dev/null || true'
dump "/proc/vmstat (selected)" bash -c "grep -E '^(pgscan|pgsteal|compact_|thp_|oom_|swp|kswapd|nr_free|nr_dirty|nr_writeback|nr_shmem|nr_anon|nr_file|workingset)' /proc/vmstat || true"
if [[ -d /sys/kernel/mm/transparent_hugepage ]]; then
  dump_sysfs_keys /sys/kernel/mm/transparent_hugepage \
    enabled defrag shmem_enabled use_zero_page
  if [[ -d /sys/kernel/mm/transparent_hugepage/khugepaged ]]; then
    dump_sysfs_keys /sys/kernel/mm/transparent_hugepage/khugepaged \
      defrag pages_to_scan scan_sleep_millisecs alloc_sleep_millisecs max_ptes_none
  fi
fi
dump "zswap/zram" bash -c '
  if [[ -d /sys/module/zswap ]]; then
    for f in /sys/module/zswap/parameters/*; do echo "$f=$(cat "$f" 2>/dev/null)"; done
  else
    echo "zswap module params: (none)"
  fi
  cat /proc/swaps 2>/dev/null || true
  lsblk -o NAME,TYPE,SIZE,MOUNTPOINT 2>/dev/null | grep -i zram || echo "zram: (none)"
'
# Extra vm sysctls for watermarks / compaction / oom
section "Memory-related sysctl extras"
{
  sudo sysctl -a 2>/dev/null || sysctl -a 2>/dev/null || true
} | grep -E '^(vm\.(watermark_|compaction_|extfrag_|vfs_cache|swappiness|dirty_|overcommit_|min_free|max_map|nr_hugepage|zone_reclaim|panic_on_oom|oom_|laptop_mode|stat_interval|page-cluster)|kernel\.numa_balancing)' \
  | sort || true

# ---------------------------------------------------------------------------
# ulimit / limits (existing + deepen)
# ---------------------------------------------------------------------------
section "ulimit (soft/hard) — current shell"
ulimit -a || true
echo "---"
kv "nofile soft/hard" bash -c 'echo $(ulimit -Sn)/$(ulimit -Hn)'
kv "nproc soft/hard" bash -c 'echo $(ulimit -Su)/$(ulimit -Hu)'
kv "stack soft/hard" bash -c 'echo $(ulimit -Ss)/$(ulimit -Hs)'
kv "memlock soft/hard" bash -c 'echo $(ulimit -Sl)/$(ulimit -Hl)'
kv "core soft/hard" bash -c 'echo $(ulimit -Sc)/$(ulimit -Hc)'

section "prlimit: self / PID1 / parent"
if command -v prlimit >/dev/null 2>&1; then
  dump "prlimit --pid $$" prlimit --pid $$
  dump "prlimit --pid 1" sudo prlimit --pid 1
  dump "prlimit --pid $PPID" prlimit --pid "$PPID" || true
else
  echo "prlimit: (not installed)"
fi

section "limits.d / security limits"
for f in /etc/security/limits.conf /etc/security/limits.d/*; do
  [[ -e "$f" ]] || continue
  echo "--- $f ---"
  cat "$f" 2>/dev/null || sudo cat "$f" 2>/dev/null || true
done

section "systemd default limits (if present)"
for f in /etc/systemd/system.conf /etc/systemd/user.conf \
  /usr/lib/systemd/system.conf.d/*.conf /etc/systemd/system.conf.d/*.conf \
  /usr/lib/systemd/user.conf.d/*.conf /etc/systemd/user.conf.d/*.conf; do
  [[ -e "$f" ]] || continue
  echo "--- $f (Limit* / DefaultLimit*) ---"
  grep -E '^(#)?DefaultLimit|^Limit' "$f" 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# classic sysctl surface
# ---------------------------------------------------------------------------
section "key sysctl (sysctl -a filtered)"
{
  sudo sysctl -a 2>/dev/null || sysctl -a 2>/dev/null || true
} | grep -E '^(kernel\.(pid_max|threads-max|randomize_va_space|core_pattern|hostname|osrelease|printk|sched_|numa_balancing|yama|unprivileged_|kptr_restrict|dmesg_restrict|sysrq|modules_disabled|perf_event_paranoid)|vm\.(swappiness|dirty_|overcommit_|min_free_kbytes|vfs_cache_pressure|max_map_count|nr_hugepages|zone_reclaim_mode|panic_on_oom)|fs\.(file-max|nr_open|inotify|aio-max-nr|pipe-|protected_|suid_dumpable)|net\.(core\.(somaxconn|netdev_max_backlog|rmem_|wmem_|default_qdisc|optmem_max)|ipv4\.(ip_local_port_range|tcp_fin_timeout|tcp_tw_reuse|tcp_max_syn_backlog|tcp_keepalive_|tcp_fastopen|tcp_congestion_control|tcp_rmem|tcp_wmem|tcp_syncookies|ip_forward)|ipv6\.conf\.(all|default)\.(disable_ipv6|forwarding|use_tempaddr))|net\.netfilter\.nf_conntrack)' \
  | sort || true

section "explicit /proc/sys reads"
PROCS=(
  kernel/pid_max
  kernel/threads-max
  kernel/randomize_va_space
  kernel/core_pattern
  kernel/sched_autogroup_enabled
  kernel/numa_balancing
  kernel/unprivileged_userns_clone
  kernel/unprivileged_bpf_disabled
  kernel/kptr_restrict
  kernel/dmesg_restrict
  kernel/perf_event_paranoid
  kernel/yama/ptrace_scope
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
  fs/protected_hardlinks
  fs/protected_symlinks
  fs/protected_fifos
  fs/protected_regular
  fs/suid_dumpable
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
  net/netfilter/nf_conntrack_max
  net/netfilter/nf_conntrack_count
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

# ---------------------------------------------------------------------------
# 1. Process / job cgroup limits
# ---------------------------------------------------------------------------
section "cgroup mounts / controllers / PSI"
kv "cgroup mount" bash -c 'mount | grep -E cgroup || true'
if [[ -r /sys/fs/cgroup/cgroup.controllers ]]; then
  kv "cgroup.controllers" cat /sys/fs/cgroup/cgroup.controllers
  kv "cgroup.subtree_control" bash -c 'cat /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true'
fi
if [[ -r /proc/pressure/cpu ]]; then
  kv "pressure/cpu" cat /proc/pressure/cpu
  kv "pressure/memory" cat /proc/pressure/memory
  kv "pressure/io" cat /proc/pressure/io
fi
section "self cgroup walk (job limits)"
dump_self_cgroup
dump "systemd-cgls (depth limited)" bash -c 'systemd-cgls --no-pager 2>/dev/null | head -n 80 || true'
dump "systemctl show user-$UID.slice (selected)" bash -c "systemctl show \"user-${UID}.slice\" -p MemoryMax -p MemoryHigh -p CPUQuota -p TasksMax -p AllowedCPUs 2>/dev/null || true"

# ---------------------------------------------------------------------------
# 2. Disk / block I/O stack
# ---------------------------------------------------------------------------
section "disk / mounts / block I/O"
dump "df -hT" df -hT
dump "lsblk -O (wide)" bash -c 'lsblk -O 2>/dev/null || lsblk -a'
dump "lsblk -D (discard)" lsblk -D
dump "mount" mount
dump "findmnt -A" findmnt -A
for dev in /sys/block/*; do
  base="$(basename "$dev")"
  # skip virtualish noise somewhat, but still show loop/ram briefly
  case "$base" in
    loop*|ram*) continue ;;
  esac
  echo "--- block $base ---"
  dump_sysfs_keys "$dev/queue" scheduler nr_requests read_ahead_kb rotational rq_affinity \
    max_sectors_kb nominal_lba_size physical_block_size logical_block_size \
    add_random iostats wbt_lat_usec
  if command -v blockdev >/dev/null 2>&1 && [[ -b "/dev/$base" ]]; then
    kv "blockdev --getra /dev/$base" sudo blockdev --getra "/dev/$base"
    kv "blockdev --getss /dev/$base" sudo blockdev --getss "/dev/$base"
  fi
done
dump "iostat -xz 1 2 (if present)" bash -c 'command -v iostat >/dev/null && iostat -xz 1 2 || echo "(sysstat/iostat not installed)"'
dump "overlay / docker storage mounts" bash -c "mount | grep -iE 'overlay|docker|containerd|fuse-overlayfs' || true"

# ---------------------------------------------------------------------------
# 3. Network stack
# ---------------------------------------------------------------------------
section "network stack"
dump "ip -d link" ip -d link
dump "ip addr" ip addr
dump "ip route" ip route
dump "ip -6 route" ip -6 route
dump "ss -s" ss -s
dump "ss -ltn (listening tcp head)" bash -c 'ss -ltn 2>/dev/null | head -n 40'
if command -v ethtool >/dev/null 2>&1; then
  for iface in $(ls /sys/class/net 2>/dev/null | grep -v '^lo$' || true); do
    dump "ethtool $iface" sudo ethtool "$iface"
    dump "ethtool -k $iface (offloads)" sudo ethtool -k "$iface"
    dump "ethtool -g $iface (rings)" sudo ethtool -g "$iface"
    dump "ethtool -i $iface (driver)" sudo ethtool -i "$iface"
  done
else
  echo "ethtool: (not installed)"
fi
dump "conntrack sysctls" bash -c "sysctl -a 2>/dev/null | grep -E 'nf_conntrack' | sort || true"
kv "nf_conntrack_count/max" bash -c 'echo $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo n/a)/$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo n/a)'
dump "resolvectl status" bash -c 'command -v resolvectl >/dev/null && resolvectl status || cat /etc/resolv.conf'
dump "DNS / nsswitch" bash -c 'echo === resolv.conf ===; cat /etc/resolv.conf; echo === nsswitch ===; grep -E "hosts:|networks:" /etc/nsswitch.conf'
dump "proxy-related env" bash -c 'env | grep -iE "^(http|https|no)_proxy=|^HTTP|^HTTPS|^NO_PROXY" || echo "(none)"'
dump "iptables vs nft" bash -c '
  echo "iptables: $(command -v iptables || echo missing)"
  sudo iptables -L -n 2>/dev/null | head -n 30 || true
  echo "nft: $(command -v nft || echo missing)"
  sudo nft list ruleset 2>/dev/null | head -n 40 || true
'

# ---------------------------------------------------------------------------
# 7. Container / Docker runtime
# ---------------------------------------------------------------------------
section "container / docker runtime"
kv "docker present?" bash -c 'command -v docker >/dev/null && docker --version || echo missing'
kv "podman present?" bash -c 'command -v podman >/dev/null && podman --version || echo missing'
kv "containerd present?" bash -c 'command -v containerd >/dev/null && containerd --version || echo missing'
if command -v docker >/dev/null 2>&1; then
  dump "docker info" sudo docker info
  dump "docker info --format security/cgroup/storage" bash -c 'sudo docker info --format "CgroupDriver={{.CgroupDriver}} CgroupVersion={{.CgroupVersion}} StorageDriver={{.Driver}} LoggingDriver={{.LoggingDriver}} SecurityOptions={{.SecurityOptions}} DefaultRuntime={{.DefaultRuntime}} Isolation={{.Isolation}} OSType={{.OSType}} Architecture={{.Architecture}} NCPU={{.NCPU}} MemTotal={{.MemTotal}} DockerRootDir={{.DockerRootDir}} ServerVersion={{.ServerVersion}}"'
  dump "docker default ulimits (info)" bash -c 'sudo docker info 2>/dev/null | grep -iA20 ulimit || true'
  dump "docker system df" sudo docker system df
  dump "containerd config.toml (head)" bash -c 'sudo head -n 80 /etc/containerd/config.toml 2>/dev/null || true'
  dump "dockerd unit drop-ins" bash -c 'systemctl cat docker 2>/dev/null | head -n 120 || true'
fi
dump "/etc/docker/daemon.json" bash -c 'cat /etc/docker/daemon.json 2>/dev/null || sudo cat /etc/docker/daemon.json 2>/dev/null || echo "(none)"'
kv "default shm (/dev/shm)" bash -c 'df -h /dev/shm; mount | grep /dev/shm || true'

# ---------------------------------------------------------------------------
# 8. Security / LSM
# ---------------------------------------------------------------------------
section "security / LSM / hardening"
kv "AppArmor" bash -c 'command -v aa-status >/dev/null && sudo aa-status || (cat /sys/module/apparmor/parameters/enabled 2>/dev/null; echo)'
kv "SELinux" bash -c 'command -v getenforce >/dev/null && getenforce || (cat /sys/fs/selinux/enforce 2>/dev/null || echo "(no selinux)")'
dump "seccomp" bash -c 'grep -i seccomp /boot/config-$(uname -r) 2>/dev/null | head || echo "(no config-$uname)"; ls /usr/share/docker/seccomp 2>/dev/null || true'
dump "LSM list" bash -c 'cat /sys/kernel/security/lsm 2>/dev/null || true'
dump "sysctl hardening knobs" bash -c "sysctl kernel.unprivileged_userns_clone kernel.unprivileged_bpf_disabled kernel.kptr_restrict kernel.dmesg_restrict kernel.yama.ptrace_scope kernel.perf_event_paranoid fs.protected_hardlinks fs.protected_symlinks fs.protected_fifos fs.protected_regular fs.suid_dumpable 2>/dev/null || true"
dump "user namespaces" bash -c 'ls -l /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null; id; cat /proc/self/status | grep -E "^(Cap|NSpid|Seccomp)"'
kv "bpf lockdown / lockdown" bash -c 'cat /sys/kernel/security/lockdown 2>/dev/null || echo "(no lockdown file)"'

# ---------------------------------------------------------------------------
# 9. Time, journals, services
# ---------------------------------------------------------------------------
section "time / journal / tuning-related services"
dump "timedatectl" timedatectl
dump "timesync status" bash -c 'timedatectl timesync-status 2>/dev/null || systemctl status systemd-timesyncd --no-pager 2>/dev/null | head -n 25 || true'
dump "journald.conf Limit* / Rate*" bash -c 'grep -E "^(Rate|System|Runtime|Compress|Storage|Forward)" /etc/systemd/journald.conf 2>/dev/null; ls /etc/systemd/journald.conf.d 2>/dev/null; cat /etc/systemd/journald.conf.d/* 2>/dev/null || true'
dump "tuning-related units" bash -c '
  for u in irqbalance tuned sysstat atop collectd haveged rngd chrony systemd-timesyncd docker containerd snap.amazon-ssm-agent.amazon-ssm-agent walinuxagent; do
    state=$(systemctl is-enabled "$u" 2>/dev/null || echo n/a)
    active=$(systemctl is-active "$u" 2>/dev/null || echo n/a)
    echo "$u enabled=$state active=$active"
  done
'
dump "crontab root / runner" bash -c 'sudo crontab -l 2>/dev/null || echo "(no root crontab)"; crontab -l 2>/dev/null || echo "(no user crontab)"'
dump "systemctl list-timers --all (head)" bash -c 'systemctl list-timers --all --no-pager 2>/dev/null | head -n 40'

# ---------------------------------------------------------------------------
# 10. User / session environment
# ---------------------------------------------------------------------------
section "runner user / session environment"
dump "id / groups" id
dump "env (selected)" bash -c 'env | grep -iE "^(PATH|HOME|USER|SHELL|LANG|LC_|TMPDIR|TMP|TEMP|GOMAXPROCS|JAVA_|NODE_|PYTHON|UV_|PIP_|npm_|DOCKER|CONTAINER|XDG_|CI|GITHUB_|RUNNER_|Image)" | sort'
dump "pwd / df workspace" bash -c 'pwd; df -h .; df -h "$HOME" 2>/dev/null || true'
dump "systemctl --user status (head)" bash -c 'systemctl --user status 2>/dev/null | head -n 30 || echo "(no user systemd or lingering)"'
kv "loginctl user-status" bash -c "loginctl user-status \"$(whoami)\" 2>/dev/null | head -n 40 || true"
dump "pam limits snippets" bash -c 'grep -RIn "pam_limits\|nofile\|nproc" /etc/pam.d 2>/dev/null | head -n 40 || true'

section "kernel cmdline"
kv "cmdline" cat /proc/cmdline

section "dmesg summary (boot/tuning hints, truncated)"
dump "dmesg Command line / Memory / CPU / Ext4 / TCP" bash -c "sudo dmesg -T 2>/dev/null | grep -iE 'Command line:|Memory:|CPU:|Hugepages|Write protecting|Ext4-fs|TCP:|random:|IO scheduler|Azure|Hyper-V' | head -n 80 || true"

section "done"
echo "collect-sysctl.sh finished at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
