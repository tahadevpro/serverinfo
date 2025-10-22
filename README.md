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
