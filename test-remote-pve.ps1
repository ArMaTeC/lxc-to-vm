# Remote PVE Test Script (PowerShell)
# Automatically tests LXC to VM conversion on remote Proxmox host
#
# Usage: .\test-remote-pve.ps1
#

param(
    [string]$PveIp = "192.168.1.29",
    [string]$PveUser = "root",
    [string]$PvePass = "AllWashedout22"
)

# Stop on errors
$ErrorActionPreference = "Stop"

# Configuration
$SshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=NUL", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=10")
$Ct126Id = "126"
$Ct127Id = "127"
$Vm260Id = "260"
$Vm261Id = "261"
$Storage = "local-lvm"

# Script paths
$LocalDir = $PSScriptRoot
$LxcToVmScript = Join-Path $LocalDir "lxc-to-vm.sh"
$ShrinkScript = Join-Path $LocalDir "shrink-lxc.sh"
$RemoteDir = "/root/lxc-to-vm-test"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Remote PVE Test Script (PowerShell)" -ForegroundColor Cyan
Write-Host "Target: ${PveUser}@${PveIp}" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# Check SSH is available
Write-Host "[1/6] Checking OpenSSH installation..." -ForegroundColor Yellow
try {
    $sshPath = (Get-Command ssh -ErrorAction Stop).Source
    $sshVersion = & ssh -V 2>&1
    Write-Host "      SSH found at: $sshPath" -ForegroundColor Green
    Write-Host "      Version: $sshVersion" -ForegroundColor Green
}
catch {
    # Try where.exe as fallback
    $sshWhere = where.exe ssh 2>&1
    if ($sshWhere -and $sshWhere -notmatch "Could not find") {
        Write-Host "      SSH found: $sshWhere" -ForegroundColor Green
    }
    else {
        Write-Host "ERROR: OpenSSH not found in PATH." -ForegroundColor Red
        Write-Host "      SSH should be installed. Try restarting your terminal." -ForegroundColor Yellow
        exit 1
    }
}

# Check SCP is available
$scpPath = where.exe scp 2>&1
if ($scpPath -match "Could not find" -or -not $scpPath) {
    Write-Host "ERROR: SCP not found. Please ensure OpenSSH is installed." -ForegroundColor Red
    exit 1
}
Write-Host "      SCP found: $scpPath" -ForegroundColor Green
Write-Host ""

# Function to run SSH command
function Invoke-SshCommand {
    param([string]$Command)
    $securePass = ConvertTo-SecureString $PvePass -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($PveUser, $securePass)
    
    # Use plink or ssh with password file approach
    $tempPassFile = [System.IO.Path]::GetTempFileName()
    $PvePass | Out-File -FilePath $tempPassFile -NoNewline
    
    try {
        $output = ssh ${SshOpts} "${PveUser}@${PveIp}" $Command 2>&1
        return $output
    }
    finally {
        Remove-Item $tempPassFile -ErrorAction SilentlyContinue
    }
}

# Alternative: Use sshpass if available
function Invoke-SshWithPass {
    param([string]$Command)
    
    # Check for local sshpass.exe in script directory first
    $localSshpass = Join-Path $LocalDir "sshpass.exe"
    $sshpassCmd = $null
    
    if (Test-Path $localSshpass) {
        $sshpassCmd = $localSshpass
    }
    else {
        # Try finding sshpass in PATH
        $pathSshpass = Get-Command sshpass -ErrorAction SilentlyContinue
        if ($pathSshpass) {
            $sshpassCmd = "sshpass"
        }
    }
    
    if ($sshpassCmd) {
        return & $sshpassCmd -p $PvePass ssh @SshOpts "${PveUser}@${PveIp}" $Command 2>&1
    }
    
    # Fallback: manual password entry or key-based auth
    Write-Host "      Note: sshpass not found. SSH commands may prompt for password." -ForegroundColor Yellow
    return ssh @SshOpts "${PveUser}@${PveIp}" $Command 2>&1
}

# Test connection
Write-Host "[2/6] Testing connection to PVE host..." -ForegroundColor Yellow
try {
    $test = Invoke-SshWithPass "echo 'Connection OK'"
    if ($test -match "Connection OK") {
        Write-Host "      Connected successfully!" -ForegroundColor Green
    }
    else {
        throw "Connection test failed"
    }
}
catch {
    Write-Host "ERROR: Cannot connect to ${PveIp}. Error: $_" -ForegroundColor Red
    Write-Host "      Please verify:" -ForegroundColor Yellow
    Write-Host "      - Network connectivity to ${PveIp}" -ForegroundColor Yellow
    Write-Host "      - SSH is enabled on the PVE host" -ForegroundColor Yellow
    Write-Host "      - Username and password are correct" -ForegroundColor Yellow
    exit 1
}
Write-Host ""

# Clean up VMs
Write-Host "[3/6] Cleaning up existing VMs ${Vm260Id} and ${Vm261Id}..." -ForegroundColor Yellow
try {
    $cleanupScript = @"
for vmid in ${Vm260Id} ${Vm261Id}; do
    if qm status \$vmid >/dev/null 2>&1; then
        echo "Stopping VM \$vmid..."
        qm stop \$vmid >/dev/null 2>&1 || true
        sleep 2
        echo "Destroying VM \$vmid..."
        qm destroy \$vmid --destroy-unreferenced-disks 1 --purge 1 >/dev/null 2>&1 || true
    else
        echo "VM \$vmid does not exist, skipping..."
    fi
done
echo "Cleanup complete"
"@
    Invoke-SshWithPass $cleanupScript | ForEach-Object { Write-Host "      $_" }
}
catch {
    Write-Host "      Warning: Cleanup encountered issues: $_" -ForegroundColor Yellow
}
Write-Host ""

# Create remote directory
Write-Host "[4/6] Creating remote directory and copying scripts..." -ForegroundColor Yellow
try {
    Invoke-SshWithPass "mkdir -p ${RemoteDir}" | Out-Null
    
    Write-Host "      Copying lxc-to-vm.sh..." -ForegroundColor Gray
    $scpPassFile = [System.IO.Path]::GetTempFileName()
    $PvePass | Out-File -FilePath $scpPassFile -NoNewline
    
    try {
        # Check for local sshpass.exe
        $localSshpass = Join-Path $LocalDir "sshpass.exe"
        $sshpassCmd = $null
        if (Test-Path $localSshpass) {
            $sshpassCmd = $localSshpass
        }
        else {
            $pathSshpass = Get-Command sshpass -ErrorAction SilentlyContinue
            if ($pathSshpass) {
                $sshpassCmd = "sshpass"
            }
        }
        
        if ($sshpassCmd) {
            & $sshpassCmd -p $PvePass scp @SshOpts "${LxcToVmScript}" "${PveUser}@${PveIp}:${RemoteDir}/" 2>&1 | Out-Null
            & $sshpassCmd -p $PvePass scp @SshOpts "${ShrinkScript}" "${PveUser}@${PveIp}:${RemoteDir}/" 2>&1 | Out-Null
        }
        else {
            # Fallback to manual SCP (may prompt for password)
            scp @SshOpts "${LxcToVmScript}" "${PveUser}@${PveIp}:${RemoteDir}/" 2>&1 | Out-Null
            scp @SshOpts "${ShrinkScript}" "${PveUser}@${PveIp}:${RemoteDir}/" 2>&1 | Out-Null
        }
    }
    finally {
        Remove-Item $scpPassFile -ErrorAction SilentlyContinue
    }
    
    Invoke-SshWithPass "chmod +x ${RemoteDir}/*.sh" | Out-Null
    Write-Host "      Scripts copied and made executable" -ForegroundColor Green
}
catch {
    Write-Host "ERROR: Failed to copy scripts: $_" -ForegroundColor Red
    exit 1
}
Write-Host ""

# Run conversions
Write-Host "[5/6] Running conversions..." -ForegroundColor Yellow
Write-Host ""

# Conversion 126 -> 260
Write-Host "      Converting CT ${Ct126Id} -> VM ${Vm260Id}..." -ForegroundColor Cyan
Write-Host "      This may take several minutes..." -ForegroundColor Gray
try {
    $log126 = "/tmp/lxc-to-vm-126.log"
    Invoke-SshWithPass "cd ${RemoteDir} && ./lxc-to-vm.sh -c ${Ct126Id} -v ${Vm260Id} -s ${Storage} --shrink --start" 2>&1 | 
    Tee-Object -FilePath $log126 | 
    ForEach-Object { Write-Host "      [126->260] $_" -ForegroundColor Gray }
    Write-Host "      Conversion 126->260 completed" -ForegroundColor Green
}
catch {
    Write-Host "      ERROR: Conversion of CT ${Ct126Id} failed!" -ForegroundColor Red
    Write-Host "      Log saved to: $log126" -ForegroundColor Yellow
}
Write-Host ""

# Conversion 127 -> 261
Write-Host "      Converting CT ${Ct127Id} -> VM ${Vm261Id}..." -ForegroundColor Cyan
Write-Host "      This may take several minutes..." -ForegroundColor Gray
try {
    $log127 = "/tmp/lxc-to-vm-127.log"
    Invoke-SshWithPass "cd ${RemoteDir} && ./lxc-to-vm.sh -c ${Ct127Id} -v ${Vm261Id} -s ${Storage} --shrink --start" 2>&1 | 
    Tee-Object -FilePath $log127 | 
    ForEach-Object { Write-Host "      [127->261] $_" -ForegroundColor Gray }
    Write-Host "      Conversion 127->261 completed" -ForegroundColor Green
}
catch {
    Write-Host "      ERROR: Conversion of CT ${Ct127Id} failed!" -ForegroundColor Red
    Write-Host "      Log saved to: $log127" -ForegroundColor Yellow
}
Write-Host ""

# Check VM status
Write-Host "[6/6] Checking VM status..." -ForegroundColor Yellow
try {
    $statusScript = @"
echo "=========================================="
echo "VM Status Check"
echo "=========================================="
for vmid in ${Vm260Id} ${Vm261Id}; do
    echo ""
    echo "--- VM \$vmid ---"
    if qm status \$vmid >/dev/null 2>&1; then
        qm status \$vmid
        echo "Guest Agent:"
        qm agent \$vmid ping 2>/dev/null && echo "  Responsive" || echo "  Not responding"
    else
        echo "VM \$vmid does not exist!"
    fi
done
echo ""
echo "=========================================="
"@
    Invoke-SshWithPass $statusScript | ForEach-Object { Write-Host "      $_" }
}
catch {
    Write-Host "      Warning: Status check failed: $_" -ForegroundColor Yellow
}
Write-Host ""

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Test Complete!" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Logs saved to:" -ForegroundColor White
Write-Host "  - /tmp/lxc-to-vm-126.log" -ForegroundColor Gray
Write-Host "  - /tmp/lxc-to-vm-127.log" -ForegroundColor Gray
Write-Host ""
Write-Host "Check VM consoles with:" -ForegroundColor White
Write-Host "  ssh ${PveUser}@${PveIp} qm terminal ${Vm260Id} -iface serial0" -ForegroundColor Yellow
Write-Host "  ssh ${PveUser}@${PveIp} qm terminal ${Vm261Id} -iface serial0" -ForegroundColor Yellow
