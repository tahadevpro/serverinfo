# ServerInfo

Comprehensive Linux server audit script (Human-readable output).

This script collects a wide range of system information from Linux servers and displays it in a clear, readable format in the terminal. All data is collected safely without creating persistent files; temporary files are stored in RAM and removed after execution.

## Features

- **System Info:** Hostname, OS, Kernel, Uptime, Load Average
- **CPU & Memory:** CPU model, architecture, logical cores, memory total/available
- **Disk Info:** Detected disks, RAID presence, SMART health
- **I/O Stats:** Disk I/O statistics
- **Network:** Interfaces, routes, listening ports
- **Processes:** Top 20 CPU-consuming processes
- **GPU Info:** Detected NVIDIA GPUs or other display adapters
- **Performance Tests:**
  - **fio:** Random and sequential read/write tests
  - **iperf3:** Network throughput test to a specified server
- **Safe Execution:** No persistent files; temporary files in RAM (`/dev/shm`) and cleaned automatically
- **Single Command Execution:** No additional parameters required

## Prerequisites

For full functionality, ensure the following commands are installed:

```bash
smartctl fio iperf3 iostat nvidia-smi mdadm


Usage

Run the script directly from GitHub with a single command:

sudo bash -c "$(curl -sSL https://raw.githubusercontent.com/tahadevpro/serverinfo/main/server_audit.sh)"


No additional parameters are required.

Output is printed directly to the terminal in a human-readable format.
Example Output (excerpt)
------------------------------------------------------------------------
Server Audit Summary (All output Human-readable)
Generated: 2025-10-22T12:34:56+00:00
Host: myserver.example.com
Kernel: Linux 6.2.0-arch x86_64 GNU/Linux
OS: Arch Linux
Uptime (sec): 123456
Load avg: 0.23 0.45 0.67
------------------------------------------------------------------------
CPU: Intel(R) Xeon(R) CPU E5-2670 v3 @ 2.30GHz (x86_64), Logical cores: 16
Memory: total_bytes=65823488, available_bytes=43211264
------------------------------------------------------------------------
Disks detected: /dev/sda /dev/nvme0n1
  /dev/sda SMART Health: PASSED
  /dev/nvme0n1 SMART Health: PASSED
------------------------------------------------------------------------
RAID Present: false
------------------------------------------------------------------------
I/O stats (sample):
Device: rrqm/s wrqm/s  ...
sda     0.00 0.00 ...
...
------------------------------------------------------------------------
Network Interfaces (brief):
lo               UNKNOWN        127.0.0.1/8 ::1/128
eth0             UP             192.168.1.10/24 fe80::1/64
Default route:
default via 192.168.1.1 dev eth0
------------------------------------------------------------------------
Top processes snapshot:
PID   PPID CMD               %MEM  %CPU
1234  1    nginx             1.2   12.3
...
------------------------------------------------------------------------
GPU Info:
+-----------------------------------------------------------------------------+
| NVIDIA-SMI 525.105.17    Driver Version: 525.105.17    CUDA Version: 12.1 |
| GPU  Name        Persistence-M| Bus-Id        Disp.A | Volatile Uncorr. ECC |
| 0    Tesla T4     On          | 00000000:00:1E.0 Off | N/A                 |
...
------------------------------------------------------------------------
FIO Results:
...
------------------------------------------------------------------------
iperf3 Results:
...
------------------------------------------------------------------------
Temporary files were stored in RAM under /dev/shm/server_audit_12345 and removed on exit.
Script finished.
Notes

All tests and commands are read-only and safe for production servers.

GPU detection works for NVIDIA GPUs via nvidia-smi or other GPUs via lspci.

I/O and network tests (fio and iperf3) can generate load; ensure you are aware before running on production.
