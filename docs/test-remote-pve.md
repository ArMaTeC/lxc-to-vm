<!-- ==============================================================================
     ### lxc-to-vm file header ###
     File: test-remote-pve.md
     Description: Test remote pve
     License: MIT
     ============================================================================== -->
# test-remote-pve.sh

Automated remote Proxmox VE test helper for validating LXC-to-VM conversions.

## Overview

`test-remote-pve.sh` connects to a remote Proxmox VE host via SSH, copies the conversion scripts, and runs automated conversion tests against designated containers and VMs. It is designed for CI/CD validation and regression testing.

## Requirements

- `sshpass` installed on the local machine (script will attempt to auto-install)
- SSH access to the target Proxmox host
- Root credentials for the target Proxmox host
- Pre-existing LXC containers on the remote host to convert

## Configuration

Edit the variables at the top of the script before running:

| Variable | Default | Description |
| --- | --- | --- |
| `PVE_IP` | `192.168.1.29` | IP address of the remote Proxmox host |
| `PVE_USER` | `root` | SSH username |
| `PVE_PASS` | `AllWashedout22` | SSH password |
| `CT126_ID` | `126` | Source LXC container ID (first test) |
| `CT127_ID` | `127` | Source LXC container ID (second test) |
| `VM260_ID` | `260` | Target VM ID (first test) |
| `VM261_ID` | `261` | Target VM ID (second test) |
| `STORAGE` | `local-lvm` | Target storage pool |

> **Security Note**: Hardcoded credentials are for test environments only. For production use, configure SSH key-based authentication and remove the password.

## Usage

```bash
# Run the test suite (no arguments)
./test-remote-pve.sh
```

## What It Does

1. **Connection Check** - Verifies SSH connectivity to the remote PVE host
2. **Cleanup** - Stops and destroys existing test VMs (260, 261)
3. **Deploy** - Copies `lxc-to-vm.sh` and `shrink-lxc.sh` to the remote host
4. **Test 1** - Converts CT 126 → VM 260 with `--shrink --start`
5. **Test 2** - Converts CT 127 → VM 261 with `--shrink --start`
6. **Status Check** - Reports VM status and config after conversion

## Exit Codes

| Code | Meaning |
| --- | --- |
| `0` | All tests completed (individual conversions may have logged errors) |
| `1` | SSH connection failed or `sshpass` installation failed |

## Logs

- `/tmp/lxc-to-vm-126.log` - Output from the first conversion test
- `/tmp/lxc-to-vm-127.log` - Output from the second conversion test

## Viewing Results

```bash
# Check VM status on the remote host
qm status 260
qm config 260

# Access VM console
qm terminal 260 -iface serial0
```

## See Also

- [lxc-to-vm.sh](lxc-to-vm) - The conversion script under test
- [shrink-lxc.sh](shrink-lxc) - Container optimizer used during testing
- [API & Automation](API-Automation) - CI/CD integration patterns

> **PowerShell Users**: A `test-remote-pve.ps1` variant is also available for Windows hosts.
