# k3s and Docker Compose Firewall Protection

## ⚠️ The Problem

Both k3s and docker-compose can bypass firewall rules through iptables manipulation:

### k3s Issues
- k3s creates its own iptables chains (KUBE-FIREWALL, KUBE-FORWARD, KUBE-SERVICES)
- kube-proxy manipulates iptables for service load balancing
- NodePort services can expose ports on all interfaces
- Can bypass user-defined OUTPUT/FORWARD rules

### docker-compose Issues
- Uses Docker daemon (inherits Docker bypass issue)
- `network_mode: host` completely bypasses Docker networking
- Port bindings default to `0.0.0.0` (all interfaces)
- Can create arbitrary networks with custom routing

---

## Solution 1: k3s Firewall Protection

### Method A: Pre-k3s iptables Rules

Insert rules before k3s chains are processed:

```bash
#!/bin/bash
# /usr/local/bin/k3s-firewall-fix

set -euo pipefail

echo "Applying k3s firewall restrictions..."

# Create k3s firewall chain
iptables -N K3S-FIREWALL 2>/dev/null || iptables -F K3S-FIREWALL

# Block production networks (customize!)
BLOCKED_NETWORKS=(
  "10.0.1.0/24"      # Production
  "192.168.1.0/24"   # Management
)

for network in "${BLOCKED_NETWORKS[@]}"; do
  # Block incoming to k3s services from these networks
  iptables -I K3S-FIREWALL -s "$network" -j DROP

  # Block outgoing from k3s pods to these networks
  iptables -I K3S-FIREWALL -d "$network" -j DROP

  echo "  Blocked k3s traffic to/from: $network"
done

# Log blocked attempts
iptables -A K3S-FIREWALL -m limit --limit 5/min -j LOG --log-prefix "K3S-BLOCKED: "

# Insert into FORWARD chain (before k3s rules)
iptables -I FORWARD -j K3S-FIREWALL

# Also block in INPUT chain (for NodePort access)
iptables -I INPUT -j K3S-FIREWALL

echo "✅ k3s firewall rules applied"

# Make persistent
if command -v iptables-save >/dev/null 2>&1; then
  iptables-save > /etc/iptables/rules.v4
fi
```

### Method B: k3s Installation with Restrictions

Install k3s with security-focused options:

```bash
#!/bin/bash
# Secure k3s installation

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=" \
  --disable traefik \
  --disable servicelb \
  --disable-network-policy \
  --flannel-backend=none \
  --cluster-cidr=172.30.0.0/16 \
  --service-cidr=172.31.0.0/16 \
  --write-kubeconfig-mode 644 \
  --kube-apiserver-arg=anonymous-auth=false \
  --kube-apiserver-arg=authorization-mode=RBAC \
  --tls-san=127.0.0.1" sh -

# Verify restricted CIDRs
kubectl cluster-info dump | grep -E "cluster-cidr|service-cidr"
```

**Key Options:**
- `--cluster-cidr`: Restrict pod IPs to specific range
- `--service-cidr`: Restrict service IPs to specific range
- `--disable servicelb`: Prevents automatic LoadBalancer exposure
- `--disable traefik`: Removes default ingress controller

### Method C: Kubernetes NetworkPolicies

Use NetworkPolicies to restrict traffic within k3s:

```yaml
# /ralph-workspaces/k8s-network-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-production-networks
  namespace: default
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress

  # Block all by default
  ingress: []

  egress:
    # Allow DNS
    - to:
        - namespaceSelector:
            matchLabels:
              name: kube-system
      ports:
        - protocol: UDP
          port: 53

    # Allow within cluster
    - to:
        - podSelector: {}

    # Block production networks (using CIDR)
    # Note: This is a whitelist approach - only allow specific ranges
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.1.0/24      # Production
              - 192.168.1.0/24   # Management
              - 172.16.0.0/12    # Private
              - 192.168.0.0/16   # Private (excluding our range)
```

Apply policy:
```bash
kubectl apply -f k8s-network-policy.yaml
```

### Method D: Restrict k3s to Ralph User Only

Don't install k3s system-wide. Run it as the ralph user:

```bash
# As ralph user
su - ralph

# Install k3s in rootless mode (experimental)
curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_START=true sh -

# Configure to run as user service
mkdir -p ~/.config/systemd/user/

cat > ~/.config/systemd/user/k3s.service <<'EOF'
[Unit]
Description=k3s (rootless)
After=network.target

[Service]
Type=notify
ExecStart=/usr/local/bin/k3s server \
  --data-dir=%h/.local/share/k3s \
  --cluster-cidr=172.30.0.0/16 \
  --service-cidr=172.31.0.0/16 \
  --disable traefik \
  --disable servicelb

Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable k3s
systemctl --user start k3s
```

**Benefit**: Ralph's k3s cannot modify system iptables (no root access).

---

## Solution 2: docker-compose Protection

### Method A: Wrapper Script with Validation

Create a wrapper that validates compose files before running:

```bash
#!/bin/bash
# /usr/local/bin/docker-compose-safe

set -euo pipefail

COMPOSE_FILE="${1:-docker-compose.yml}"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "ERROR: Compose file not found: $COMPOSE_FILE" >&2
  exit 1
fi

echo "🔍 Validating $COMPOSE_FILE for security issues..."

# Check for host network mode (bypasses all isolation)
if grep -q "network_mode.*host" "$COMPOSE_FILE"; then
  echo "❌ ERROR: network_mode: host is not allowed" >&2
  echo "   This bypasses all network isolation" >&2
  exit 1
fi

# Check for privileged containers
if grep -q "privileged.*true" "$COMPOSE_FILE"; then
  echo "❌ ERROR: privileged: true is not allowed" >&2
  exit 1
fi

# Check for dangerous port bindings (0.0.0.0)
if grep -E "ports:.*\"[0-9]+:[0-9]+\"" "$COMPOSE_FILE" | grep -qv "127.0.0.1"; then
  echo "⚠️  WARNING: Port binding without localhost restriction detected" >&2
  echo "   Recommended format: \"127.0.0.1:8080:80\"" >&2
  echo "" >&2
  echo "Dangerous bindings found:" >&2
  grep -E "ports:.*\"[0-9]+:[0-9]+\"" "$COMPOSE_FILE" | grep -v "127.0.0.1" >&2
  echo "" >&2

  read -p "Continue anyway? [y/N] " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

# Check for cap_add (capability additions)
if grep -q "cap_add:" "$COMPOSE_FILE"; then
  echo "⚠️  WARNING: cap_add detected - review carefully" >&2
  grep -A 5 "cap_add:" "$COMPOSE_FILE" >&2
fi

# Check for volume mounts to sensitive directories
SENSITIVE_MOUNTS=(
  "/etc"
  "/root"
  "/var/lib/docker"
  "/sys"
  "/proc"
)

for mount in "${SENSITIVE_MOUNTS[@]}"; do
  if grep -E "volumes:.*$mount" "$COMPOSE_FILE" >/dev/null; then
    echo "❌ ERROR: Volume mount to sensitive directory detected: $mount" >&2
    exit 1
  fi
done

echo "✅ Security validation passed"
echo ""

# Run docker-compose with validated file
exec docker-compose -f "$COMPOSE_FILE" "${@:2}"
```

### Method B: Enforce Localhost Binding with Environment Variable

```bash
# /etc/environment or ralph's .bashrc
export DOCKER_HOST_IP=127.0.0.1
```

Then in compose files, use:
```yaml
services:
  web:
    ports:
      - "${DOCKER_HOST_IP:-127.0.0.1}:8080:80"
```

### Method C: AppArmor Profile for docker-compose

Restrict what docker-compose can do:

```bash
# /etc/apparmor.d/usr.local.bin.docker-compose

#include <tunables/global>

/usr/local/bin/docker-compose {
  #include <abstractions/base>

  # Allow docker-compose to work
  /usr/local/bin/docker-compose r,
  /usr/bin/docker rix,
  /var/run/docker.sock rw,

  # Allow reading compose files in workspace only
  /ralph-workspaces/** r,

  # Deny everything else
  deny /etc/docker/** w,
  deny /etc/systemd/** w,
  deny /root/** rw,
  deny /home/*/** w,

  # Allow temp and logs
  /tmp/** rw,
  /var/tmp/** rw,
  /var/log/docker-compose.log w,
}
```

Apply:
```bash
apparmor_parser -r /etc/apparmor.d/usr.local.bin.docker-compose
aa-enforce /usr/local/bin/docker-compose
```

### Method D: Compose File Template Enforcement

Provide a secure template that Ralph must use:

```yaml
# /usr/local/share/ralph/docker-compose.template.yml
version: '3.8'

# Security notes:
# - All ports MUST bind to 127.0.0.1
# - No privileged containers
# - No host network mode
# - Use internal networks for inter-service communication

services:
  app:
    image: your-image
    ports:
      # ✅ CORRECT: Bind to localhost only
      - "127.0.0.1:8080:80"

      # ❌ WRONG: Binds to all interfaces
      # - "8080:80"

    networks:
      - internal

    # Security restrictions
    security_opt:
      - no-new-privileges:true

    cap_drop:
      - ALL

    cap_add:
      - NET_BIND_SERVICE  # Only if needed

    read_only: true

    tmpfs:
      - /tmp
      - /var/run

  db:
    image: postgres:15

    # ✅ CORRECT: No ports exposed to host
    # Only accessible via internal network

    networks:
      - internal

    volumes:
      # ✅ CORRECT: Only mount workspace subdirs
      - ./data:/var/lib/postgresql/data

      # ❌ WRONG: System directory mounts
      # - /etc:/host-etc

    environment:
      POSTGRES_PASSWORD: dev-password

networks:
  internal:
    driver: bridge
    internal: true  # No external connectivity
    ipam:
      config:
        - subnet: 172.30.1.0/24

# Optional: External network (restricted)
  external:
    driver: bridge
    ipam:
      config:
        - subnet: 172.30.2.0/24
```

---

## Complete Implementation Script

```bash
#!/bin/bash
# /usr/local/bin/setup-k3s-compose-security

set -euo pipefail

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║   k3s and Docker Compose Firewall Protection Setup            ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# ============================================================================
# 1. k3s Firewall Rules
# ============================================================================

echo "[1/5] Creating k3s firewall script..."

cat > /usr/local/bin/k3s-firewall-fix <<'EOF'
#!/bin/bash
set -euo pipefail

# Create K3S-FIREWALL chain
iptables -N K3S-FIREWALL 2>/dev/null || iptables -F K3S-FIREWALL

# Block production networks
BLOCKED_NETWORKS=(
  "10.0.1.0/24"      # CUSTOMIZE!
  "192.168.1.0/24"   # CUSTOMIZE!
)

for network in "${BLOCKED_NETWORKS[@]}"; do
  iptables -I K3S-FIREWALL -s "$network" -j DROP
  iptables -I K3S-FIREWALL -d "$network" -j DROP
  echo "  Blocked k3s traffic to/from: $network"
done

iptables -A K3S-FIREWALL -m limit --limit 5/min -j LOG --log-prefix "K3S-BLOCKED: "

# Insert into FORWARD and INPUT chains
iptables -I FORWARD -j K3S-FIREWALL 2>/dev/null || true
iptables -I INPUT -j K3S-FIREWALL 2>/dev/null || true

echo "✅ k3s firewall rules applied"
EOF

chmod +x /usr/local/bin/k3s-firewall-fix
echo "✅ k3s firewall script created"

# ============================================================================
# 2. docker-compose Validation Wrapper
# ============================================================================

echo ""
echo "[2/5] Creating docker-compose validation wrapper..."

cat > /usr/local/bin/docker-compose-safe <<'EOF'
#!/bin/bash
set -euo pipefail

COMPOSE_FILE="${1:-docker-compose.yml}"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "ERROR: Compose file not found: $COMPOSE_FILE" >&2
  exit 1
fi

echo "🔍 Validating $COMPOSE_FILE..."

# Check for host network mode
if grep -q "network_mode.*host" "$COMPOSE_FILE"; then
  echo "❌ ERROR: network_mode: host is not allowed" >&2
  exit 1
fi

# Check for privileged containers
if grep -q "privileged.*true" "$COMPOSE_FILE"; then
  echo "❌ ERROR: privileged: true is not allowed" >&2
  exit 1
fi

# Check for port bindings without localhost
if grep -E "ports:.*\"[0-9]+:[0-9]+" "$COMPOSE_FILE" | grep -qv "127.0.0.1"; then
  echo "⚠️  WARNING: Port binding without localhost detected" >&2
  grep -E "ports:" "$COMPOSE_FILE" >&2
  echo "   Recommended: \"127.0.0.1:8080:80\"" >&2

  read -p "Continue? [y/N] " -n 1 -r
  echo
  [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# Check for sensitive volume mounts
if grep -E "volumes:.*/(etc|root|sys|proc)" "$COMPOSE_FILE"; then
  echo "❌ ERROR: Mount to sensitive directory detected" >&2
  exit 1
fi

echo "✅ Validation passed"

# Run docker-compose
exec docker-compose -f "$COMPOSE_FILE" "${@:2}"
EOF

chmod +x /usr/local/bin/docker-compose-safe
echo "✅ docker-compose wrapper created"

# ============================================================================
# 3. Secure Compose Template
# ============================================================================

echo ""
echo "[3/5] Creating secure docker-compose template..."

mkdir -p /usr/local/share/ralph

cat > /usr/local/share/ralph/docker-compose.template.yml <<'EOF'
version: '3.8'

# SECURE TEMPLATE - Use this as a base for Ralph projects
# Key security features:
# - Ports bind to 127.0.0.1 only
# - Internal networks by default
# - No privileged containers
# - Dropped capabilities

services:
  app:
    image: nginx:alpine
    ports:
      - "127.0.0.1:8080:80"  # Localhost only!
    networks:
      - internal
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /tmp
      - /var/cache/nginx

networks:
  internal:
    driver: bridge
    internal: true
    ipam:
      config:
        - subnet: 172.30.1.0/24
EOF

echo "✅ Secure template created: /usr/local/share/ralph/docker-compose.template.yml"

# ============================================================================
# 4. Systemd Services for Persistence
# ============================================================================

echo ""
echo "[4/5] Creating systemd services..."

# k3s firewall service
cat > /etc/systemd/system/k3s-firewall.service <<'EOF'
[Unit]
Description=k3s Firewall Rules
After=network.target
Before=k3s.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/k3s-firewall-fix
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable k3s-firewall 2>/dev/null || true

echo "✅ k3s firewall service created"

# ============================================================================
# 5. Restrict k3s Installation (if not yet installed)
# ============================================================================

echo ""
echo "[5/5] k3s installation notes..."

if command -v k3s >/dev/null 2>&1; then
  echo "⚠️  k3s is already installed"
  echo "   Apply firewall rules manually: /usr/local/bin/k3s-firewall-fix"
else
  echo "ℹ️  When installing k3s, use secure options:"
  echo ""
  echo "  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=\"\\"
  echo "    --disable traefik \\"
  echo "    --disable servicelb \\"
  echo "    --cluster-cidr=172.30.0.0/16 \\"
  echo "    --service-cidr=172.31.0.0/16 \\"
  echo "    --write-kubeconfig-mode 644\" sh -"
  echo ""
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                  Setup Complete ✅                             ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Security Tools Created:"
echo "  ✅ /usr/local/bin/k3s-firewall-fix"
echo "  ✅ /usr/local/bin/docker-compose-safe"
echo "  ✅ /usr/local/share/ralph/docker-compose.template.yml"
echo "  ✅ k3s-firewall.service (systemd)"
echo ""
echo "Next Steps:"
echo ""
echo "1. Customize blocked networks:"
echo "   nano /usr/local/bin/k3s-firewall-fix"
echo ""
echo "2. Apply k3s firewall rules (if k3s installed):"
echo "   /usr/local/bin/k3s-firewall-fix"
echo ""
echo "3. Replace docker-compose with safe wrapper:"
echo "   ln -sf /usr/local/bin/docker-compose-safe /usr/local/bin/docker-compose"
echo "   # Or: alias docker-compose='docker-compose-safe'"
echo ""
echo "4. Use secure template for new projects:"
echo "   cp /usr/local/share/ralph/docker-compose.template.yml \\
echo "      /ralph-workspaces/project/docker-compose.yml"
echo ""
echo "5. Verify k3s firewall:"
echo "   iptables -L K3S-FIREWALL -n -v"
echo ""
echo "6. Test docker-compose validation:"
echo "   docker-compose-safe -f docker-compose.yml config"
echo ""
```

---

## Testing & Verification

### Test k3s Firewall

```bash
# Apply rules
/usr/local/bin/k3s-firewall-fix

# Check rules exist
iptables -L K3S-FIREWALL -n -v
iptables -L FORWARD | grep K3S-FIREWALL

# Deploy a test service
kubectl run nginx --image=nginx --port=80
kubectl expose pod nginx --type=NodePort --port=80

# Get NodePort
NODE_PORT=$(kubectl get svc nginx -o jsonpath='{.spec.ports[0].nodePort}')

# Test from production network (should be blocked)
curl http://ralph-vm:$NODE_PORT  # From 10.0.1.x

# Check logs
grep K3S-BLOCKED /var/log/syslog
```

### Test docker-compose Validation

```bash
# Test 1: Valid compose file
cat > test-good.yml <<EOF
version: '3'
services:
  web:
    image: nginx
    ports:
      - "127.0.0.1:8080:80"
EOF

docker-compose-safe -f test-good.yml config
# Should succeed

# Test 2: Invalid (host network)
cat > test-bad.yml <<EOF
version: '3'
services:
  web:
    image: nginx
    network_mode: host
EOF

docker-compose-safe -f test-bad.yml config
# Should fail with error

# Test 3: Invalid (privileged)
cat > test-bad2.yml <<EOF
version: '3'
services:
  web:
    image: nginx
    privileged: true
EOF

docker-compose-safe -f test-bad2.yml config
# Should fail with error

# Test 4: Warning (unbound port)
cat > test-warn.yml <<EOF
version: '3'
services:
  web:
    image: nginx
    ports:
      - "8080:80"  # Binds to 0.0.0.0
EOF

docker-compose-safe -f test-warn.yml config
# Should warn and prompt
```

---

## Monitoring

### Watch for k3s Bypass Attempts

```bash
# Real-time monitoring
journalctl -kf | grep K3S-BLOCKED

# Recent blocks
grep K3S-BLOCKED /var/log/syslog | tail -20

# Count by source
grep K3S-BLOCKED /var/log/syslog | \
  grep -oP 'SRC=\K[\d.]+' | \
  sort | uniq -c | sort -rn
```

### Audit docker-compose Usage

```bash
# Log all docker-compose commands
cat > /etc/profile.d/audit-compose.sh <<'EOF'
if [[ $(id -u) -eq $(id -u ralph) ]]; then
  docker-compose() {
    echo "[$(date)] docker-compose $*" >> /var/log/ralph-compose.log
    command docker-compose "$@"
  }
fi
EOF
```

---

## Integration with setup-security.sh

Add to the main security setup script:

```bash
# After Docker firewall setup, add:

echo ""
echo "Step 4c: k3s and Docker Compose Protection"
echo "─────────────────────────────────────────"

# Run the k3s/compose security setup
if [[ -f /usr/local/bin/setup-k3s-compose-security ]]; then
  /usr/local/bin/setup-k3s-compose-security
else
  warn "k3s/compose security script not found"
  warn "Download from: docs/K3S_COMPOSE_FIREWALL_FIX.md"
fi
```

---

## Prevention Checklist

- [ ] k3s firewall rules applied (`/usr/local/bin/k3s-firewall-fix`)
- [ ] K3S-FIREWALL chain in FORWARD and INPUT
- [ ] docker-compose wrapper created (`docker-compose-safe`)
- [ ] Secure compose template available
- [ ] k3s installed with restricted CIDRs (if applicable)
- [ ] NetworkPolicies applied in k3s (if applicable)
- [ ] Monitoring in place for K3S-BLOCKED
- [ ] docker-compose audit logging enabled
- [ ] Tested blocking from production network
- [ ] Rules persist after reboot

---

## Summary

**k3s Protection:**
- K3S-FIREWALL chain blocks before k3s rules
- Restricted CIDRs during installation
- NetworkPolicies for pod-level restrictions
- Monitoring for bypass attempts

**docker-compose Protection:**
- Validation wrapper prevents dangerous configurations
- Secure template enforces best practices
- Localhost binding enforcement
- Audit logging of all compose operations

**Result:** Ralph cannot use k3s or docker-compose to bypass network isolation.
