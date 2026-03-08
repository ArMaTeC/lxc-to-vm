# Examples & Best Practices

Real-world examples and best practices for using the Proxmox LXC ↔️ VM Converter suite.

---

## Table of Contents

1. [Quick Examples](#quick-examples)
2. [Production Workflows](#production-workflows)
3. [Migration Scenarios](#migration-scenarios)
4. [Batch Operations](#batch-operations)
5. [Troubleshooting Examples](#troubleshooting-examples)
6. [Best Practices](#best-practices)

---

## Quick Examples

### Example 1: Simple LXC to VM

```bash
# Convert container 100 to VM 200 on local-lvm storage
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --start
```

### Example 2: VM to LXC with Auto-Start

```bash
# Convert VM 200 to container 100 with auto-start
sudo ./vm-to-lxc.sh -v 200 -c 100 -s local-lvm --start
```

### Example 3: Shrink Before Convert

```bash
# Optimize container then convert
sudo ./shrink-lxc.sh -c 100 --resize
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --start
```

### Example 4: Safe Conversion with Snapshot

```bash
# Create snapshot, convert, rollback on failure
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm \
  --snapshot --rollback-on-failure --start
```

---

## Production Workflows

### Workflow 1: Dev to Production Migration

**Scenario:** Move development container to production VM

```bash
#!/bin/bash
# dev-to-prod.sh

DEV_CTID=100
PROD_VMID=500
STORAGE="prodmox-storage"

# 1. Shrink dev container
sudo ./shrink-lxc.sh -c $DEV_CTID --resize

# 2. Convert with UEFI for production
sudo ./lxc-to-vm.sh -c $DEV_CTID -v $PROD_VMID -s $STORAGE \
  --uefi --snapshot --start

# 3. Configure production settings
qm set $PROD_VMID --cpu host
qm set $PROD_VMID --memory 4096
qm set $PROD_VMID --tags "production,converted"

# 4. Run health check
sleep 30
if qm agent $PROD_VMID ping; then
    echo "✅ Production VM ready"
else
    echo "❌ Health check failed - investigate"
fi
```

### Workflow 2: VM Consolidation

**Scenario:** Convert multiple VMs to containers for density

```bash
#!/bin/bash
# vm-consolidation.sh

# List of VMs to convert declare -A VM_MAP=( [200]=100 [201]=101 [202]=102 [203]=103 )

for VMID in "${!VM_MAP[@]}"; do
    CTID=${VM_MAP[$VMID]}
    echo "Converting VM $VMID to CT $CTID..."

    sudo ./vm-to-lxc.sh -v $VMID -c $CTID -s local-lvm \
        --unprivileged --snapshot --start

    if [ $? -eq 0 ]; then
        echo "✅ VM $VMID → CT $CTID successful"
        # Optional: destroy source VM after verification
        # qm destroy $VMID
    else
        echo "❌ VM $VMID → CT $CTID failed"
    fi
done
```

### Workflow 3: Legacy System Modernization

**Scenario:** Convert legacy VM to modern container with cleanup

```bash
#!/bin/bash
# modernize.sh

VMID=200
CTID=100

# Pre-conversion hook to backup legacy system
cat > /var/lib/vm-to-lxc/hooks/pre-convert << 'EOF'
#!/bin/bash
VMID=$1
echo "Creating legacy backup of VM $VMID..."
vzdump $VMID --dumpdir /backups/legacy/
EOF
chmod +x /var/lib/vm-to-lxc/hooks/pre-convert

# Convert with full cleanup
sudo ./vm-to-lxc.sh -v $VMID -c $CTID -s local-lvm \
    --snapshot --start

# Post-conversion: install modern tools
pct exec $CTID -- apt-get update
pct exec $CTID -- apt-get install -y systemd-timesyncd
```

---

## Migration Scenarios

### Scenario 1: Cross-Node Migration

**Situation:** Container is on node2, need VM on node1

```bash
# On node1
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm \
    --api-host node2.proxmox.local \
    --api-token "root@pam!token=xxxxx" \
    --migrate-to-local \
    --start
```

### Scenario 2: Cloud Export

**Export converted VM to cloud storage:**

```bash
# Convert and export to S3
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm \
    --export-to s3://mybucket/vms/ \
    --export-format qcow2 \
    --start

# Also available: NFS, SSH destinations
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm \
    --export-to nfs://nas.local/export/vms/ \
    --start
```

### Scenario 3: Template Creation

**Create reusable VM template from container:**

```bash
# Convert to high VMID for template
sudo ./lxc-to-vm.sh -c 100 -v 9000 -s local-lvm --template

# Clone template for new VMs
qm clone 9000 201 --name "web-server-01"
qm clone 9000 202 --name "web-server-02"
```

---

## Batch Operations

### Batch File Format

**lxc-to-vm batch file:**

```bash
# /etc/conversions/lxc-batch.txt
# Format: CTID VMID [storage] [disk-size]

# Basic conversions
100 200 local-lvm
101 201 local-lvm
102 202 local-lvm

# With custom disk sizes
103 203 local-lvm 8G
104 204 local-lvm 16G

# With different storage
105 205 fast-storage 10G
```

**vm-to-lxc batch file:**

```bash
# /etc/conversions/vm-batch.txt
# Format: VMID CTID [storage] [disk-size]

200 100 local-lvm
201 101 local-lvm
202 102 local-lvm 8G
```

### Parallel Batch Processing

```bash
# Convert 4 at a time with logging
sudo ./lxc-to-vm.sh \
    --batch /etc/conversions/lxc-batch.txt \
    --parallel 4 \
    2>&1 | tee /var/log/batch-convert.log
```

### Range Conversion

```bash
# Convert CT 100-110 to VM 200-210
sudo ./lxc-to-vm.sh --range 100-110:200-210 -s local-lvm --start

# Convert VM 200-210 to CT 100-110
sudo ./vm-to-lxc.sh --range 200-210:100-110 -s local-lvm --start
```

---

## Troubleshooting Examples

### Fix Boot Issues

**VM won't boot after conversion:**

```bash
# Check boot order
qm config 200 | grep boot

# Fix boot order
qm set 200 --boot order=scsi0

# Check if UEFI needed
qm config 200 | grep bios
# If seabios, try UEFI:
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --uefi --start
```

### Network Fix

**Container has no network:**

```bash
# Check current config
pct config 100 | grep net0

# Fix DHCP
pct set 100 --net0 name=eth0,bridge=vmbr0,ip=dhcp

# Or set static
pct set 100 --net0 name=eth0,bridge=vmbr0,ip=192.168.1.100/24,gw=192.168.1.1

# Restart networking inside container
pct exec 100 -- systemctl restart networking
```

### Disk Space Recovery

**Ran out of space during conversion:**

```bash
# Check space
pvesm status | grep local-lvm

# Find and clean old backups
find /var/lib/vz/dump -name "*.tar.zst" -mtime +7 -delete

# Resume conversion
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm --resume
```

---

## Best Practices

### Pre-Conversion Checklist

- [ ] Verify source exists and is accessible
- [ ] Check available disk space (2x source size recommended)
- [ ] Confirm target ID is available
- [ ] Test with `--dry-run` first
- [ ] Create snapshot if production workload
- [ ] Notify stakeholders of maintenance window

### During Conversion

- [ ] Monitor conversion logs
- [ ] Don't interrupt the process
- [ ] Watch disk space usage
- [ ] Keep original until verification complete

### Post-Conversion Checklist

- [ ] Verify new VM/container starts
- [ ] Test network connectivity
- [ ] Check critical services
- [ ] Update monitoring systems
- [ ] Document the change
- [ ] Archive or destroy original (after delay)

### Automation Best Practices

```bash
# Always use absolute paths in scripts
/usr/local/bin/lxc-to-vm -c 100 -v 200 -s local-lvm

# Log everything
echo "$(date): Starting conversion" >> /var/log/auto-convert.log
sudo ./lxc-to-vm.sh -c 100 -v 200 -s local-lvm >> /var/log/auto-convert.log 2>&1

# Check exit codes
if [ $? -eq 0 ]; then
    echo "Conversion successful"
else
    echo "Conversion failed with code $?"
    # Alert on-call
fi
```

### Security Best Practices

- Use unprivileged containers when possible (`--unprivileged`)
- Set strong root passwords (`--password`)
- Use API tokens with minimal privileges
- Store credentials in secure locations (not in scripts)
- Audit conversions with hooks

---

## Related Documentation

- **[lxc-to-vm.sh](lxc-to-vm)** - Complete LXC to VM guide
- **[vm-to-lxc.sh](vm-to-lxc)** - Complete VM to LXC guide
- **[Hooks](Hooks)** - Automation with hooks
- **[Troubleshooting](Troubleshooting)** - Common issues
