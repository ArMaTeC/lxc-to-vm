# API & Automation

Guide for programmatic control and automation of conversions using the Proxmox VE API.

---

## Table of Contents

1. [Overview](#overview)
2. [API Token Setup](#api-token-setup)
3. [Cluster Operations](#cluster-operations)
4. [Batch Automation](#batch-automation)
5. [CI/CD Integration](#cicd-integration)
6. [Scripting Examples](#scripting-examples)

---

## Overview

All scripts support Proxmox VE API integration and automation for:

- **Cluster Operations** - Migrate containers/VMs between nodes before conversion
- **Remote Execution** - Trigger conversions and disk operations from external systems
- **Automation** - Schedule batch conversions and disk management, integrate with CI/CD

The full suite of scripts available for automation:

| Script | Purpose |
| ------ | ------- |
| `lxc-to-vm.sh` | Convert LXC containers to KVM VMs |
| `vm-to-lxc.sh` | Convert KVM VMs to LXC containers |
| `shrink-lxc.sh` | Shrink LXC container disk to actual usage |
| `expand-lxc.sh` | Expand LXC container disk |
| `shrink-vm.sh` | Shrink VM disk to actual usage |
| `expand-vm.sh` | Expand VM disk |
| `clone-replace-disk.sh` | Clone and replace VM/LXC disks |

---

## API Token Setup

### Creating an API Token

1. **Via Web Interface:**
   - Datacenter → Permissions → API Tokens
   - Click "Add"
   - Select user (e.g., `root@pam`)
   - Set token name (e.g., `converter`)
   - Copy the token value

2. **Via CLI:**

```bash
pveum user token add root@pam converter --privsep=0
```

### Required Privileges

| Privilege | Purpose |
| --------- | ------- |
| `VM.Audit` | Read VM configuration |
| `VM.Config.Disk` | Modify VM disks |
| `VM.PowerMgmt` | Start/stop VMs |
| `VM.Allocate` | Create VMs |
| `Datastore.AllocateSpace` | Import disks |
| `Datastore.Audit` | Read storage info |
| `Sys.Modify` | Migration operations |
| `CTVM.Map` | Map containers to VMs |

### Token File Format

Create `api-token.conf`:

```bash
API_HOST="proxmox-cluster.example.com"
API_TOKEN="root@pam!converter=xxxxx-xxxxx-xxxxx"
API_USER="root@pam"
```

---

## Cluster Operations

### Migrating Before Conversion

When container/VM is on a different node:

```bash
# Migrate container to local node, then convert
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm \
  --api-host proxmox-node1.example.com \
  --api-token "root@pam!converter=xxxxx" \
  --migrate-to-local

# Migrate VM to local, then convert
sudo ./vm-to-lxc.sh -v 200 -c 100 -s local-lvm \
  --api-host proxmox-node2.example.com \
  --api-token "root@pam!converter=xxxxx" \
  --migrate-to-local
```

### API Arguments

| Argument | Description | Example |
| -------- | ----------- | ------- |
| `--api-host` | Proxmox API hostname | `proxmox.example.com` |
| `--api-token` | API token string | `user@realm!tokenid=uuid` |
| `--api-user` | API user (optional) | `root@pam` |
| `--migrate-to-local` | Migrate to local node first | Flag only |

---

## Batch Automation

### Scheduled Batch Conversions

**Cron job for nightly conversions:**

```bash
# /etc/cron.d/conversions
0 2 * * * root /usr/local/bin/lxc-to-vm --batch /etc/conversions/nightly.txt >> /var/log/conversions.log 2>&1
```

### Batch File Format

```bash
# /etc/conversions/nightly.txt
# Format: SOURCE TARGET [storage] [disk-size]

# lxc-to-vm batch file
100 200 local-lvm 10G
101 201 local-lvm 15G
102 202 local-lvm auto

# vm-to-lxc batch file
200 100 local-lvm
201 101 local-lvm 8G
```

### Parallel Processing

```bash
# Convert 8 containers simultaneously
sudo ./lxc-to-vm.sh --batch /etc/conversions/nightly.txt --parallel 8
```

---

## CI/CD Integration

### GitLab CI Example

```yaml
# .gitlab-ci.yml
stages:
  - convert

convert_lxc_to_vm:
  stage: convert
  script:
    - apt-get update && apt-get install -y curl
    - curl -O https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/lxc-to-vm.sh
    - chmod +x lxc-to-vm.sh
    - ./lxc-to-vm.sh -c $CTID -v $VMID -s $STORAGE --start
  variables:
    CTID: "100"
    VMID: "200"
    STORAGE: "local-lvm"
  only:
    - triggers
```

### GitHub Actions Example

```yaml
# .github/workflows/convert.yml
name: Convert LXC to VM
on:
  workflow_dispatch:
    inputs:
      ctid:
        description: 'Source Container ID'
        required: true
      vmid:
        description: 'Target VM ID'
        required: true

jobs:
  convert:
    runs-on: self-hosted
    steps:
      - name: Checkout
        uses: actions/checkout@v3

      - name: Run Conversion
        run: |
          sudo ./lxc-to-vm.sh -c ${{ github.event.inputs.ctid }} \
            -v ${{ github.event.inputs.vmid }} \
            -s local-lvm --start
```

### Ansible Playbook

```yaml
# convert.yml
- name: Convert LXC to VM
  hosts: proxmox
  become: yes
  tasks:
    - name: Download converter script
      get_url:
        url: https://raw.githubusercontent.com/ArMaTeC/lxc-to-vm/main/lxc-to-vm.sh
        dest: /tmp/lxc-to-vm.sh
        mode: '0755'

    - name: Run conversion
      command: >
        /tmp/lxc-to-vm.sh
        -c {{ source_ctid }}
        -v {{ target_vmid }}
        -s {{ storage }}
        --start
      vars:
        source_ctid: "100"
        target_vmid: "200"
        storage: "local-lvm"
```

---

## Scripting Examples

### Bulk Conversion Script

```bash
#!/bin/bash
# bulk-convert.sh - Convert multiple containers

CTIDS=(100 101 102 103)
BASE_VMID=200
STORAGE="local-lvm"

for i in "${!CTIDS[@]}"; do
    CTID=${CTIDS[$i]}
    VMID=$((BASE_VMID + i))

    echo "Converting CT $CTID to VM $VMID..."

    sudo ./lxc-to-vm.sh -c $CTID -v $VMID -s $STORAGE --start

    if [ $? -eq 0 ]; then
        echo "✅ CT $CTID → VM $VMID successful"
    else
        echo "❌ CT $CTID → VM $VMID failed"
    fi
done
```

### Conditional Conversion

```bash
#!/bin/bash
# Convert only if container is running

CTID=100
VMID=200

# Check if container is running
if pct status $CTID | grep -q "running"; then
    echo "Container $CTID is running, converting..."
    sudo ./lxc-to-vm.sh -c $CTID -v $VMID -s local-lvm --start
else
    echo "Container $CTID is not running, skipping"
fi
```

### Post-Conversion Verification

```bash
#!/bin/bash
# Convert and verify

CTID=100
VMID=200

# Convert
sudo ./lxc-to-vm.sh -c $CTID -v $VMID -s local-lvm --start

# Wait for VM to boot
sleep 30

# Verify health
if qm agent $VMID ping 2>/dev/null; then
    echo "✅ VM $VMID is healthy"

    # Destroy original container
    pct stop $CTID
    pct destroy $CTID
else
    echo "❌ VM $VMID health check failed"
fi
```

### Shrink + Convert Pipeline

Automate the shrink-before-convert workflow:

```bash
#!/bin/bash
# shrink-and-convert.sh

CTID=100
VMID=200
STORAGE="local-lvm"

echo "Shrinking CT $CTID..."
sudo ./shrink-lxc.sh -c $CTID --force

echo "Converting CT $CTID to VM $VMID..."
sudo ./lxc-to-vm.sh -c $CTID -v $VMID -s $STORAGE --start

echo "Done: CT $CTID → VM $VMID"
```

### Bulk VM Disk Expansion

```bash
#!/bin/bash
# expand-all-vms.sh - Add 20GB to a list of VMs

VMIDS=(100 101 102 103)

for VMID in "${VMIDS[@]}"; do
    echo "Expanding VM $VMID by 20GB..."
    sudo ./expand-vm.sh -v $VMID -a 20 --force
done
```

### Automated Disk Shrink Before Migration

```bash
#!/bin/bash
# shrink-vm-for-migration.sh

VMID=200

echo "Shrinking VM $VMID..."
sudo ./shrink-vm.sh -v $VMID --force

echo "Current disk after shrink:"
qm config $VMID | grep -E '^(scsi|virtio|ide)0'
```

### Disk Clone and Replace (CI/CD fix step)

```bash
#!/bin/bash
# fix-guest-disk-size.sh

TYPE="lxc"   # or "vm"
ID=100
NEW_SIZE=200

echo "Cloning and replacing disk for $TYPE $ID to ${NEW_SIZE}GB..."
sudo ./clone-replace-disk.sh -t $TYPE -i $ID --size $NEW_SIZE --force
```

---

## Related Documentation

- **[lxc-to-vm.sh](lxc-to-vm)** - LXC to VM guide
- **[vm-to-lxc.sh](vm-to-lxc)** - VM to LXC guide
- **[shrink-lxc.sh](shrink-lxc)** - Shrink LXC disks
- **[expand-lxc.sh](expand-lxc)** - Expand LXC disks
- **[shrink-vm.sh](shrink-vm)** - Shrink VM disks
- **[expand-vm.sh](expand-vm)** - Expand VM disks
- **[clone-replace-disk.sh](clone-replace-disk)** - Clone and replace disks
- **[Hooks](Hooks)** - Automation hooks
- **[Examples](Examples)** - More automation examples
