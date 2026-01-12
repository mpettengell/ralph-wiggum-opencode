# Security Hardening Guide for Ralph

## Overview

This guide provides comprehensive safeguards for running Ralph in a development environment with k3s and Docker Compose, ensuring damage is contained to a single VM.

---

## Architecture: Defense in Depth

```
┌─────────────────────────────────────────────────────────────┐
│ Layer 1: VM Isolation                                       │
│  • Dedicated VM, no shared resources                        │
│  • Snapshots before each run                                │
└─────────────────────────────────────────────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────────────────────┐
│ Layer 2: Network Isolation                                  │
│  • Separate VLAN/subnet                                     │
│  • Firewall rules                                           │
│  • No access to production networks                         │
└─────────────────────────────────────────────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────────────────────┐
│ Layer 3: User/Permission Isolation                          │
│  • Non-root user with limited sudo                          │
│  • cgroups resource limits                                  │
│  • Docker rootless mode                                     │
└─────────────────────────────────────────────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────────────────────┐
│ Layer 4: Filesystem Protection                              │
│  • Separate partition for Ralph workspace                   │
│  • Quota limits                                             │
│  • No access to sensitive directories                       │
└─────────────────────────────────────────────────────────────┘
           │
           ▼
┌─────────────────────────────────────────────────────────────┐
│ Layer 5: Monitoring & Alerting                              │
│  • Audit logging                                            │
│  • Resource monitoring                                      │
│  • Automatic kill switches                                  │
└─────────────────────────────────────────────────────────────┘
```

---

## Layer 1: VM Isolation

### 1.1 Dedicated VM Setup

**Recommended VM Specs:**
```yaml
CPU: 4-8 cores
RAM: 8-16 GB
Disk: 100-200 GB (separate partition for workspaces)
OS: Ubuntu 22.04 LTS or similar
```

**Create VM with automation-friendly snapshot system:**

```bash
# Example: Proxmox VM creation
qm create 9001 \
  --name ralph-dev \
  --memory 8192 \
  --cores 4 \
  --net0 virtio,bridge=vmbr1 \
  --scsi0 local-lvm:100

# Enable snapshot support
qm set 9001 --snapshot
```

### 1.2 Automatic Snapshot Management

Create a wrapper script that snapshots before each Ralph run:

```bash
#!/bin/bash
# /usr/local/bin/ralph-safe

set -euo pipefail

SNAPSHOT_NAME="ralph-pre-run-$(date +%Y%m%d-%H%M%S)"
VM_ID="9001"  # Your VM ID

echo "Creating snapshot: $SNAPSHOT_NAME"
# Adjust for your hypervisor (Proxmox example)
ssh hypervisor "qm snapshot $VM_ID $SNAPSHOT_NAME"

# Run Ralph with timeout
timeout 24h /opt/ralph/.opencode/ralph-scripts/ralph-loop.sh "$@"
EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
  echo "Ralph exited with error. Snapshot available: $SNAPSHOT_NAME"
  echo "To restore: ssh hypervisor 'qm rollback $VM_ID $SNAPSHOT_NAME'"
fi

exit $EXIT_CODE
```

### 1.3 Automatic Cleanup

```bash
#!/bin/bash
# /usr/local/bin/ralph-cleanup-snapshots

# Keep only last 5 snapshots
ssh hypervisor "qm listsnapshot $VM_ID" | \
  grep ralph-pre-run | \
  sort -r | \
  tail -n +6 | \
  while read snap; do
    echo "Removing old snapshot: $snap"
    ssh hypervisor "qm delsnapshot $VM_ID $snap"
  done
```

---

## Layer 2: Network Isolation

### 2.1 Network Architecture

```
Internet
   │
   ▼
[Firewall]
   │
   ├─────────► Production Network (10.0.1.0/24) ❌ No access
   │
   └─────────► Ralph Dev VLAN (10.0.99.0/24) ✅
                  │
                  ▼
              [Ralph VM]
                  │
                  ├─► Outbound: Allow specific hosts only
                  └─► Inbound: SSH from admin subnet only
```

### 2.2 Firewall Rules (iptables)

```bash
#!/bin/bash
# /etc/ralph/firewall-setup.sh

set -euo pipefail

# Flush existing rules
iptables -F
iptables -X
iptables -Z

# Default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow SSH from admin subnet only
iptables -A INPUT -p tcp --dport 22 -s 10.0.1.0/24 -j ACCEPT

# Allow outbound to specific services only
ALLOWED_HOSTS=(
  "api.opencode.ai"
  "github.com"
  "registry-1.docker.io"
  "archive.ubuntu.com"
  "security.ubuntu.com"
)

for host in "${ALLOWED_HOSTS[@]}"; do
  # Resolve IP and allow
  IPS=$(dig +short "$host" | grep -E '^[0-9]+\.')
  for ip in $IPS; do
    iptables -A OUTPUT -d "$ip" -j ACCEPT
  done
done

# Allow DNS
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# Allow HTTPS/HTTP for package downloads
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 80 -j ACCEPT

# Block all production networks
iptables -A OUTPUT -d 10.0.1.0/24 -j DROP
iptables -A OUTPUT -d 192.168.1.0/24 -j DROP  # Add your prod networks

# Log dropped packets
iptables -A INPUT -j LOG --log-prefix "RALPH-FW-DROP-IN: " --log-level 4
iptables -A OUTPUT -j LOG --log-prefix "RALPH-FW-DROP-OUT: " --log-level 4

# Save rules
iptables-save > /etc/iptables/rules.v4

echo "Firewall rules applied"
```

### 2.3 Network Namespace Isolation (Optional, Advanced)

Run Ralph in its own network namespace:

```bash
#!/bin/bash
# /usr/local/bin/ralph-netns

# Create isolated network namespace
ip netns add ralph-ns

# Create veth pair
ip link add veth-ralph type veth peer name veth-host
ip link set veth-ralph netns ralph-ns

# Configure addresses
ip addr add 10.99.1.1/24 dev veth-host
ip link set veth-host up
ip netns exec ralph-ns ip addr add 10.99.1.2/24 dev veth-ralph
ip netns exec ralph-ns ip link set veth-ralph up
ip netns exec ralph-ns ip link set lo up
ip netns exec ralph-ns ip route add default via 10.99.1.1

# Enable NAT
iptables -t nat -A POSTROUTING -s 10.99.1.0/24 -j MASQUERADE
echo 1 > /proc/sys/net/ipv4/ip_forward

# Run Ralph in namespace
ip netns exec ralph-ns sudo -u ralph /opt/ralph/.opencode/ralph-scripts/ralph-loop.sh
```

---

## Layer 3: User & Permission Isolation

### 3.1 Create Dedicated User

```bash
#!/bin/bash
# /usr/local/bin/setup-ralph-user

set -euo pipefail

# Create ralph user with no login shell initially
useradd -m -d /home/ralph -s /bin/bash ralph

# Create workspace directory on separate partition
mkdir -p /ralph-workspaces
chown ralph:ralph /ralph-workspaces
chmod 0750 /ralph-workspaces

# Limit user to specific directories only
mkdir -p /etc/systemd/system/user@$(id -u ralph).service.d
cat > /etc/systemd/system/user@$(id -u ralph).service.d/override.conf <<'EOF'
[Service]
# Restrict filesystem access
ReadOnlyPaths=/
ReadWritePaths=/home/ralph
ReadWritePaths=/ralph-workspaces
ReadWritePaths=/tmp
ReadWritePaths=/var/tmp
InaccessiblePaths=/root
InaccessiblePaths=/etc/shadow
InaccessiblePaths=/etc/sudoers
EOF

systemctl daemon-reload
```

### 3.2 Limited sudo Configuration

```bash
# /etc/sudoers.d/ralph
# Allow ralph user to run only specific commands

Defaults:ralph !authenticate
ralph ALL=(ALL) NOPASSWD: /usr/local/bin/docker-compose
ralph ALL=(ALL) NOPASSWD: /usr/local/bin/kubectl
ralph ALL=(ALL) NOPASSWD: /usr/local/bin/k3s
ralph ALL=(ALL) NOPASSWD: /bin/systemctl start k3s
ralph ALL=(ALL) NOPASSWD: /bin/systemctl stop k3s
ralph ALL=(ALL) NOPASSWD: /bin/systemctl restart k3s
ralph ALL=(ALL) NOPASSWD: /bin/systemctl status k3s

# Explicitly deny dangerous commands
Cmnd_Alias DANGEROUS = /bin/rm -rf /, /sbin/reboot, /sbin/shutdown, /sbin/poweroff, /usr/sbin/userdel, /usr/sbin/usermod
ralph ALL=(ALL) !DANGEROUS
```

### 3.3 Docker Rootless Mode

```bash
#!/bin/bash
# Setup Docker in rootless mode

# Install rootless Docker
curl -fsSL https://get.docker.com/rootless | sh

# Add to ralph user's profile
su - ralph <<'EOF'
echo 'export PATH=/home/ralph/bin:$PATH' >> ~/.bashrc
echo 'export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock' >> ~/.bashrc
source ~/.bashrc

# Configure rootless docker
systemctl --user enable docker
systemctl --user start docker
EOF

# Verify
su - ralph -c "docker run hello-world"
```

### 3.4 cgroups Resource Limits

```bash
# /etc/systemd/system/ralph-limiter.slice

[Unit]
Description=Resource limits for Ralph user
Before=slices.target

[Slice]
# Limit CPU to 80%
CPUQuota=80%

# Limit RAM to 12GB
MemoryMax=12G
MemoryHigh=10G

# Limit I/O
IOWeight=500

# Limit tasks
TasksMax=500
```

Apply to user:

```bash
# /etc/systemd/system/user-$(id -u ralph).slice.d/override.conf
[Slice]
Slice=ralph-limiter.slice
```

---

## Layer 4: Filesystem Protection

### 4.1 Dedicated Partition Setup

```bash
#!/bin/bash
# Create dedicated partition for Ralph workspaces

# Create and mount partition (adjust device as needed)
mkfs.ext4 -L RALPH_WORKSPACE /dev/vdb1
echo 'LABEL=RALPH_WORKSPACE /ralph-workspaces ext4 defaults,nodev,nosuid,noexec 0 2' >> /etc/fstab
mount /ralph-workspaces

# Set quota
apt-get install -y quota
quotacheck -cum /ralph-workspaces
quotaon -v /ralph-workspaces

# Set user quota: 80GB soft, 100GB hard
setquota -u ralph 83886080 104857600 0 0 /ralph-workspaces
```

### 4.2 Workspace Path Validation

Create a patched version of ralph-loop.sh:

```bash
# /opt/ralph/patches/workspace-validation.sh

validate_workspace() {
  local path="$1"

  # Resolve to absolute path
  if ! path="$(cd "$path" && pwd)" 2>/dev/null; then
    echo "❌ Error: Invalid workspace path: $1" >&2
    return 1
  fi

  # CRITICAL: Must be under /ralph-workspaces
  if [[ ! "$path" =~ ^/ralph-workspaces/ ]]; then
    echo "❌ Error: Workspace must be under /ralph-workspaces/" >&2
    echo "   Got: $path" >&2
    return 1
  fi

  # Must not contain suspicious patterns
  if [[ "$path" =~ \.\. ]] || [[ "$path" =~ /\./ ]]; then
    echo "❌ Error: Workspace path contains suspicious patterns" >&2
    return 1
  fi

  # Prevent access to system directories (defense in depth)
  local forbidden_dirs=(
    "/"
    "/bin"
    "/boot"
    "/dev"
    "/etc"
    "/lib"
    "/lib64"
    "/proc"
    "/root"
    "/sbin"
    "/sys"
    "/usr"
    "/var/lib"
  )

  for forbidden in "${forbidden_dirs[@]}"; do
    if [[ "$path" == "$forbidden" ]] || [[ "$path" =~ ^${forbidden}/ ]]; then
      echo "❌ Error: Cannot use system directory: $path" >&2
      return 1
    fi
  done

  # Must be a git repo or we create one
  if ! git -C "$path" rev-parse --git-dir > /dev/null 2>&1; then
    echo "⚠️  Warning: Not a git repository. Initializing..." >&2
    git -C "$path" init
  fi

  echo "✅ Workspace validated: $path" >&2
  echo "$path"
}
```

### 4.3 Protected Directories with AppArmor

```bash
# /etc/apparmor.d/ralph-protection

#include <tunables/global>

profile ralph-protection /home/ralph/bin/opencode {
  #include <abstractions/base>

  # Allow Ralph workspace
  /ralph-workspaces/** rw,

  # Allow home directory
  /home/ralph/** rw,

  # Allow reading system files
  /etc/passwd r,
  /etc/group r,

  # Allow temp
  /tmp/** rw,
  /var/tmp/** rw,

  # Allow Docker socket
  /run/user/*/docker.sock rw,

  # Deny everything else
  deny /root/** rwx,
  deny /etc/shadow rwx,
  deny /etc/sudoers rwx,
  deny /boot/** rwx,
  deny /sys/** w,
}
```

Activate:

```bash
apparmor_parser -r /etc/apparmor.d/ralph-protection
aa-enforce ralph-protection
```

---

## Layer 5: Monitoring & Alerting

### 5.1 Audit Logging

```bash
# /etc/audit/rules.d/ralph.rules

# Monitor file access
-w /ralph-workspaces/ -p wa -k ralph-workspace
-w /etc/sudoers -p wa -k sudoers-changes
-w /etc/passwd -p wa -k passwd-changes

# Monitor ralph user actions
-a always,exit -F arch=b64 -F auid=$(id -u ralph) -S execve -k ralph-exec
-a always,exit -F arch=b64 -F auid=$(id -u ralph) -S connect -k ralph-network

# Monitor privilege escalation
-a always,exit -F arch=b64 -S setuid -S setgid -F uid=$(id -u ralph) -k ralph-privesc
```

Reload:

```bash
augenrules --load
systemctl restart auditd
```

### 5.2 Resource Monitoring Script

```bash
#!/bin/bash
# /usr/local/bin/ralph-monitor

set -euo pipefail

LOGFILE="/var/log/ralph-monitor.log"
ALERT_EMAIL="admin@example.com"
RALPH_UID=$(id -u ralph)

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

alert() {
  local subject="$1"
  local message="$2"
  log "ALERT: $subject - $message"
  echo "$message" | mail -s "[RALPH ALERT] $subject" "$ALERT_EMAIL"
}

check_cpu() {
  local cpu_usage=$(ps -u ralph -o %cpu --no-headers | awk '{sum+=$1} END {print sum}')
  if (( $(echo "$cpu_usage > 90" | bc -l) )); then
    alert "High CPU Usage" "Ralph using ${cpu_usage}% CPU"
  fi
}

check_memory() {
  local mem_kb=$(ps -u ralph -o rss --no-headers | awk '{sum+=$1} END {print sum}')
  local mem_gb=$(echo "scale=2; $mem_kb / 1024 / 1024" | bc)
  if (( $(echo "$mem_gb > 10" | bc -l) )); then
    alert "High Memory Usage" "Ralph using ${mem_gb}GB RAM"
  fi
}

check_disk() {
  local usage=$(df /ralph-workspaces | tail -1 | awk '{print $5}' | sed 's/%//')
  if [[ $usage -gt 85 ]]; then
    alert "High Disk Usage" "Ralph workspace ${usage}% full"
  fi
}

check_suspicious_processes() {
  # Check for mining processes
  if ps -u ralph -o cmd --no-headers | grep -iE '(xmrig|ethminer|minerd|cgminer)'; then
    alert "Suspicious Process Detected" "Possible cryptocurrency miner running"
    pkill -u ralph
  fi

  # Check for reverse shells
  if netstat -tnp | grep "ESTABLISHED.*$(id -u ralph)" | grep -vE '(443|80|22)'; then
    alert "Suspicious Network Connection" "Ralph has unexpected outbound connection"
  fi
}

check_file_modifications() {
  # Check for modifications outside workspace
  local suspect_files=$(find /etc /usr /bin /sbin -user ralph -mtime -1 2>/dev/null)
  if [[ -n "$suspect_files" ]]; then
    alert "Unauthorized File Modifications" "Ralph modified system files:\n$suspect_files"
  fi
}

# Main monitoring loop
main() {
  log "Ralph monitoring started"

  while true; do
    check_cpu
    check_memory
    check_disk
    check_suspicious_processes
    check_file_modifications

    # Check every 60 seconds
    sleep 60
  done
}

main
```

Run as systemd service:

```ini
# /etc/systemd/system/ralph-monitor.service

[Unit]
Description=Ralph Security Monitor
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ralph-monitor
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

### 5.3 Kill Switch

```bash
#!/bin/bash
# /usr/local/bin/ralph-killswitch

set -euo pipefail

REASON="${1:-Manual trigger}"

echo "🚨 RALPH KILLSWITCH ACTIVATED: $REASON"
echo "Timestamp: $(date)"

# Stop all Ralph processes
echo "Stopping Ralph processes..."
pkill -u ralph -9

# Stop Docker containers
echo "Stopping Docker containers..."
su - ralph -c "docker stop \$(docker ps -q)" 2>/dev/null || true

# Stop k3s
echo "Stopping k3s..."
systemctl stop k3s 2>/dev/null || true

# Create incident report
INCIDENT_FILE="/var/log/ralph-incidents/$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$(dirname "$INCIDENT_FILE")"

cat > "$INCIDENT_FILE" <<EOF
RALPH KILLSWITCH ACTIVATION REPORT
===================================
Timestamp: $(date)
Reason: $REASON

Process List:
$(ps aux | grep ralph)

Network Connections:
$(netstat -tnp | grep ralph)

Recent Audit Logs:
$(ausearch -ua ralph -ts recent 2>/dev/null | tail -50)

Disk Usage:
$(df -h /ralph-workspaces)

Recent File Modifications:
$(find /ralph-workspaces -mtime -1 -ls)
EOF

echo "Incident report saved to: $INCIDENT_FILE"

# Send alert
echo "Sending alert..."
mail -s "[RALPH KILLSWITCH] Activated: $REASON" admin@example.com < "$INCIDENT_FILE"

echo "✅ Killswitch complete"
```

Auto-trigger on suspicious activity:

```bash
# Add to ralph-monitor script:
check_anomalies() {
  # Check for fork bombs
  local process_count=$(ps -u ralph --no-headers | wc -l)
  if [[ $process_count -gt 200 ]]; then
    /usr/local/bin/ralph-killswitch "Fork bomb detected ($process_count processes)"
    exit 1
  fi

  # Check for rapid file creation (potential ransomware)
  local new_files=$(find /ralph-workspaces -mmin -1 -type f | wc -l)
  if [[ $new_files -gt 1000 ]]; then
    /usr/local/bin/ralph-killswitch "Mass file creation detected ($new_files files)"
    exit 1
  fi
}
```

---

## Layer 6: Hardened Ralph Wrapper

Create a production-ready wrapper that combines all protections:

```bash
#!/bin/bash
# /usr/local/bin/ralph-hardened

set -euo pipefail

RALPH_USER="ralph"
WORKSPACE_BASE="/ralph-workspaces"
MAX_RUNTIME="24h"
SNAPSHOT_ENABLED="${SNAPSHOT_ENABLED:-true}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS] <project-name>

Options:
  -t, --timeout <duration>    Max runtime (default: 24h)
  -n, --no-snapshot           Disable automatic snapshots
  -h, --help                  Show this help

Example:
  $0 my-microservice
EOF
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--timeout)
      MAX_RUNTIME="$2"
      shift 2
      ;;
    -n|--no-snapshot)
      SNAPSHOT_ENABLED="false"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      PROJECT_NAME="$1"
      shift
      ;;
  esac
done

if [[ -z "${PROJECT_NAME:-}" ]]; then
  echo "Error: Project name required"
  usage
fi

WORKSPACE="$WORKSPACE_BASE/$PROJECT_NAME"

# Validate workspace
if [[ ! "$WORKSPACE" =~ ^/ralph-workspaces/ ]]; then
  echo "❌ Security violation: Invalid workspace path"
  exit 1
fi

# Create workspace if doesn't exist
if [[ ! -d "$WORKSPACE" ]]; then
  echo "Creating workspace: $WORKSPACE"
  mkdir -p "$WORKSPACE"
  chown ralph:ralph "$WORKSPACE"
  chmod 0750 "$WORKSPACE"
fi

# Pre-flight checks
echo "🔍 Pre-flight security checks..."

# Check firewall
if ! iptables -L -n | grep -q "RALPH-FW-DROP"; then
  echo "⚠️  Warning: Firewall rules not active"
  read -p "Continue anyway? [y/N] " -n 1 -r
  echo
  [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# Check quotas
if ! quota -u ralph >/dev/null 2>&1; then
  echo "⚠️  Warning: Disk quotas not enabled"
fi

# Check monitoring
if ! systemctl is-active --quiet ralph-monitor; then
  echo "⚠️  Warning: Ralph monitor not running"
  echo "   Start with: systemctl start ralph-monitor"
fi

# Create snapshot if enabled
if [[ "$SNAPSHOT_ENABLED" == "true" ]]; then
  SNAPSHOT_NAME="ralph-$(date +%Y%m%d-%H%M%S)-$PROJECT_NAME"
  echo "📸 Creating VM snapshot: $SNAPSHOT_NAME"

  # This assumes you have a snapshot script configured
  if command -v create-vm-snapshot >/dev/null 2>&1; then
    create-vm-snapshot "$SNAPSHOT_NAME"
    echo "✅ Snapshot created"
    trap "echo '💡 Restore snapshot: restore-vm-snapshot $SNAPSHOT_NAME'" EXIT
  else
    echo "⚠️  Snapshot command not found, skipping"
  fi
fi

# Log start
echo "[$(date)] Starting Ralph for project: $PROJECT_NAME" >> /var/log/ralph-sessions.log

# Run Ralph with timeout and resource limits
echo "🚀 Starting Ralph (timeout: $MAX_RUNTIME)..."
echo "   Workspace: $WORKSPACE"
echo "   Monitor: tail -f $WORKSPACE/.ralph/activity.log"
echo ""

# Set trap for cleanup
cleanup() {
  local exit_code=$?
  echo ""
  echo "🛑 Ralph stopped (exit code: $exit_code)"

  if [[ $exit_code -ne 0 ]]; then
    echo "❌ Ralph exited with error"
    echo "   Review logs: $WORKSPACE/.ralph/errors.log"
    echo "   Incident report: /var/log/ralph-incidents/"
  else
    echo "✅ Ralph completed successfully"
  fi

  # Log end
  echo "[$(date)] Stopped Ralph for project: $PROJECT_NAME (exit: $exit_code)" >> /var/log/ralph-sessions.log
}
trap cleanup EXIT INT TERM

# Run as ralph user with systemd-run for proper cgroup isolation
systemd-run \
  --uid="$RALPH_USER" \
  --gid="$RALPH_USER" \
  --slice=ralph-limiter.slice \
  --working-directory="$WORKSPACE" \
  --setenv=RALPH_TASK_FILE="$WORKSPACE/RALPH_TASK.md" \
  --setenv=HOME="/home/ralph" \
  --property=MemoryMax=12G \
  --property=CPUQuota=80% \
  --property=TasksMax=500 \
  --pty \
  timeout "$MAX_RUNTIME" \
  /opt/ralph/.opencode/ralph-scripts/ralph-loop.sh "$WORKSPACE"
```

Make executable:

```bash
chmod +x /usr/local/bin/ralph-hardened
```

---

## Complete Setup Script

Run this on your VM to apply all hardening:

```bash
#!/bin/bash
# /root/setup-ralph-security.sh

set -euo pipefail

echo "🔒 Ralph Security Hardening Setup"
echo "=================================="
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Install dependencies
echo "📦 Installing dependencies..."
apt-get update
apt-get install -y \
  iptables-persistent \
  quota \
  quotatool \
  auditd \
  apparmor-utils \
  mailutils \
  bc \
  jq \
  git \
  docker.io \
  curl

# Create ralph user
echo "👤 Creating ralph user..."
if ! id ralph >/dev/null 2>&1; then
  useradd -m -d /home/ralph -s /bin/bash ralph
fi

# Setup workspace partition
echo "💾 Setting up workspace directory..."
mkdir -p /ralph-workspaces
chown ralph:ralph /ralph-workspaces
chmod 0750 /ralph-workspaces

# Setup quota (if on separate partition)
if mountpoint -q /ralph-workspaces; then
  quotacheck -cum /ralph-workspaces || true
  quotaon -v /ralph-workspaces || true
  setquota -u ralph 83886080 104857600 0 0 /ralph-workspaces
  echo "✅ Quota enabled: 80GB soft, 100GB hard"
fi

# Setup firewall
echo "🔥 Configuring firewall..."
# (Copy the firewall script from above)
# /etc/ralph/firewall-setup.sh

# Setup sudoers
echo "🔐 Configuring sudoers..."
cat > /etc/sudoers.d/ralph <<'EOF'
Defaults:ralph !authenticate
ralph ALL=(ALL) NOPASSWD: /usr/bin/docker-compose
ralph ALL=(ALL) NOPASSWD: /usr/bin/kubectl
ralph ALL=(ALL) NOPASSWD: /usr/local/bin/k3s
ralph ALL=(ALL) NOPASSWD: /bin/systemctl start k3s
ralph ALL=(ALL) NOPASSWD: /bin/systemctl stop k3s
ralph ALL=(ALL) NOPASSWD: /bin/systemctl restart k3s
ralph ALL=(ALL) NOPASSWD: /bin/systemctl status k3s
Cmnd_Alias DANGEROUS = /bin/rm -rf /, /sbin/reboot, /sbin/shutdown
ralph ALL=(ALL) !DANGEROUS
EOF
chmod 0440 /etc/sudoers.d/ralph

# Setup cgroups
echo "📊 Configuring resource limits..."
mkdir -p /etc/systemd/system/ralph-limiter.slice.d
cat > /etc/systemd/system/ralph-limiter.slice <<'EOF'
[Unit]
Description=Resource limits for Ralph
Before=slices.target

[Slice]
CPUQuota=80%
MemoryMax=12G
MemoryHigh=10G
TasksMax=500
EOF

mkdir -p /etc/systemd/system/user-$(id -u ralph).slice.d
cat > /etc/systemd/system/user-$(id -u ralph).slice.d/override.conf <<'EOF'
[Slice]
Slice=ralph-limiter.slice
EOF

systemctl daemon-reload

# Setup audit rules
echo "📝 Configuring audit logging..."
cat > /etc/audit/rules.d/ralph.rules <<EOF
-w /ralph-workspaces/ -p wa -k ralph-workspace
-w /etc/sudoers -p wa -k sudoers-changes
-a always,exit -F arch=b64 -F auid=$(id -u ralph) -S execve -k ralph-exec
EOF
augenrules --load || true

# Setup monitoring service
echo "👁️  Installing monitoring service..."
# (Copy ralph-monitor script and service file from above)
# systemctl enable ralph-monitor
# systemctl start ralph-monitor

# Setup Docker rootless (optional)
echo "🐳 Configuring Docker rootless..."
# (Copy Docker rootless setup from above)

# Install Ralph
echo "🐛 Installing Ralph..."
su - ralph -c "curl -fsSL https://raw.githubusercontent.com/agrimsingh/ralph-wiggum-opencode/main/install.sh | bash"

# Copy hardened wrapper
# (Copy ralph-hardened script to /usr/local/bin/)

echo ""
echo "✅ Ralph security hardening complete!"
echo ""
echo "Next steps:"
echo "  1. Review firewall rules: iptables -L -n"
echo "  2. Test Ralph: sudo -u ralph /usr/local/bin/ralph-hardened test-project"
echo "  3. Monitor: tail -f /var/log/ralph-monitor.log"
echo "  4. Create VM snapshot for baseline recovery"
echo ""
```

---

## Quick Reference Commands

```bash
# Start Ralph (hardened)
ralph-hardened my-project

# Monitor in real-time
tail -f /ralph-workspaces/my-project/.ralph/activity.log

# Check resource usage
systemd-cgtop

# View audit logs
ausearch -ua ralph -ts recent

# Emergency stop
ralph-killswitch "Manual intervention"

# Restore from snapshot
restore-vm-snapshot ralph-20240112-143022

# Check quota
quota -u ralph

# View firewall logs
grep RALPH-FW-DROP /var/log/syslog
```

---

## Testing the Security

Create a test suite to verify all protections:

```bash
#!/bin/bash
# /usr/local/bin/test-ralph-security

echo "🧪 Ralph Security Test Suite"
echo "============================="

# Test 1: Workspace isolation
echo "Test 1: Workspace path validation"
if sudo -u ralph /opt/ralph/.opencode/ralph-scripts/ralph-loop.sh /etc 2>&1 | grep -q "Error"; then
  echo "✅ PASS: System directory access blocked"
else
  echo "❌ FAIL: System directory accessible"
fi

# Test 2: Resource limits
echo "Test 2: Memory limits"
if systemctl show user-$(id -u ralph).slice | grep -q "MemoryMax=12"; then
  echo "✅ PASS: Memory limit configured"
else
  echo "❌ FAIL: No memory limit"
fi

# Test 3: Firewall
echo "Test 3: Firewall rules"
if iptables -L OUTPUT | grep -q "DROP.*10.0.1.0"; then
  echo "✅ PASS: Production network blocked"
else
  echo "❌ FAIL: Production network accessible"
fi

# Test 4: Sudo restrictions
echo "Test 4: Sudo restrictions"
if sudo -u ralph sudo reboot 2>&1 | grep -q "not allowed"; then
  echo "✅ PASS: Dangerous commands blocked"
else
  echo "❌ FAIL: Dangerous commands allowed"
fi

# Test 5: Audit logging
echo "Test 5: Audit logging"
if auditctl -l | grep -q "ralph"; then
  echo "✅ PASS: Audit rules active"
else
  echo "❌ FAIL: No audit rules"
fi

echo ""
echo "Testing complete"
```

---

## Recovery Procedures

### If Ralph Goes Rogue

```bash
# Step 1: Immediate containment
ralph-killswitch "Suspicious activity detected"

# Step 2: Isolate network
iptables -A OUTPUT -m owner --uid-owner $(id -u ralph) -j DROP

# Step 3: Review logs
ausearch -ua ralph -ts today
tail -500 /var/log/ralph-monitor.log

# Step 4: Check for persistence mechanisms
find / -user ralph -perm -u+s 2>/dev/null
crontab -u ralph -l

# Step 5: Restore from snapshot if needed
restore-vm-snapshot ralph-baseline

# Step 6: Incident report
/usr/local/bin/generate-incident-report
```

---

## Maintenance Checklist

Daily:
- [ ] Review ralph-monitor.log for anomalies
- [ ] Check disk usage: `df -h /ralph-workspaces`
- [ ] Verify monitoring service: `systemctl status ralph-monitor`

Weekly:
- [ ] Rotate logs: `logrotate /etc/logrotate.d/ralph`
- [ ] Review audit logs: `ausearch -ua ralph`
- [ ] Clean old snapshots: `ralph-cleanup-snapshots`
- [ ] Update Ralph: `su - ralph -c "cd /opt/ralph && git pull"`

Monthly:
- [ ] Review firewall rules
- [ ] Update OS: `apt-get update && apt-get upgrade`
- [ ] Test recovery procedures
- [ ] Review and adjust resource limits

---

## Additional Considerations

### 1. Network Egress Filtering

For maximum security, use a transparent proxy to log and filter all Ralph's network traffic:

```bash
# Install squid proxy
apt-get install squid

# Configure for Ralph user only
# /etc/squid/squid.conf
```

### 2. Container Sandboxing

For k3s/Docker workloads, consider:
- gVisor for container sandboxing
- Kata Containers for VM-level isolation
- Seccomp profiles to restrict syscalls

### 3. Secret Management

Never let Ralph access production secrets:

```bash
# Create separate secret store
mkdir -p /ralph-secrets
chmod 0700 /ralph-secrets

# Use age encryption for secrets
age-keygen -o /ralph-secrets/key.txt
chmod 0400 /ralph-secrets/key.txt

# Ralph can only access encrypted dev secrets
chown ralph:ralph /ralph-secrets/dev-secrets.age
```

---

## Conclusion

This defense-in-depth approach ensures that even if Ralph is compromised:

✅ Damage is contained to one VM
✅ No production network access
✅ Limited resource consumption
✅ All activity is logged
✅ Easy rollback via snapshots
✅ Automatic killswitch on anomalies

**Remember**: Security is not "set and forget". Regularly review logs, test procedures, and update defenses.
