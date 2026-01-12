# Ralph Security Quick Start

> **TL;DR**: Run Ralph safely in an isolated VM with automatic damage containment

---

## 🚀 Quick Setup (5 minutes)

```bash
# 1. On your hypervisor, create a dedicated VM
#    - Ubuntu 22.04 LTS
#    - 4-8 CPU cores, 8-16GB RAM, 100GB disk
#    - Separate VLAN/network (e.g., 10.0.99.0/24)
#    - Enable snapshot support

# 2. SSH into the VM as root
ssh root@ralph-vm

# 3. Run the security setup script
cd /path/to/ralph-wiggum-opencode
chmod +x scripts/setup-security.sh
./scripts/setup-security.sh

# 4. Install Ralph for the ralph user
su - ralph
curl -fsSL https://raw.githubusercontent.com/agrimsingh/ralph-wiggum-opencode/main/install.sh | bash
exit

# 5. Apply firewall rules (review first!)
/usr/local/bin/ralph-firewall

# 6. CRITICAL: Apply Docker firewall fix
#    Docker bypasses iptables rules when forwarding ports!
nano /usr/local/bin/docker-firewall-fix  # Customize your networks
/usr/local/bin/docker-firewall-fix

# Verify Docker firewall
iptables -L DOCKER-USER -n -v

# 7. Create baseline snapshot
# (On hypervisor: qm snapshot <vmid> ralph-baseline)
```

**Done!** Now you can safely run Ralph.

> **⚠️ CRITICAL**: Always apply the Docker firewall fix! Docker automatically bypasses standard iptables rules when forwarding ports. See `docs/DOCKER_FIREWALL_FIX.md` for details.

---

## 📋 Daily Usage

### Start Ralph on a Project

```bash
# Create project workspace
mkdir -p /ralph-workspaces/my-api
chown ralph:ralph /ralph-workspaces/my-api

# Create RALPH_TASK.md
cd /ralph-workspaces/my-api
cat > RALPH_TASK.md <<'EOF'
---
task: Build a REST API
test_command: "npm test"
---

# Task: Build REST API

## Success Criteria
- [ ] Create Express server
- [ ] Add /health endpoint
- [ ] Add tests
- [ ] Pass all tests
EOF

# Run Ralph (as root or with sudo)
ralph-run my-api
```

### Monitor Progress

```bash
# Watch activity log
tail -f /ralph-workspaces/my-api/.ralph/activity.log

# Check resource usage
systemd-cgtop

# View Ralph processes
ps aux | grep ralph
```

### Stop Ralph

```bash
# Normal stop (Ctrl+C in ralph-run terminal)
^C

# Emergency stop
ralph-killswitch "Manual stop requested"

# Kill specific project
pkill -u ralph
```

---

## 🔒 Security Controls Active

> **⚠️ CRITICAL**: Docker bypasses iptables OUTPUT rules! You MUST apply the DOCKER-USER firewall rules. See step 6 in Quick Setup or read `docs/DOCKER_FIREWALL_FIX.md`.

### ✅ What's Protected

| Control | Protection |
|---------|------------|
| **User Isolation** | Ralph runs as non-root user with limited sudo |
| **Workspace Isolation** | Only access to `/ralph-workspaces/*` |
| **Resource Limits** | Max 80% CPU, 12GB RAM, 500 processes |
| **Network Isolation** | Blocked from production networks |
| **Docker Isolation** | DOCKER-USER chain + rootless Docker |
| **Filesystem Protection** | Cannot access `/etc`, `/root`, system dirs |
| **Audit Logging** | All actions logged |
| **Emergency Stop** | One-command killswitch |

### ⚠️ What Ralph CAN Do (by design)

- Create/modify files in `/ralph-workspaces/<project>/`
- Run Docker containers (rootless mode)
- Run k3s for Kubernetes
- Install npm/pip/gem packages in workspace
- Git operations in workspace
- Network access to allowed hosts (GitHub, Docker Hub, etc.)

### ❌ What Ralph CANNOT Do

- Access system directories (`/etc`, `/root`, `/bin`, etc.)
- Access production networks (configure in firewall)
- Reboot/shutdown system
- Create/modify users
- Access other users' files
- Use more than 12GB RAM or 80% CPU
- Run for more than 24 hours (default timeout)

---

## 🚨 Emergency Procedures

### If Ralph Goes Rogue

```bash
# 1. IMMEDIATE: Kill all Ralph processes
ralph-killswitch "Suspicious activity"

# 2. Block network access
iptables -A OUTPUT -m owner --uid-owner $(id -u ralph) -j DROP

# 3. Check what happened
tail -200 /var/log/ralph-sessions.log
find /ralph-workspaces -mmin -60 -ls

# 4. Restore from snapshot
# (On hypervisor: qm rollback <vmid> ralph-baseline)

# 5. Investigate
grep ralph /var/log/auth.log
ausearch -ua ralph -ts recent
```

### Recovery Checklist

- [ ] Kill all Ralph processes
- [ ] Block network
- [ ] Review logs
- [ ] Check for persistence (cron, systemd, authorized_keys)
- [ ] Restore from snapshot if needed
- [ ] Update firewall rules if necessary
- [ ] Review RALPH_TASK.md for suspicious content
- [ ] File incident report

---

## 🔥 Firewall Configuration

### Review Before Applying

```bash
# Edit to add your production networks
nano /usr/local/bin/ralph-firewall

# Add your networks to BLOCKED_NETWORKS:
BLOCKED_NETWORKS=(
  "10.0.1.0/24"     # Your production network
  "192.168.1.0/24"  # Your management network
  # etc...
)
```

### Apply Firewall Rules

```bash
# Test first (won't persist)
/usr/local/bin/ralph-firewall

# Make persistent
apt-get install iptables-persistent
iptables-save > /etc/iptables/rules.v4
```

### Verify Blocking

```bash
# Test from ralph user
su - ralph
ping 10.0.1.1  # Should be blocked
curl https://github.com  # Should work
```

---

## 📊 Monitoring

### Real-Time Monitoring

```bash
# Resource usage
watch -n 5 'systemd-cgtop | grep ralph'

# Network connections
watch -n 5 'netstat -tnp | grep ralph'

# Disk usage
watch -n 30 'df -h /ralph-workspaces'
```

### Log Files

```bash
# Ralph sessions
tail -f /var/log/ralph-sessions.log

# Activity log (per project)
tail -f /ralph-workspaces/<project>/.ralph/activity.log

# Incident reports
ls -lah /var/log/ralph-incidents/

# System auth log
grep ralph /var/log/auth.log

# Firewall blocks
grep RALPH-BLOCKED /var/log/syslog
```

---

## 💾 Backup Strategy

### VM Snapshots (Recommended)

```bash
# Before each Ralph run (automatic if using wrapper)
qm snapshot <vmid> ralph-pre-run-$(date +%Y%m%d-%H%M%S)

# Baseline snapshot (after setup)
qm snapshot <vmid> ralph-baseline

# Restore if needed
qm rollback <vmid> ralph-baseline
```

### Workspace Backups

```bash
# Daily backup of workspaces
rsync -av /ralph-workspaces/ backup-server:/backups/ralph/$(date +%Y%m%d)/

# Or use git (already tracked)
cd /ralph-workspaces/<project>
git push origin main  # If using remote
```

---

## 🛠️ Troubleshooting

### Ralph won't start

```bash
# Check if ralph user exists
id ralph

# Check if scripts are installed
ls -la /home/ralph/.opencode/ralph-scripts/

# Check resource limits
systemctl show user-$(id -u ralph).slice | grep -i memory

# Check workspace permissions
ls -la /ralph-workspaces/
```

### High resource usage

```bash
# Check what Ralph is doing
ps aux | grep ralph

# Check cgroup limits
systemctl status user-$(id -u ralph).slice

# View activity log
tail -50 /ralph-workspaces/<project>/.ralph/activity.log
```

### Network issues

```bash
# Check firewall rules
iptables -L OUTPUT -n -v | grep ralph

# Test connectivity as ralph user
su - ralph -c "curl -I https://github.com"

# View blocked attempts
grep RALPH-BLOCKED /var/log/syslog
```

### "Permission denied" errors

```bash
# Check workspace ownership
ls -la /ralph-workspaces/<project>

# Fix permissions
chown -R ralph:ralph /ralph-workspaces/<project>
chmod -R u+rwX /ralph-workspaces/<project>

# Check sudo rules
sudo -l -U ralph
```

---

## 🎯 Best Practices

### DO ✅

- **Create a baseline snapshot** before running Ralph
- **Review RALPH_TASK.md** before starting
- **Monitor resource usage** during runs
- **Keep VM isolated** from production networks
- **Review logs regularly** for anomalies
- **Test recovery procedures** monthly
- **Update Ralph** and OS regularly
- **Use timeouts** for all runs

### DON'T ❌

- **Don't run Ralph on production systems**
- **Don't give Ralph access to production secrets**
- **Don't disable security controls** "temporarily"
- **Don't ignore alerts** from monitoring
- **Don't skip baseline snapshots**
- **Don't connect Ralph VM** to production networks
- **Don't run as root** (use the wrapper)
- **Don't trust AI-generated code** without review

---

## 📐 Architecture Diagram

```
┌─────────────────────────────────────────────────────────┐
│                    Your Infrastructure                  │
│  ┌────────────────┐         ┌──────────────────────┐   │
│  │  Production    │         │    Ralph VM          │   │
│  │  Network       │    ❌   │   (Isolated)         │   │
│  │  10.0.1.0/24   │◄────────│   10.0.99.0/24       │   │
│  └────────────────┘  Blocked└──────────────────────┘   │
│                                │                        │
│                                │ ✅ Allowed             │
│                                ▼                        │
│  ┌────────────────────────────────────────────────┐    │
│  │  External (Filtered)                           │    │
│  │  - GitHub (git operations)                     │    │
│  │  - Docker Hub (image pulls)                    │    │
│  │  - OpenCode API (LLM access)                   │    │
│  │  - Package repos (npm, pip, apt)               │    │
│  └────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘

Ralph VM Internal:
┌──────────────────────────────────────────────┐
│ ralph user (non-root)                        │
│  ├─ /ralph-workspaces/<project>/  ✅         │
│  │   └─ Full access                          │
│  ├─ /etc/, /root/, /bin/  ❌                 │
│  │   └─ No access                            │
│  └─ Limits: 80% CPU, 12GB RAM, 500 tasks    │
└──────────────────────────────────────────────┘
```

---

## 📞 Quick Reference

| Task | Command |
|------|---------|
| **Run Ralph** | `ralph-run <project>` |
| **Stop Ralph** | `ralph-killswitch "reason"` |
| **Monitor** | `tail -f /ralph-workspaces/<project>/.ralph/activity.log` |
| **Check resources** | `systemd-cgtop` |
| **View logs** | `tail -f /var/log/ralph-sessions.log` |
| **Apply Docker firewall** | `/usr/local/bin/docker-firewall-fix` |
| **Check Docker rules** | `iptables -L DOCKER-USER -n -v` |
| **Test security** | `/usr/local/bin/test-ralph-security` |
| **Apply firewall** | `/usr/local/bin/ralph-firewall` |
| **Create snapshot** | `qm snapshot <vmid> <name>` (on hypervisor) |
| **Restore snapshot** | `qm rollback <vmid> <name>` (on hypervisor) |

---

## 📚 Further Reading

- **Complete Guide**: `SECURITY_HARDENING.md` (full documentation)
- **Security Review**: `SECURITY_REVIEW.md` (vulnerability analysis)
- **Ralph README**: `README.md` (how Ralph works)

---

## 🆘 Support

If something goes wrong:

1. **Immediate**: Run `ralph-killswitch "issue description"`
2. **Restore**: Rollback to baseline snapshot
3. **Report**: Check `/var/log/ralph-incidents/` for details
4. **Review**: Read logs and incident reports
5. **Fix**: Update security controls as needed

**Remember**: It's just a VM. When in doubt, nuke it and restore from snapshot. That's the whole point of the isolation! 🎯
