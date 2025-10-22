#!/usr/bin/env bash
# server_audit.sh
# Comprehensive Linux server audit script (Human-readable output)
# All features enabled by default: CPU, RAM, Disk, SMART, RAID, Network, I/O, Processes, GPU, fio, iperf3
# No persistent files, everything stored in RAM and cleaned on exit

set -euo pipefail

###############################################################################
# Temporary workspace (RAM)
###############################################################################
SHM_BASE="/dev/shm"
SCRIPT_RUN_ID="server_audit_$$"
SHM_DIR="$SHM_BASE/$SCRIPT_RUN_ID"
mkdir -m 700 -p "$SHM_DIR"

cleanup() {
  rm -rf "$SHM_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

###############################################################################
# Default options (all enabled)
###############################################################################
RUN_FIO=true
IPERF_SERVER="1.2.3.4"   # replace with your iperf3 server IP
OUTPUT_JSON=false

###############################################################################
# Root check
###############################################################################
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: This script must be run as root (sudo)."
  exit 1
fi

pp() { printf "%s\n" "$*"; }
pp_sep() { printf -- '%.0s-' $(seq 1 72); printf "\n"; }

START_TS=$(date --iso-8601=seconds 2>/dev/null || date -Iseconds)

###############################################################################
# Collect core system data
###############################################################################
HOSTNAME_FULL=$(hostname -f 2>/dev/null || hostname)
KERNEL=$(uname -srmo 2>/dev/null || uname -sr)
OS_RELEASE=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
CPU_MODEL=$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | sed 's/^[ \t]*//')
CPU_ARCH=$(uname -m)
CPU_CORES_LOGICAL=$(nproc)
LOADAVG=$(cut -d' ' -f1-3 /proc/loadavg)
MEM_TOTAL_BYTES=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEM_AVAILABLE_BYTES=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
UPTIME_SECONDS=$(awk '{print int($1)}' /proc/uptime)

###############################################################################
# Disk & SMART
###############################################################################
DISKS=($(ls /dev/sd[a-z] 2>/dev/null) $(ls /dev/nvme?n1 2>/dev/null))
declare -A SMART_SUMMARY
if command -v smartctl >/dev/null 2>&1; then
  for d in "${DISKS[@]}"; do
    out="$SHM_DIR/smart_${d##*/}.txt"
    smartctl -i -H -A "$d" >"$out" 2>&1 || true
    SMART_SUMMARY["$d"]=$(awk -F: '/overall-health|SMART overall-health/ {print $2; exit}' "$out" | sed 's/^[ \t]*//g')
  done
fi

###############################################################################
# RAID check
###############################################################################
RAID_PRESENT=false
if command -v mdadm >/dev/null 2>&1 && ls /dev/md* >/dev/null 2>&1; then
  RAID_PRESENT=true
fi

###############################################################################
# I/O stats
###############################################################################
IO_STATS_FILE="$SHM_DIR/iostats.txt"
if command -v iostat >/dev/null 2>&1; then
  iostat -xz 1 2 > "$IO_STATS_FILE" 2>&1 || true
else
  awk '{print $3,$4,$5,$6,$7,$8,$9,$10,$11,$12}' /proc/diskstats | head -n 40 > "$IO_STATS_FILE" || true
fi

###############################################################################
# Network
###############################################################################
IP_BR_FILE="$SHM_DIR/ip_br.txt"
ip -br address > "$IP_BR_FILE" 2>/dev/null || true
IP_ROUTE_FILE="$SHM_DIR/ip_route.txt"
ip route > "$IP_ROUTE_FILE" 2>/dev/null || true
SS_FILE="$SHM_DIR/ss_out.txt"
ss -tunlp > "$SS_FILE" 2>/dev/null || true

###############################################################################
# Top processes
###############################################################################
TOP_PS_FILE="$SHM_DIR/top_ps.txt"
ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 20 > "$TOP_PS_FILE" 2>/dev/null || true

###############################################################################
# GPU info
###############################################################################
GPU_PRESENT=false
GPU_RAW_FILE="$SHM_DIR/gpu_raw.txt"
if command -v nvidia-smi >/dev/null 2>&1; then
  GPU_PRESENT=true
  nvidia-smi > "$GPU_RAW_FILE" 2>/dev/null || true
elif command -v lspci >/dev/null 2>&1; then
  lspci | grep -i -E 'vga|3d|display' > "$GPU_RAW_FILE" 2>/dev/null || true
  [ -s "$GPU_RAW_FILE" ] && GPU_PRESENT=true
fi

###############################################################################
# fio test
###############################################################################
if [ "$RUN_FIO" = true ] && command -v fio >/dev/null 2>&1; then
  FIO_WORKDIR="$SHM_DIR/fio"
  mkdir -p "$FIO_WORKDIR"
  FIO_JOB="$FIO_WORKDIR/fio_job.job"
  cat > "$FIO_JOB" <<'FIOJOB'
[global]
ioengine=libaio
direct=1
time_based=1
runtime=8
group_reporting=1
bs=1M

[randread]
rw=randread
size=64M
numjobs=2
filename=/dev/shm/fio_randread_testfile

[randwrite]
rw=randwrite
size=64M
numjobs=2
filename=/dev/shm/fio_randwrite_testfile

[seqwrite]
rw=write
bs=1M
size=64M
numjobs=1
filename=/dev/shm/fio_seqwrite_testfile

[seqread]
rw=read
bs=1M
size=64M
numjobs=1
filename=/dev/shm/fio_seqread_testfile
FIOJOB
  FIO_RESULTS_FILE="$SHM_DIR/fio_result.txt"
  fio "$FIO_JOB" > "$FIO_RESULTS_FILE" 2>&1 || true
fi

###############################################################################
# iperf3 test
###############################################################################
if [ -n "$IPERF_SERVER" ] && command -v iperf3 >/dev/null 2>&1; then
  IPERF_RESULT_FILE="$SHM_DIR/iperf3_result.txt"
  iperf3 -c "$IPERF_SERVER" -t 10 > "$IPERF_RESULT_FILE" 2>&1 || true
fi

###############################################################################
# Display results
###############################################################################
pp_sep
pp "Server Audit Summary (All output Human-readable)"
pp "Generated: $START_TS"
pp "Host: $HOSTNAME_FULL"
pp "Kernel: $KERNEL"
pp "OS: $OS_RELEASE"
pp "Uptime (sec): $UPTIME_SECONDS"
pp "Load avg: $LOADAVG"
pp_sep

pp "CPU: $CPU_MODEL ($CPU_ARCH), Logical cores: $CPU_CORES_LOGICAL"
pp "Memory: total_bytes=$MEM_TOTAL_BYTES, available_bytes=$MEM_AVAILABLE_BYTES"
pp_sep

pp "Disks detected: ${DISKS[*]}"
for d in "${DISKS[@]}"; do
  pp "  $d SMART Health: ${SMART_SUMMARY[$d]:-N/A}"
done
pp_sep

pp "RAID Present: $RAID_PRESENT"
pp_sep

pp "I/O stats (sample):"
head -n 20 "$IO_STATS_FILE"
pp_sep

pp "Network Interfaces (brief):"
cat "$IP_BR_FILE"
pp "Default route:"
cat "$IP_ROUTE_FILE"
pp_sep

pp "Top processes snapshot:"
cat "$TOP_PS_FILE"
pp_sep

if [ "$GPU_PRESENT" = true ]; then
  pp "GPU Info:"
  cat "$GPU_RAW_FILE"
  pp_sep
fi

if [ "$RUN_FIO" = true ] && [ -n "${FIO_RESULTS_FILE:-}" ]; then
  pp "FIO Results:"
  head -n 50 "$FIO_RESULTS_FILE"
  pp_sep
fi

if [ -n "${IPERF_RESULT_FILE:-}" ]; then
  pp "iperf3 Results:"
  cat "$IPERF_RESULT_FILE"
  pp_sep
fi

pp "Temporary files were stored in RAM under $SHM_DIR and removed on exit."
pp "Script finished."
cleanup
exit 0
