# Hooks System

Complete guide to extending conversions with custom hooks for automation and integration.

---

## Table of Contents

1. [Overview](#overview)
2. [Hook Directories](#hook-directories)
3. [Hook Stages](#hook-stages)
4. [Creating Hooks](#creating-hooks)
5. [Environment Variables](#environment-variables)
6. [Example Hooks](#example-hooks)
7. [Use Cases](#use-cases)

---

## Overview

Hooks allow you to run custom scripts at various stages of the conversion process. This enables:

- Notifications (Slack, email, PagerDuty)
- External backups before/after conversion
- Integration with CMDB or inventory systems
- Custom validations
- Automatic remediation
- Audit logging

---

## Hook Directories

### lxc-to-vm.sh Hooks

```text
/var/lib/lxc-to-vm/hooks/
├── pre-shrink          # Runs before container shrinking
├── pre-convert         # Runs before conversion starts
├── post-convert        # Runs after successful conversion
├── pre-destroy         # Runs before destroying source container
├── health-check-failed # Runs when health checks fail
└── post-shrink         # Runs after successful shrink
```

### vm-to-lxc.sh Hooks

```text
/var/lib/vm-to-lxc/hooks/
├── pre-convert         # Runs before conversion starts
├── post-convert        # Runs after successful conversion
├── pre-destroy         # Runs before destroying source VM
└── health-check-failed # Runs when health checks fail
```

### Custom Hook Directory

Override default location with environment variable:

```bash
export LXC_TO_VM_HOOK_DIR=/custom/hooks/path
export VM_TO_LXC_HOOK_DIR=/custom/hooks/path
```

---

## Hook Stages

### For lxc-to-vm.sh

| Stage | When | Arguments |
| ----- | ---- | ----------- |
| `pre-shrink` | Before shrinking container | `CTID` |
| `post-shrink` | After successful shrink | `CTID` |
| `pre-convert` | Before conversion starts | `CTID` `VMID` |
| `post-convert` | After VM created successfully | `CTID` `VMID` |
| `pre-destroy` | Before destroying container | `CTID` `VMID` |
| `health-check-failed` | When health checks fail | `CTID` `VMID` |

### For vm-to-lxc.sh

| Stage | When | Arguments |
| ----- | ---- | ----------- |
| `pre-convert` | Before conversion starts | `VMID` `CTID` |
| `post-convert` | After CT created successfully | `VMID` `CTID` |
| `pre-destroy` | Before destroying VM | `VMID` `CTID` |
| `health-check-failed` | When health checks fail | `VMID` `CTID` |

---

## Creating Hooks

### Basic Hook Structure

```bash
#!/bin/bash
# Hook receives arguments based on stage
# Exit 0 for success, non-zero to abort (for pre-* hooks)

CTID=$1
VMID=$2

# Your logic here
echo "Hook executed: CTID=$CTID, VMID=$VMID"

exit 0
```

### Installation

```bash
# Create hook file
cat > /var/lib/lxc-to-vm/hooks/pre-convert << 'EOF'
#!/bin/bash
CTID=$1
VMID=$2
logger "Starting conversion of CT $CTID to VM $VMID"
EOF

# Make executable
chmod +x /var/lib/lxc-to-vm/hooks/pre-convert
```

### Aborting Conversion

Pre-* hooks can abort by returning non-zero:

```bash
#!/bin/bash
# pre-convert hook that validates before proceeding
CTID=$1

# Check if container has critical data
if pct exec $CTID -- test -f /var/critical-data 2>/dev/null; then
    echo "ERROR: Critical data found! Aborting."
    exit 1
fi

exit 0
```

---

## Environment Variables

Hooks have access to these environment variables:

| Variable | Description |
| -------- | ----------- |
| `CONVERT_SCRIPT` | Script name (lxc-to-vm or vm-to-lxc) |
| `CONVERT_STAGE` | Current stage name |
| `CTID` | Container ID |
| `VMID` | VM ID |
| `STORAGE` | Target storage name |
| `DISK_SIZE` | Disk size setting |
| `LOG_FILE` | Path to log file |
| `DRY_RUN` | "true" if dry-run mode |

---

## Example Hooks

### Slack Notification

```bash
#!/bin/bash
# /var/lib/lxc-to-vm/hooks/post-convert
CTID=$1
VMID=$2

WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"

MESSAGE="✅ Conversion complete: CT $CTID → VM $VMID"

curl -s -X POST -H 'Content-type: application/json' \
    --data "{\"text\":\"$MESSAGE\"}" \
    $WEBHOOK_URL

exit 0
```

### Backup Before Conversion

```bash
#!/bin/bash
# /var/lib/lxc-to-vm/hooks/pre-convert
CTID=$1

BACKUP_DIR="/backups/pre-convert"
mkdir -p $BACKUP_DIR

# Create backup
vzdump $CTID --dumpdir $BACKUP_DIR --compress zstd

exit 0
```

### CMDB Integration

```bash
#!/bin/bash
# /var/lib/lxc-to-vm/hooks/post-convert
CTID=$1
VMID=$2

# Update CMDB
CMDB_API="https://cmdb.example.com/api/v1/servers"
API_TOKEN="your-api-token"

curl -s -X POST \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
        \"old_id\": \"$CTID\",
        \"new_id\": \"$VMID\",
        \"type\": \"lxc-to-vm\",
        \"timestamp\": \"$(date -Iseconds)\"
    }" \
    $CMDB_API

exit 0
```

### Automatic Remediation

```bash
#!/bin/bash
# /var/lib/lxc-to-vm/hooks/health-check-failed
VMID=$2

logger "Health check failed for VM $VMID, attempting remediation"

# Restart VM
qm stop $VMID
sleep 2
qm start $VMID

# Wait and recheck
sleep 10

# Check if VM is now running
if qm status $VMID | grep -q "running"; then
    logger "VM $VMID recovered after restart"
    exit 0
fi

exit 1
```

---

## Use Cases

### Production Environment

```bash
# Pre-convert: Create backup, notify team
# Post-convert: Update monitoring, send success notification
# Pre-destroy: Final verification, archive logs
```

### Development/Testing

```bash
# Pre-convert: Tag with timestamp
# Post-convert: Run smoke tests
# Health-check-failed: Capture diagnostics, rollback
```

### Compliance/Audit

```bash
# All stages: Log to SIEM
# Pre-destroy: Create compliance snapshot
# Post-convert: Record in audit database
```

---

## Testing Hooks

```bash
# Test hook manually
/var/lib/lxc-to-vm/hooks/pre-convert 100 200

# Check exit code
echo "Exit code: $?"
```

---

## Related Documentation

- **[lxc-to-vm.sh](lxc-to-vm)** - LXC to VM conversion
- **[vm-to-lxc.sh](vm-to-lxc)** - VM to LXC conversion
- **[Examples](Examples)** - More hook examples
