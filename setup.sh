#!/usr/bin/env bash
# setup.sh — full cluster bootstrap from scratch
# Run from the repo root on the Ansible control node.
set -euo pipefail

CLUSTER_NAME="aranya-cluster"
MASTER_IP="134.199.193.57"
SSH_KEY="${SSH_KEY:-$REPO_DIR/nodes}"
ARGOCD_VERSION="v2.10.5"

log()  { echo -e "\033[1;36m[bootstrap]\033[0m $*"; }
die()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── 1. SSH connectivity check ──────────────────────────────────────────────────
log "Checking SSH connectivity to all nodes..."
for ip in 134.199.193.57 134.199.205.61 134.199.198.44; do
  ssh -q -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$SSH_KEY" root@"$ip" true \
    || die "Cannot reach root@$ip — check SSH keys"
done
log "All nodes reachable."

# ── 2. Add Christian's SSH keys to every node ──────────────────────────────────
log "Adding condaatje's GitHub SSH keys to all nodes..."
CHRISTIAN_KEYS=$(curl -fsSL https://github.com/condaatje.keys)
for ip in 134.199.193.57 134.199.205.61 134.199.198.44; do
  ssh -i "$SSH_KEY" root@"$ip" "
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    touch ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    while IFS= read -r key; do
      grep -qF \"\$key\" ~/.ssh/authorized_keys || echo \"\$key\" >> ~/.ssh/authorized_keys
    done <<'KEYS'
$CHRISTIAN_KEYS
KEYS
  "
  log "  Keys added to root@$ip"
done

# ── 3. Install Kubespray deps ──────────────────────────────────────────────────
log "Installing Kubespray requirements..."
command -v python3 >/dev/null || die "python3 not found"
command -v git     >/dev/null || die "git not found"

KUBESPRAY_DIR="${KUBESPRAY_DIR:-/opt/kubespray}"
if [ ! -d "$KUBESPRAY_DIR" ]; then
  git clone --depth 1 https://github.com/kubernetes-sigs/kubespray "$KUBESPRAY_DIR"
fi
cd "$KUBESPRAY_DIR"
pip3 install -q -r requirements.txt

# ── 4. Copy inventory ─────────────────────────────────────────────────────────
log "Copying inventory into Kubespray..."
cp -rf "$REPO_DIR/working-inventory" "$KUBESPRAY_DIR/inventory/aranya"

# ── 5. Run Kubespray ──────────────────────────────────────────────────────────
log "Running Kubespray cluster.yml (this takes ~20 min)..."
ansible-playbook -i inventory/aranya/inventory.ini \
  --become --become-user=root \
  --private-key "$SSH_KEY" \
  cluster.yml

# ── 6. Fetch kubeconfig ───────────────────────────────────────────────────────
log "Fetching kubeconfig from master..."
mkdir -p ~/.kube
ssh -i "$SSH_KEY" root@"$MASTER_IP" "cat /etc/kubernetes/admin.conf" > ~/.kube/config
chmod 600 ~/.kube/config
log "kubeconfig written to ~/.kube/config"

# ── 7. Install ArgoCD ─────────────────────────────────────────────────────────
log "Installing ArgoCD $ARGOCD_VERSION..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"

log "Waiting for ArgoCD server to be ready (up to 3 min)..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=180s

kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}'
ARGOCD_PORT=$(kubectl get svc -n argocd argocd-server -ojson | jq -r '.spec.ports[] | select(.name=="https") | .nodePort')
log "ArgoCD NodePort: $ARGOCD_PORT"

# ── 8. Install ClusterDOS ─────────────────────────────────────────────────────
log "Installing ClusterDOS + GitApps..."
kubectl apply -f "$REPO_DIR/clusterdos-src/install.yaml"

# ── 9. Deploy hello-aranya ────────────────────────────────────────────────────
log "Deploying hello-aranya..."
kubectl apply -f "$REPO_DIR/deploy/namespace.yaml"
kubectl apply -f "$REPO_DIR/deploy/hello-aranya.yaml"
HELLO_PORT=$(kubectl get svc -n ayobami-app hello-aranya-np -ojson | jq -r '.spec.ports[] | select(.name=="http") | .nodePort')
log "hello-aranya NodePort: $HELLO_PORT"

# ── 10. Print summary ─────────────────────────────────────────────────────────
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d 2>/dev/null || echo "<not yet available>")

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Cluster: $CLUSTER_NAME"
echo "  ArgoCD:  https://$MASTER_IP:$ARGOCD_PORT"
echo "           user: admin  pass: $ARGOCD_PASS"
echo "  hello-aranya: http://$MASTER_IP:$HELLO_PORT"
echo "  hello-aranya ingress host: hello.aranya-cluster.local"
echo "  Point your DNS / /etc/hosts at any worker IP (134.199.205.61, 134.199.198.44)"
echo "═══════════════════════════════════════════════════════"
