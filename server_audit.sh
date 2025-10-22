#!/usr/bin/env bash
# full_server_audit.sh
# Single-file server audit script (English output).
# - No persistent files (uses /dev/shm; cleaned on exit)
# - Run as root (script will check)
# - Options:
#     --json            -> Output JSON only
#     --run-fio         -> Run safe fio micro-benchmarks (fio must be installed)
#     --iperf-server IP -> Run iperf3 test to given server (iperf3 must be installed)
#
# Usage (single-command from remote host):
# sudo bash -c "$(curl -sSL https://your-host/full_server_audit.sh)" -- --json --run-fio --iperf-server 1.2.3.4

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
# Parse args
###############################################################################
OUTPUT_JSON=false
RUN_FIO=false
IPERF_SERVER=""
QUIET=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) OUTPUT_JSON=true; shift ;;
    --run-fio) RUN_FIO=true; shift ;;
    --iperf-server) IPERF_SERVER="$2"; shift 2 ;;
    --quiet) QUIET=true; shift ;;
    --help|-h) echo "Usage: $0 [--json] [--run-fio] [--iperf-server <host>]"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

if [ "$EUID" -ne 0 ]; then
  cat >&2 <<'ERR'
ERROR: This script must be run as root (sudo).
ERR
  exit 1
fi

pp() { if [ "$OUTPUT_JSON" = false ]; then printf "%s\n" "$*"; fi }
pp_sep() { if [ "$OUTPUT_JSON" = false ]; then printf -- '%.0s-' $(seq 1 72); printf "\n"; fi }

capture() {
  local label="$1"; shift
  local out="$SHM_DIR/${label}.txt"
  if "$@" >"$out" 2>&1; then
    :
  else
    :
  fi
  printf "%s" "$out"
}

START_TS=$(date --iso-8601=seconds 2>/dev/null || date -Iseconds)

###############################################################################
# Collect core data
###############################################################################
HOSTNAME_FULL=$(hostname -f 2>/dev/null || hostname)
KERNEL=$(uname -srmo 2>/dev/null || uname -sr)
OS_RELEASE=""
if [ -f /etc/os-release ]; then
  OS_RELEASE=$(sed -n '1,40p' /etc/os-release | tr '\n' ';' )
fi
PPID="$(ps -p $$ -o ppid= | tr -d ' ')"

CPU_INFO_FILE=$(capture cpu_info lscpu || true)
CPU_MODEL=$(awk -F: '/Model name|Model/ {print $2; exit}' "$CPU_INFO_FILE" 2>/dev/null | sed 's/^[ \t]*//g' || true)
CPU_ARCH=$(uname -m)
CPU_CORES_LOGICAL=$(nproc --all 2>/dev/null || awk -F: '/^CPU\(s\)/{print $2; exit}' "$CPU_INFO_FILE" 2>/dev/null || true)
LOADAVG=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || true)

MEM_TOTAL_BYTES=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || true)
MEM_AVAILABLE_BYTES=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || true)

UPTIME_SECONDS=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || true)

LSBLK_OUT_FILE=$(capture lsblk_out lsblk -J -o NAME,MODEL,SIZE,ROTA,TYPE,MOUNTPOINT || true)
DF_OUT_FILE=$(capture df_out df -B1 --output=source,fstype,size,used,avail,pcent,target || true)

# list block devices
DISK_LIST=()
if ls /dev/sd[a-z] >/dev/null 2>&1; then
  while read -r d; do DISK_LIST+=("$d"); done < <(ls /dev/sd[a-z] 2>/dev/null || true)
fi
if ls /dev/nvme?n1 >/dev/null 2>&1; then
  while read -r d; do DISK_LIST+=("$d"); done < <(ls /dev/nvme?n1 2>/dev/null || true)
fi

###############################################################################
# SMART per-disk (smartctl)
###############################################################################
declare -A SMART_SUMMARY
SMART_AVAILABLE=false
if command -v smartctl >/dev/null 2>&1; then
  SMART_AVAILABLE=true
  for d in "${DISK_LIST[@]}"; do
    outfile="$SHM_DIR/smart_${d##*/}.txt"
    smartctl -i -H -A "$d" > "$outfile" 2>&1 || true
    SMART_HEALTH=$(awk -F: '/overall-health|SMART overall-health/ {print $2; exit}' "$outfile" 2>/dev/null | sed 's/^[ \t]*//g' || true)
    SMART_SUMMARY["$d,health"]="$SMART_HEALTH"
    RS=$(awk '/Reallocated_Sector_Ct/{print $10; exit}' "$outfile" 2>/dev/null || true)
    CPS=$(awk '/Current_Pending_Sector/{print $10; exit}' "$outfile" 2>/dev/null || true)
    TEMP=$(awk '/Temperature_Celsius/{print $10; exit}' "$outfile" 2>/dev/null || true)
    SMART_SUMMARY["$d,reallocated"]="$RS"
    SMART_SUMMARY["$d,pending"]="$CPS"
    SMART_SUMMARY["$d,temp"]="$TEMP"
  done
fi

###############################################################################
# RAID (mdadm) - software RAID
###############################################################################
RAID_RAW_FILE="$SHM_DIR/raid_raw.txt"
RAID_SUMMARY_FILE="$SHM_DIR/raid_summary.txt"
RAID_PRESENT=false
if command -v mdadm >/dev/null 2>&1; then
  if ls /dev/md* >/dev/null 2>&1; then
    RAID_PRESENT=true
    mdadm --detail --scan > "$RAID_RAW_FILE" 2>/dev/null || true
    for md in /dev/md*; do
      if [ -e "$md" ]; then
        mdadm --detail "$md" >> "$RAID_SUMMARY_FILE" 2>/dev/null || true
      fi
    done
  fi
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
IP_BR_FILE=$(capture ip_br ip -br address || true)
IP_ROUTE_FILE=$(capture ip_route ip route || true)
SS_FILE=$(capture ss_out ss -tunlp || true)

declare -A IFACE_LINK
if command -v ethtool >/dev/null 2>&1; then
  while read -r iface; do
    if [ "$iface" = "lo" ]; then continue; fi
    ifout="$SHM_DIR/ethtool_${iface}.txt"
    ethtool "$iface" >"$ifout" 2>/dev/null || true
    LINK_INFO=$(awk -F: '/Speed|Duplex|Link detected/ {gsub(/^[ \t]+/,"",$2); print $1": "$2}' "$ifout" 2>/dev/null | tr '\n' ';' || true)
    IFACE_LINK["$iface"]="$LINK_INFO"
  done < <(ip -o link show | awk -F': ' '{print $2}')
fi

NET_SPEED_RESULT=""
if command -v speedtest >/dev/null 2>&1; then
  SP_OUT="$SHM_DIR/speedtest.json"
  speedtest --accept-license --accept-gdpr --format=json >"$SP_OUT" 2>/dev/null || true
  NET_SPEED_RESULT="$SP_OUT"
elif command -v speedtest-cli >/dev/null 2>&1; then
  SP_OUT="$SHM_DIR/speedtest_cli.txt"
  speedtest-cli --json >"$SP_OUT" 2>/dev/null || true
  NET_SPEED_RESULT="$SP_OUT"
else
  TEST_URL="http://speedtest.tele2.net/10MB.zip"
  CURL_OUT="$SHM_DIR/curl_speed.txt"
  curl -s -o /dev/null -w "download_bytes:%{size_download} time:%{time_total} speed:%{speed_download}\n" "$TEST_URL" >"$CURL_OUT" 2>&1 || true
  NET_SPEED_RESULT="$CURL_OUT"
fi

TOP_PS_FILE=$(capture top_ps ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 20 || true)

###############################################################################
# Advanced: fio (opt-in)
###############################################################################
FIO_RESULTS_FILE=""
if [ "$RUN_FIO" = true ]; then
  if command -v fio >/dev/null 2>&1; then
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
  else
    FIO_RESULTS_FILE=""
  fi
fi

###############################################################################
# Advanced: iperf3 (opt-in)
###############################################################################
IPERF_RESULT_FILE=""
if [ -n "$IPERF_SERVER" ]; then
  if command -v iperf3 >/dev/null 2>&1; then
    IPERF_RESULT_FILE="$SHM_DIR/iperf3_result.txt"
    iperf3 -c "$IPERF_SERVER" -t 10 --json > "$IPERF_RESULT_FILE" 2>&1 || true
  else
    IPERF_RESULT_FILE=""
  fi
fi

###############################################################################
# GPU Info: nvidia-smi preferred, fallback to lspci
###############################################################################
GPU_RAW_FILE="$SHM_DIR/gpu_raw.txt"
GPU_SUMMARY_FILE="$SHM_DIR/gpu_summary.txt"
GPU_PRESENT=false
declare -a GPU_JSON_ENTRIES
if command -v nvidia-smi >/dev/null 2>&1; then
  GPU_PRESENT=true
  nvidia-smi --query-gpu=index,name,driver_version,memory.total,memory.used,utilization.gpu,temperature.gpu --format=csv,noheader,nounits > "$GPU_RAW_FILE" 2>/dev/null || true
  # parse into JSON-like strings
  while IFS=, read -r idx name driver memtot memused util temp; do
    name=$(echo "$name" | sed 's/^ *//;s/ *$//;s/"/\\"/g')
    GPU_JSON_ENTRIES+=("{\"index\": ${idx}, \"vendor\": \"NVIDIA\", \"model\": \"${name}\", \"driver\": \"${driver}\", \"memory_total_MB\": ${memtot:-0}, \"memory_used_MB\": ${memused:-0}, \"utilization_percent\": ${util:-0}, \"temperature_C\": ${temp:-0}}")
  done < "$GPU_RAW_FILE"
elif command -v lspci >/dev/null 2>&1; then
  lspci | grep -i -E 'vga|3d|display' > "$GPU_RAW_FILE" 2>/dev/null || true
  if [ -s "$GPU_RAW_FILE" ]; then
    GPU_PRESENT=true
    while IFS= read -r line; do
      esc=$(echo "$line" | sed 's/"/\\"/g')
      GPU_JSON_ENTRIES+=("{\"vendor_model_line\": \"${esc}\"}")
    done < "$GPU_RAW_FILE"
  fi
fi

###############################################################################
# Build JSON report (prefer python3)
###############################################################################
JSON_OUT_FILE="$SHM_DIR/report.json"

if command -v python3 >/dev/null 2>&1; then
  python3 - <<PY > "$JSON_OUT_FILE"
import json,os

shm = "${SHM_DIR}"
def read(path):
    try:
        with open(path,'r',errors='replace') as f:
            return f.read()
    except:
        return ""

report = {}
report['generated_at'] = "${START_TS}"
report['host'] = {
    "hostname": "${HOSTNAME_FULL}",
    "kernel": "${KERNEL}",
    "os_release_snippet": "${OS_RELEASE}",
    "parent_pid": "${PPID}"
}

report['cpu'] = {
    "arch": "${CPU_ARCH}",
    "model_line": "${CPU_MODEL}",
    "logical_cores": "${CPU_CORES_LOGICAL}",
    "load_average": "${LOADAVG}"
}

report['memory'] = {
    "total_bytes": int("${MEM_TOTAL_BYTES}" or 0),
    "available_bytes": int("${MEM_AVAILABLE_BYTES}" or 0)
}

report['uptime_seconds'] = int("${UPTIME_SECONDS}" or 0)

# disks and mounts
lsblk_file = "${LSBLK_OUT_FILE}"
if os.path.exists(lsblk_file):
    txt = read(lsblk_file)
    try:
        report['disks'] = json.loads(txt)
    except:
        report['disks'] = {'raw': txt}
else:
    report['disks'] = {}

report['mounts_raw'] = read("${DF_OUT_FILE}")

# SMART
report['smart'] = {'available': ${SMART_AVAILABLE}, 'disks': {}}
SMART_MAP = {}
PY

  # append SMART_MAP entries
  for k in "${!SMART_SUMMARY[@]}"; do
    disk="${k%%,*}"
    field="${k##*,}"
    value="${SMART_SUMMARY[$k]}"
    esc_disk=$(printf '%s' "$disk" | sed 's/\\/\\\\/g; s/"/\\"/g')
    esc_field=$(printf '%s' "$field" | sed 's/\\/\\\\/g; s/"/\\"/g')
    esc_value=$(printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g')
    cat >> "$JSON_OUT_FILE" <<PY
SMART_MAP.setdefault("${esc_disk}", {})["${esc_field}"] = "${esc_value}"
PY
  done

  cat >> "$JSON_OUT_FILE" <<'PY'
report['smart']['disks'] = SMART_MAP
report['raid'] = {}
report['raid']['present'] = ${RAID_PRESENT}
report['raid']['raw'] = read("${RAID_RAW_FILE}")
report['raid']['details'] = read("${RAID_SUMMARY_FILE}")
report['iostats_raw'] = read("${IO_STATS_FILE}")
report['network'] = {
    'interfaces_brief': read("${IP_BR_FILE}"),
    'routes': read("${IP_ROUTE_FILE}"),
    'sockets': read("${SS_FILE}"),
    'link_info': {}
}
# link info files
for fn in os.listdir("${SHM_DIR}"):
    if fn.startswith("ethtool_"):
        iface = fn.replace("ethtool_","").replace(".txt","")
        report['network']['link_info'][iface] = read(os.path.join("${SHM_DIR}",fn))

report['network']['speed_test_raw'] = read("${NET_SPEED_RESULT}")
report['processes'] = {'top_snapshot': read("${TOP_PS_FILE}")}

# fio
fio_file = "${FIO_RESULTS_FILE}"
if fio_file and os.path.exists(fio_file):
    report['fio'] = read(fio_file)
else:
    report['fio'] = None

# iperf3
iperf_file = "${IPERF_RESULT_FILE}"
if iperf_file and os.path.exists(iperf_file):
    try:
        report['iperf3'] = json.loads(read(iperf_file))
    except:
        report['iperf3'] = read(iperf_file)
else:
    report['iperf3'] = None

# GPU
report['gpu'] = []
PY

  # append GPU entries from bash variable
  for entry in "${GPU_JSON_ENTRIES[@]}"; do
    esc_entry=$(printf '%s' "$entry" | sed 's/\\/\\\\/g; s/"/\\"/g')
    cat >> "$JSON_OUT_FILE" <<PY
report['gpu'].append(json.loads("${esc_entry}"))
PY
  done

  cat >> "$JSON_OUT_FILE" <<'PY'
report['meta'] = {
    'smart_available': ${SMART_AVAILABLE},
    'raid_present': ${RAID_PRESENT},
    'fio_requested': ${RUN_FIO},
    'iperf_server': "${IPERF_SERVER}",
    'gpu_present': ${GPU_PRESENT},
    'note': "Temporary files stored in RAM under ${SHM_DIR} and removed on exit."
}
print(json.dumps(report, indent=2, ensure_ascii=False))
PY

else
  # fallback minimal JSON
  {
    echo "{"
    echo "  \"generated_at\": \"${START_TS}\","
    echo "  \"host\": {\"hostname\": \"${HOSTNAME_FULL}\", \"kernel\": \"${KERNEL}\"},"
    echo "  \"note\": \"Python3 not available; limited JSON provided.\""
    echo "}"
  } > "$JSON_OUT_FILE"
fi

###############################################################################
# Output to user
###############################################################################
if [ "$OUTPUT_JSON" = true ]; then
  cat "$JSON_OUT_FILE"
  exit 0
fi

pp_sep
pp "Server Audit Summary (temporary files in RAM; cleaned on exit)"
pp "Generated: ${START_TS}"
pp ""
pp "Host: ${HOSTNAME_FULL}"
pp "Kernel: ${KERNEL}"
pp "OS release (snippet): ${OS_RELEASE:-not available}"
pp "Uptime (sec): ${UPTIME_SECONDS}"
pp "Load avg: ${LOADAVG}"
pp_sep

pp "CPU: ${CPU_MODEL:-unknown} (${CPU_ARCH}), logical cores: ${CPU_CORES_LOGICAL}"
pp "Memory: total_bytes=${MEM_TOTAL_BYTES:-0}, available_bytes=${MEM_AVAILABLE_BYTES:-0}"
pp_sep

pp "Disk and mount overview (lsblk JSON or raw):"
if [ -s "${LSBLK_OUT_FILE}" ]; then
  sed -n '1,20p' "${LSBLK_OUT_FILE}" | sed 's/^/  /'
else
  pp "  lsblk not available"
fi
pp_sep

pp "SMART summary available: ${SMART_AVAILABLE}"
if [ "${SMART_AVAILABLE}" = true ]; then
  for key in "${!SMART_SUMMARY[@]}"; do
    disk="${key%%,*}"
    field="${key##*,}"
    val="${SMART_SUMMARY[$key]}"
    pp "  ${disk} ${field}: ${val}"
  done
fi
pp_sep

pp "RAID present: ${RAID_PRESENT}"
if [ "${RAID_PRESENT}" = true ]; then
  pp "RAID detail (mdadm --detail outputs):"
  sed -n '1,200p' "$RAID_SUMMARY_FILE" | sed 's/^/  /' || true
fi
pp_sep

pp "I/O stats (sample):"
sed -n '1,20p' "$IO_STATS_FILE" | sed 's/^/  /'
pp_sep

pp "Network interfaces (brief):"
sed -n '1,20p' "$IP_BR_FILE" | sed 's/^/  /'
pp "Default route:"
sed -n '1,10p' "$IP_ROUTE_FILE" | sed 's/^/  /'
pp_sep

if [ -s "${NET_SPEED_RESULT}" ]; then
  pp "Network speed test (raw):"
  sed -n '1,20p' "$NET_SPEED_RESULT" | sed 's/^/  /'
  pp_sep
fi

pp "Top processes snapshot:"
sed -n '1,20p' "$TOP_PS_FILE" | sed 's/^/  /'
pp_sep

if [ -n "$FIO_RESULTS_FILE" ] && [ -s "$FIO_RESULTS_FILE" ]; then
  pp "FIO results (safe run):"
  sed -n '1,200p' "$FIO_RESULTS_FILE" | sed 's/^/  /'
  pp_sep
elif [ "$RUN_FIO" = true ]; then
  pp "FIO requested but fio is not installed or failed."
  pp_sep
fi

if [ -n "$IPERF_RESULT_FILE" ] && [ -s "$IPERF_RESULT_FILE" ]; then
  pp "iperf3 result (raw):"
  sed -n '1,200p' "$IPERF_RESULT_FILE" | sed 's/^/  /'
  pp_sep
elif [ -n "$IPERF_SERVER" ]; then
  pp "iperf3 requested but iperf3 is not installed or test failed."
  pp_sep
fi

if [ "${GPU_PRESENT}" = true ]; then
  pp "GPU info:"
  if [ -s "$GPU_RAW_FILE" ]; then
    sed -n '1,20p' "$GPU_RAW_FILE" | sed 's/^/  /'
  else
    pp "  GPU raw data not available"
  fi
  pp_sep
fi

pp "Structured JSON attached below for machines and automation."
pp_sep
cat "$JSON_OUT_FILE"
pp_sep
pp "Temporary files were stored in RAM under ${SHM_DIR} and removed on exit."
pp "To get JSON only, re-run with --json."
pp "Script finished."
cleanup
exit 0
