#!/bin/bash
# Ralph Security Setup Script
# Quick deployment of essential security controls

set -euo pipefail

RALPH_USER="ralph"
WORKSPACE_BASE="/ralph-workspaces"
ADMIN_EMAIL="${ADMIN_EMAIL:-root@localhost}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
  echo -e "${GREEN}[✓]${NC} $*"
}

warn() {
  echo -e "${YELLOW}[!]${NC} $*"
}

error() {
  echo -e "${RED}[✗]${NC} $*"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root"
   exit 1
fi

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║           Ralph Security Hardening Setup                      ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# ============================================================================
# STEP 1: Create Ralph User
# ============================================================================

echo "Step 1: User Setup"
echo "─────────────────────────────────────"

if id "$RALPH_USER" >/dev/null 2>&1; then
  warn "User '$RALPH_USER' already exists"
else
  useradd -m -d /home/$RALPH_USER -s /bin/bash $RALPH_USER
  log "Created user: $RALPH_USER"
fi

# ============================================================================
# STEP 2: Workspace Directory
# ============================================================================

echo ""
echo "Step 2: Workspace Setup"
echo "─────────────────────────────────────"

mkdir -p "$WORKSPACE_BASE"
chown $RALPH_USER:$RALPH_USER "$WORKSPACE_BASE"
chmod 0750 "$WORKSPACE_BASE"
log "Workspace created: $WORKSPACE_BASE"

# ============================================================================
# STEP 3: Sudo Configuration
# ============================================================================

echo ""
echo "Step 3: Sudo Configuration"
echo "─────────────────────────────────────"

cat > /etc/sudoers.d/$RALPH_USER <<'EOF'
# Ralph user - limited sudo access
Defaults:ralph !authenticate

# Allow specific commands without password
ralph ALL=(ALL) NOPASSWD: /usr/bin/docker
ralph ALL=(ALL) NOPASSWD: /usr/local/bin/docker-compose
ralph ALL=(ALL) NOPASSWD: /usr/bin/kubectl
ralph ALL=(ALL) NOPASSWD: /usr/local/bin/k3s
ralph ALL=(ALL) NOPASSWD: /bin/systemctl start k3s
ralph ALL=(ALL) NOPASSWD: /bin/systemctl stop k3s
ralph ALL=(ALL) NOPASSWD: /bin/systemctl restart k3s
ralph ALL=(ALL) NOPASSWD: /bin/systemctl status k3s

# Explicitly deny dangerous commands
Cmnd_Alias DANGEROUS = /bin/rm -rf /, /sbin/reboot, /sbin/shutdown, /sbin/poweroff, /sbin/halt, /usr/sbin/userdel, /usr/sbin/usermod, /usr/bin/passwd [a-z]*, /bin/su
ralph ALL=(ALL) !DANGEROUS
EOF

chmod 0440 /etc/sudoers.d/$RALPH_USER
log "Sudo configuration created"

# Validate sudoers file
if visudo -c -f /etc/sudoers.d/$RALPH_USER; then
  log "Sudoers file validated"
else
  error "Sudoers file invalid, removing"
  rm -f /etc/sudoers.d/$RALPH_USER
  exit 1
fi

# ============================================================================
# STEP 4: Firewall Rules
# ============================================================================

echo ""
echo "Step 4: Firewall Configuration"
echo "─────────────────────────────────────"

# Backup existing rules
iptables-save > /root/iptables-backup-$(date +%Y%m%d-%H%M%S).rules
log "Backed up existing firewall rules"

# Create firewall script
cat > /usr/local/bin/ralph-firewall <<'FWEOF'
#!/bin/bash
set -euo pipefail

# Get ralph UID
RALPH_UID=$(id -u ralph)

# Block ralph user from accessing common private network ranges
# Add your production networks here
BLOCKED_NETWORKS=(
  "10.0.0.0/8"      # Private network class A
  "172.16.0.0/12"   # Private network class B
  "192.168.0.0/16"  # Private network class C
)

# Exception: Allow localhost
iptables -A OUTPUT -m owner --uid-owner $RALPH_UID -d 127.0.0.1 -j ACCEPT

# Block private networks (add exceptions above as needed)
for network in "${BLOCKED_NETWORKS[@]}"; do
  iptables -A OUTPUT -m owner --uid-owner $RALPH_UID -d "$network" -j DROP
done

# Log blocked attempts
iptables -A OUTPUT -m owner --uid-owner $RALPH_UID -m limit --limit 5/min -j LOG --log-prefix "RALPH-BLOCKED: " --log-level 4

echo "Ralph firewall rules applied"
FWEOF

chmod +x /usr/local/bin/ralph-firewall

warn "Firewall script created but NOT applied automatically"
warn "Review /usr/local/bin/ralph-firewall and run manually"
warn "This prevents accidental network disruption"

# ============================================================================
# STEP 5: Resource Limits (cgroups)
# ============================================================================

echo ""
echo "Step 5: Resource Limits"
echo "─────────────────────────────────────"

# Create systemd slice for ralph
cat > /etc/systemd/system/ralph.slice <<'EOF'
[Unit]
Description=Resource limits for Ralph user
Before=slices.target

[Slice]
# Limit CPU to 80% of total
CPUQuota=80%

# Limit RAM to 12GB
MemoryMax=12G
MemoryHigh=10G

# Limit number of processes/threads
TasksMax=500

# Limit I/O weight (default is 100)
IOWeight=500
EOF

# Apply slice to ralph user
mkdir -p /etc/systemd/system/user-$(id -u $RALPH_USER).slice.d
cat > /etc/systemd/system/user-$(id -u $RALPH_USER).slice.d/override.conf <<EOF
[Slice]
Slice=ralph.slice
EOF

systemctl daemon-reload
log "Resource limits configured (CPU: 80%, RAM: 12GB, Tasks: 500)"

# ============================================================================
# STEP 6: Workspace Validation Script
# ============================================================================

echo ""
echo "Step 6: Workspace Validation"
echo "─────────────────────────────────────"

cat > /usr/local/bin/ralph-validate-workspace <<'EOF'
#!/bin/bash
# Validate workspace path for security

set -euo pipefail

validate_workspace() {
  local path="$1"

  # Resolve to absolute path
  if ! path="$(cd "$path" && pwd)" 2>/dev/null; then
    echo "ERROR: Invalid workspace path: $1" >&2
    return 1
  fi

  # CRITICAL: Must be under /ralph-workspaces
  if [[ ! "$path" =~ ^/ralph-workspaces/ ]]; then
    echo "ERROR: Workspace must be under /ralph-workspaces/" >&2
    echo "       Got: $path" >&2
    return 1
  fi

  # Must not contain path traversal
  if [[ "$path" =~ \.\. ]]; then
    echo "ERROR: Workspace path contains path traversal (..)" >&2
    return 1
  fi

  # Blacklist system directories (defense in depth)
  local forbidden_dirs=(
    "/" "/bin" "/boot" "/dev" "/etc" "/lib" "/lib64"
    "/proc" "/root" "/sbin" "/sys" "/usr" "/var/lib"
  )

  for forbidden in "${forbidden_dirs[@]}"; do
    if [[ "$path" == "$forbidden" ]] || [[ "$path" =~ ^${forbidden}/ ]]; then
      echo "ERROR: Cannot use system directory: $path" >&2
      return 1
    fi
  done

  # Initialize git repo if needed
  if ! git -C "$path" rev-parse --git-dir > /dev/null 2>&1; then
    echo "WARNING: Not a git repository. Initializing..." >&2
    git -C "$path" init
  fi

  echo "$path"
}

validate_workspace "$@"
EOF

chmod +x /usr/local/bin/ralph-validate-workspace
log "Workspace validation script created"

# ============================================================================
# STEP 7: Hardened Ralph Wrapper
# ============================================================================

echo ""
echo "Step 7: Hardened Wrapper Script"
echo "─────────────────────────────────────"

cat > /usr/local/bin/ralph-run <<'EOF'
#!/bin/bash
# Hardened Ralph runner with security controls

set -euo pipefail

RALPH_USER="ralph"
WORKSPACE_BASE="/ralph-workspaces"
MAX_RUNTIME="${RALPH_TIMEOUT:-24h}"

usage() {
  cat <<USAGE
Usage: $(basename $0) <project-name>

Run Ralph in a hardened, isolated environment.

Options:
  RALPH_TIMEOUT    Max runtime (default: 24h)
                   Examples: 2h, 30m, 1d

Environment:
  Workspace:  $WORKSPACE_BASE/<project-name>
  User:       $RALPH_USER (non-root)
  Limits:     CPU 80%, RAM 12GB, Tasks 500

Examples:
  $(basename $0) my-microservice
  RALPH_TIMEOUT=4h $(basename $0) quick-test

Monitor:
  tail -f $WORKSPACE_BASE/<project-name>/.ralph/activity.log
USAGE
  exit 0
}

[[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]] && usage

if [[ $# -lt 1 ]]; then
  echo "ERROR: Project name required" >&2
  usage
fi

PROJECT_NAME="$1"
WORKSPACE="$WORKSPACE_BASE/$PROJECT_NAME"

# Validate workspace path
if ! /usr/local/bin/ralph-validate-workspace "$WORKSPACE" >/dev/null; then
  echo "ERROR: Workspace validation failed" >&2
  exit 1
fi

# Create workspace if needed
if [[ ! -d "$WORKSPACE" ]]; then
  echo "Creating workspace: $WORKSPACE"
  mkdir -p "$WORKSPACE"
  chown $RALPH_USER:$RALPH_USER "$WORKSPACE"
  chmod 0750 "$WORKSPACE"
fi

# Check if ralph scripts are installed
if [[ ! -f /home/$RALPH_USER/.opencode/ralph-scripts/ralph-loop.sh ]]; then
  echo "ERROR: Ralph not installed for user $RALPH_USER" >&2
  echo "       Run: su - $RALPH_USER -c 'curl -fsSL https://raw.githubusercontent.com/agrimsingh/ralph-wiggum-opencode/main/install.sh | bash'" >&2
  exit 1
fi

# Log start
echo "[$(date)] Starting Ralph for project: $PROJECT_NAME (timeout: $MAX_RUNTIME)" | \
  tee -a /var/log/ralph-sessions.log

# Display info
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                     Ralph Starting                             ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Project:    $PROJECT_NAME"
echo "  Workspace:  $WORKSPACE"
echo "  User:       $RALPH_USER (UID: $(id -u $RALPH_USER))"
echo "  Timeout:    $MAX_RUNTIME"
echo "  Limits:     CPU: 80%, RAM: 12GB, Tasks: 500"
echo ""
echo "  Monitor:    tail -f $WORKSPACE/.ralph/activity.log"
echo "  Stop:       pkill -u $RALPH_USER"
echo ""
echo "────────────────────────────────────────────────────────────────"

# Trap for cleanup
cleanup() {
  local exit_code=$?
  echo ""
  echo "────────────────────────────────────────────────────────────────"
  if [[ $exit_code -eq 0 ]]; then
    echo "✅ Ralph completed successfully"
  elif [[ $exit_code -eq 124 ]]; then
    echo "⏱️  Ralph timed out after $MAX_RUNTIME"
  else
    echo "❌ Ralph exited with error (code: $exit_code)"
  fi
  echo "[$(date)] Stopped Ralph for project: $PROJECT_NAME (exit: $exit_code)" | \
    tee -a /var/log/ralph-sessions.log
}
trap cleanup EXIT

# Run Ralph with systemd-run for proper isolation
exec systemd-run \
  --uid="$RALPH_USER" \
  --gid="$RALPH_USER" \
  --slice=ralph.slice \
  --working-directory="$WORKSPACE" \
  --setenv=HOME="/home/$RALPH_USER" \
  --setenv=RALPH_TASK_FILE="$WORKSPACE/RALPH_TASK.md" \
  --property=MemoryMax=12G \
  --property=CPUQuota=80% \
  --property=TasksMax=500 \
  --pty \
  --wait \
  --collect \
  timeout "$MAX_RUNTIME" \
  /home/$RALPH_USER/.opencode/ralph-scripts/ralph-loop.sh "$WORKSPACE"
EOF

chmod +x /usr/local/bin/ralph-run
log "Hardened wrapper created: /usr/local/bin/ralph-run"

# ============================================================================
# STEP 8: Kill Switch
# ============================================================================

echo ""
echo "Step 8: Emergency Kill Switch"
echo "─────────────────────────────────────"

cat > /usr/local/bin/ralph-killswitch <<EOF
#!/bin/bash
# Emergency stop for Ralph

set -euo pipefail

REASON="\${1:-Manual intervention}"
RALPH_USER="$RALPH_USER"

echo "🚨 RALPH EMERGENCY STOP"
echo "======================="
echo "Reason: \$REASON"
echo "Time:   \$(date)"
echo ""

# Stop all Ralph processes
echo "Stopping all Ralph processes..."
pkill -u \$RALPH_USER -9 || true

# Stop Docker containers
echo "Stopping Docker containers..."
su - \$RALPH_USER -c "docker stop \\\$(docker ps -q) 2>/dev/null" || true

# Stop k3s if running
echo "Stopping k3s..."
systemctl stop k3s 2>/dev/null || true

# Log incident
mkdir -p /var/log/ralph-incidents
INCIDENT_FILE="/var/log/ralph-incidents/\$(date +%Y%m%d-%H%M%S).log"

cat > "\$INCIDENT_FILE" <<INCIDENT
Ralph Killswitch Activation
===========================
Timestamp: \$(date)
Reason: \$REASON

Process List:
\$(ps aux | grep ralph || echo "No processes found")

Network Connections:
\$(netstat -tnp 2>/dev/null | grep ralph || echo "No connections found")

Recent Files:
\$(find /ralph-workspaces -mmin -60 -ls 2>/dev/null | head -20 || echo "No recent files")
INCIDENT

echo ""
echo "✅ All Ralph processes stopped"
echo "📄 Incident report: \$INCIDENT_FILE"

# Send alert if mail is configured
if command -v mail >/dev/null 2>&1; then
  mail -s "[RALPH ALERT] Emergency stop: \$REASON" $ADMIN_EMAIL < "\$INCIDENT_FILE" 2>/dev/null || true
fi
EOF

chmod +x /usr/local/bin/ralph-killswitch
log "Kill switch created: /usr/local/bin/ralph-killswitch"

# ============================================================================
# STEP 9: Install Dependencies (if needed)
# ============================================================================

echo ""
echo "Step 9: Check Dependencies"
echo "─────────────────────────────────────"

MISSING_DEPS=()

command -v git >/dev/null 2>&1 || MISSING_DEPS+=("git")
command -v jq >/dev/null 2>&1 || MISSING_DEPS+=("jq")
command -v systemd-run >/dev/null 2>&1 || MISSING_DEPS+=("systemd")

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
  warn "Missing dependencies: ${MISSING_DEPS[*]}"
  read -p "Install now? [Y/n] " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update
      apt-get install -y "${MISSING_DEPS[@]}"
      log "Dependencies installed"
    elif command -v yum >/dev/null 2>&1; then
      yum install -y "${MISSING_DEPS[@]}"
      log "Dependencies installed"
    else
      error "Cannot auto-install. Please install: ${MISSING_DEPS[*]}"
    fi
  fi
else
  log "All dependencies present"
fi

# ============================================================================
# STEP 10: Summary
# ============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    Setup Complete ✅                           ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Security Controls Deployed:"
echo "  ✅ Dedicated user: $RALPH_USER"
echo "  ✅ Workspace isolation: $WORKSPACE_BASE"
echo "  ✅ Sudo restrictions (limited commands only)"
echo "  ✅ Resource limits (CPU 80%, RAM 12GB)"
echo "  ✅ Workspace validation"
echo "  ✅ Emergency kill switch"
echo ""
echo "⚠️  Manual Steps Required:"
echo "  1. Review and apply firewall rules:"
echo "     /usr/local/bin/ralph-firewall"
echo ""
echo "  2. Install Ralph for the ralph user:"
echo "     su - $RALPH_USER"
echo "     curl -fsSL https://raw.githubusercontent.com/agrimsingh/ralph-wiggum-opencode/main/install.sh | bash"
echo ""
echo "  3. Create a test project:"
echo "     mkdir -p $WORKSPACE_BASE/test-project"
echo "     chown $RALPH_USER:$RALPH_USER $WORKSPACE_BASE/test-project"
echo ""
echo "  4. Configure RALPH_TASK.md in your project workspace"
echo ""
echo "Usage:"
echo "  ralph-run <project-name>"
echo ""
echo "Examples:"
echo "  ralph-run my-microservice"
echo "  RALPH_TIMEOUT=4h ralph-run quick-test"
echo ""
echo "Emergency Stop:"
echo "  ralph-killswitch 'reason for stop'"
echo ""
echo "Monitoring:"
echo "  tail -f $WORKSPACE_BASE/<project>/.ralph/activity.log"
echo "  journalctl -u user@\$(id -u $RALPH_USER).service -f"
echo ""
echo "Documentation:"
echo "  See SECURITY_HARDENING.md for complete details"
echo ""
