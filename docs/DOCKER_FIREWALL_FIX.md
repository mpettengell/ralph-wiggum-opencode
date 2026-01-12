# Docker Firewall Bypass Fix

## ⚠️ Critical Security Issue

**Problem**: Docker automatically modifies iptables when forwarding ports, bypassing user-defined firewall rules. This can expose Ralph's containers to production networks we explicitly blocked.

**Example**:
```bash
# You block production network
iptables -A OUTPUT -d 10.0.1.0/24 -j DROP

# Ralph runs Docker container with port forwarding
docker run -p 8080:80 nginx

# Docker adds ACCEPT rule in DOCKER chain that bypasses your block!
# Production network can now access port 8080 on the Ralph VM
```

**Impact**: HIGH - Completely undermines network isolation

---

## Solutions (Apply ALL)

### Solution 1: Disable Docker's iptables Manipulation

Configure Docker daemon to not modify iptables automatically.

```bash
# /etc/docker/daemon.json
{
  "iptables": false,
  "ip-forward": false,
  "bridge": "none"
}
```

**Apply**:
```bash
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "iptables": false,
  "ip-forward": false,
  "bridge": "none"
}
EOF

systemctl restart docker
```

**Trade-off**: Docker networking requires manual setup. Ralph will need to use `--network host` or pre-configured networks.

---

### Solution 2: Use Docker DOCKER-USER Chain

If you need Docker to manage iptables (for easier networking), use the DOCKER-USER chain to add restrictions.

Docker checks DOCKER-USER chain **before** its own rules, so we can block networks here.

```bash
#!/bin/bash
# /usr/local/bin/docker-firewall-fix

set -euo pipefail

# Flush DOCKER-USER chain
iptables -F DOCKER-USER 2>/dev/null || iptables -N DOCKER-USER

# Block production networks in DOCKER-USER chain
BLOCKED_NETWORKS=(
  "10.0.1.0/24"      # Production
  "192.168.1.0/24"   # Management
  # Add your networks here
)

for network in "${BLOCKED_NETWORKS[@]}"; do
  # Block incoming from these networks
  iptables -I DOCKER-USER -s "$network" -j DROP

  # Block outgoing to these networks
  iptables -I DOCKER-USER -d "$network" -j DROP

  echo "Blocked Docker traffic to/from: $network"
done

# Log blocked attempts
iptables -A DOCKER-USER -m limit --limit 5/min -j LOG --log-prefix "DOCKER-BLOCKED: " --log-level 4

# Accept everything else (Docker will handle port forwarding)
iptables -A DOCKER-USER -j RETURN

echo "Docker firewall rules applied"
```

**Apply**:
```bash
chmod +x /usr/local/bin/docker-firewall-fix
/usr/local/bin/docker-firewall-fix

# Make persistent
iptables-save > /etc/iptables/rules.v4
```

---

### Solution 3: Restrict Docker to Specific Interface

Bind Docker daemon to loopback only, preventing external access.

```bash
# /etc/docker/daemon.json
{
  "ip": "127.0.0.1",
  "iptables": true
}
```

Ralph's containers can only be accessed from localhost, not from network.

---

### Solution 4: Use Docker Rootless Mode (Recommended)

Rootless Docker **cannot modify system iptables**, providing natural isolation.

```bash
# Setup rootless Docker for ralph user
su - ralph

# Install rootless Docker
curl -fsSL https://get.docker.com/rootless | sh

# Configure environment
cat >> ~/.bashrc <<'EOF'
export PATH=/home/ralph/bin:$PATH
export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock
EOF

source ~/.bashrc

# Enable and start
systemctl --user enable docker
systemctl --user start docker

# Verify
docker run hello-world
```

**Benefits**:
- Ralph cannot modify system iptables (no root access)
- Natural isolation from system networking
- Containers run as ralph user
- No DOCKER chain manipulation

**Limitations**:
- Cannot bind to ports < 1024
- Some Docker features unavailable (cgroups v1 on old kernels)
- Performance overhead (negligible for dev environments)

---

## Recommended Configuration

**For Maximum Security: Rootless Docker + DOCKER-USER blocks**

```bash
#!/bin/bash
# Complete Docker security setup

set -euo pipefail

echo "=== Docker Security Hardening ==="

# 1. Setup rootless Docker for ralph user
echo "[1/4] Installing rootless Docker..."
su - ralph -c "curl -fsSL https://get.docker.com/rootless | sh"

su - ralph <<'EOF'
cat >> ~/.bashrc <<'BASHRC'
export PATH=/home/ralph/bin:$PATH
export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock
BASHRC

source ~/.bashrc
systemctl --user enable docker
systemctl --user start docker
EOF

# 2. For root Docker (if needed), configure restrictions
echo "[2/4] Configuring root Docker restrictions..."
if systemctl is-active docker >/dev/null 2>&1; then
  mkdir -p /etc/docker

  cat > /etc/docker/daemon.json <<'EOF'
{
  "iptables": true,
  "userland-proxy": false,
  "ip-forward": true,
  "default-address-pools": [
    {
      "base": "172.30.0.0/16",
      "size": 24
    }
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

  systemctl restart docker
fi

# 3. Apply DOCKER-USER firewall rules
echo "[3/4] Applying DOCKER-USER firewall rules..."

# Ensure DOCKER-USER chain exists
iptables -N DOCKER-USER 2>/dev/null || iptables -F DOCKER-USER

# Block production networks
BLOCKED_NETWORKS=(
  "10.0.1.0/24"
  "192.168.1.0/24"
)

for network in "${BLOCKED_NETWORKS[@]}"; do
  iptables -I DOCKER-USER -s "$network" -j DROP
  iptables -I DOCKER-USER -d "$network" -j DROP
done

# Log and return
iptables -A DOCKER-USER -m limit --limit 5/min -j LOG --log-prefix "DOCKER-BLOCKED: "
iptables -A DOCKER-USER -j RETURN

# 4. Make persistent
echo "[4/4] Making rules persistent..."
if command -v iptables-save >/dev/null 2>&1; then
  iptables-save > /etc/iptables/rules.v4
fi

# 5. Create systemd service to reapply on boot
cat > /etc/systemd/system/docker-firewall.service <<'EOF'
[Unit]
Description=Docker Firewall Rules
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/docker-firewall-fix
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable docker-firewall

echo ""
echo "✅ Docker security hardening complete"
echo ""
echo "Verification:"
echo "  1. Check rootless Docker:"
echo "     su - ralph -c 'docker ps'"
echo ""
echo "  2. Check DOCKER-USER rules:"
echo "     iptables -L DOCKER-USER -n -v"
echo ""
echo "  3. Test blocking (should fail):"
echo "     docker run --rm -p 8080:80 nginx &"
echo "     curl http://ralph-vm:8080 # From production network"
echo ""
```

---

## Testing Docker Firewall

```bash
#!/bin/bash
# Test Docker firewall restrictions

set -euo pipefail

echo "=== Docker Firewall Security Test ==="

# Test 1: Verify DOCKER-USER chain exists
echo "Test 1: DOCKER-USER chain"
if iptables -L DOCKER-USER -n >/dev/null 2>&1; then
  echo "  ✅ DOCKER-USER chain exists"
else
  echo "  ❌ DOCKER-USER chain missing"
fi

# Test 2: Verify production network blocked in DOCKER-USER
echo "Test 2: Production network blocking"
if iptables -L DOCKER-USER -n | grep -q "10.0.1.0/24"; then
  echo "  ✅ Production network blocked in DOCKER-USER"
else
  echo "  ❌ Production network not blocked"
fi

# Test 3: Verify rootless Docker for ralph
echo "Test 3: Rootless Docker"
if su - ralph -c "docker ps" >/dev/null 2>&1; then
  echo "  ✅ Rootless Docker working for ralph user"
else
  echo "  ⚠️  Rootless Docker not configured"
fi

# Test 4: Check if Docker can modify iptables
echo "Test 4: Docker iptables manipulation"
IPTABLES_SETTING=$(docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -o "iptables=\w*" || echo "unknown")
echo "  Status: $IPTABLES_SETTING"

# Test 5: Test actual blocking
echo "Test 5: Network blocking (requires manual verification)"
echo "  Run from production network:"
echo "    docker run -d --rm -p 8888:80 --name test-nginx nginx"
echo "    curl http://ralph-vm:8888"
echo "  Expected: Connection should be blocked/timeout"

echo ""
echo "Manual verification required for Test 5"
```

---

## Docker Compose Considerations

When using Docker Compose with Ralph, ensure networks are restricted:

```yaml
# docker-compose.yml - SECURE configuration

version: '3.8'

services:
  app:
    image: nginx
    ports:
      # Bind to localhost only
      - "127.0.0.1:8080:80"
    networks:
      - internal
    restart: unless-stopped

  db:
    image: postgres:15
    # No ports exposed to host
    networks:
      - internal
    environment:
      POSTGRES_PASSWORD: dev-only-password
    restart: unless-stopped

networks:
  internal:
    driver: bridge
    internal: true  # No external connectivity
    ipam:
      config:
        - subnet: 172.30.1.0/24

# Alternative: Use host network with firewall restrictions
# services:
#   app:
#     image: nginx
#     network_mode: "host"
```

**Key Points**:
- Bind ports to `127.0.0.1` not `0.0.0.0`
- Use `internal: true` for databases/backend services
- Use custom networks with defined subnets
- Never expose services on `0.0.0.0` directly

---

## Kubernetes (k3s) Firewall Considerations

K3s also manipulates iptables. Apply similar restrictions:

```bash
#!/bin/bash
# k3s firewall restrictions

# Block production networks in KUBE-FIREWALL chain
iptables -N KUBE-FIREWALL 2>/dev/null || iptables -F KUBE-FIREWALL

BLOCKED_NETWORKS=(
  "10.0.1.0/24"
  "192.168.1.0/24"
)

for network in "${BLOCKED_NETWORKS[@]}"; do
  iptables -I KUBE-FIREWALL -s "$network" -j DROP
  iptables -I KUBE-FIREWALL -d "$network" -j DROP
done

# Install k3s with custom options
curl -sfL https://get.k3s.io | sh -s - \
  --disable traefik \
  --disable servicelb \
  --cluster-cidr=172.30.0.0/16 \
  --service-cidr=172.31.0.0/16 \
  --write-kubeconfig-mode 644
```

**Configure k3s services to bind localhost only**:
```yaml
# k3s service
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  type: NodePort
  # Use externalIPs with localhost only
  externalIPs:
    - 127.0.0.1
  ports:
    - port: 80
      nodePort: 30080
  selector:
    app: my-app
```

---

## Monitoring Docker Firewall Bypass Attempts

```bash
#!/bin/bash
# Monitor for Docker firewall bypass attempts

# Watch for DOCKER-BLOCKED logs
journalctl -kf | grep DOCKER-BLOCKED

# Or via syslog
tail -f /var/log/syslog | grep DOCKER-BLOCKED

# Alert on bypass attempts
while true; do
  COUNT=$(journalctl -k --since "1 minute ago" | grep -c DOCKER-BLOCKED)
  if [[ $COUNT -gt 5 ]]; then
    echo "ALERT: $COUNT Docker firewall bypass attempts in last minute"
    # Send alert
    /usr/local/bin/ralph-killswitch "Docker firewall bypass detected"
  fi
  sleep 60
done
```

---

## Updated setup-security.sh Integration

Add to the security setup script:

```bash
# Add after Step 4 (Firewall Configuration)

echo ""
echo "Step 4b: Docker Firewall Fix"
echo "─────────────────────────────────────"

# Setup rootless Docker for ralph
su - ralph -c "curl -fsSL https://get.docker.com/rootless | sh"

su - ralph <<'EOF'
cat >> ~/.bashrc <<'BASHRC'
export PATH=/home/ralph/bin:$PATH
export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock
BASHRC
source ~/.bashrc
systemctl --user enable docker
systemctl --user start docker
EOF

log "Rootless Docker installed for ralph user"

# Apply DOCKER-USER restrictions for root Docker (if present)
if systemctl is-active docker >/dev/null 2>&1; then
  iptables -N DOCKER-USER 2>/dev/null || iptables -F DOCKER-USER

  # Block production networks
  iptables -I DOCKER-USER -d 10.0.1.0/24 -j DROP
  iptables -A DOCKER-USER -j RETURN

  log "DOCKER-USER firewall rules applied"
fi
```

---

## Quick Fix Command

For immediate mitigation on existing systems:

```bash
# One-liner to fix Docker firewall bypass
sudo bash -c '
  iptables -N DOCKER-USER 2>/dev/null || iptables -F DOCKER-USER
  iptables -I DOCKER-USER -d 10.0.1.0/24 -j DROP
  iptables -I DOCKER-USER -d 192.168.1.0/24 -j DROP
  iptables -A DOCKER-USER -j RETURN
  iptables-save > /etc/iptables/rules.v4
  echo "Docker firewall bypass fixed"
'
```

---

## Prevention Checklist

- [ ] Rootless Docker installed for ralph user
- [ ] DOCKER-USER chain configured with production network blocks
- [ ] Root Docker disabled or configured with `"iptables": false`
- [ ] Docker Compose uses `127.0.0.1` bindings or `internal: true`
- [ ] k3s configured with custom CIDRs and firewall rules
- [ ] Monitoring in place for DOCKER-BLOCKED logs
- [ ] Testing performed from production network (blocked)
- [ ] Rules persist after reboot (iptables-persistent)

---

## References

- Docker iptables documentation: https://docs.docker.com/network/iptables/
- Rootless Docker: https://docs.docker.com/engine/security/rootless/
- Docker security best practices: https://docs.docker.com/engine/security/

---

## Summary

**Critical**: Docker bypasses iptables OUTPUT rules with DOCKER chain rules.

**Fix**: Use rootless Docker (best) + DOCKER-USER chain blocks (defense in depth).

**Verify**:
```bash
# Should see blocks
iptables -L DOCKER-USER -n -v

# Should work
su - ralph -c "docker ps"

# Should be blocked from production network
curl http://ralph-vm:8080  # From 10.0.1.x
```

**Result**: Ralph's containers cannot accept connections from or connect to production networks.
