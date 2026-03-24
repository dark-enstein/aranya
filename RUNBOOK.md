# Aranya Cluster — Build Runbook

Reproduces the full cluster from scratch: Kubernetes via Kubespray, ArgoCD, ClusterDOS gitops, and the hello-aranya app.

---

## Nodes

| Name  | IP               | Role                      |
|-------|------------------|---------------------------|
| node1 | 134.199.193.57   | control-plane + etcd      |
| node2 | 134.199.205.61   | worker                    |
| node3 | 134.199.198.44   | worker                    |

---

## Prerequisites

On your control machine (laptop / jump host):

- `python3` and `pip3`
- `git`
- `kubectl`
- `jq`
- SSH private key with root access to all three nodes (repo ships one at `./nodes`)

---

## Step 0 — Clone the repo

```bash
git clone <this-repo-url>
cd aranya
```

---

## Step 1 — Verify SSH access

```bash
SSH_KEY=./nodes
for ip in 134.199.193.57 134.199.205.61 134.199.198.44; do
  ssh -q -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$SSH_KEY" root@"$ip" true \
    && echo "OK $ip" || echo "FAIL $ip"
done
```

All three must print `OK`. If any fail, check that the key is correct and the node is reachable.

---

## Step 2 — Install Kubespray

```bash
KUBESPRAY_DIR=/opt/kubespray

git clone --depth 1 https://github.com/kubernetes-sigs/kubespray "$KUBESPRAY_DIR"
cd "$KUBESPRAY_DIR"
pip3 install -q -r requirements.txt
```

---

## Step 3 — Copy inventory

```bash
REPO_DIR=<absolute path to aranya repo>
cp -rf "$REPO_DIR/working-inventory" "$KUBESPRAY_DIR/inventory/aranya"
```

The inventory is at [working-inventory/inventory.ini](working-inventory/inventory.ini).

---

## Step 4 — Provision the cluster

```bash
cd "$KUBESPRAY_DIR"

ansible-playbook -i inventory/aranya/inventory.ini \
  --become --become-user=root \
  --private-key "$REPO_DIR/nodes" \
  cluster.yml
```

This takes ~20 minutes. Kubespray will install Kubernetes with containerd on all three nodes.

---

## Step 5 — Fetch kubeconfig

```bash
ssh -i "$REPO_DIR/nodes" root@134.199.193.57 "cat /etc/kubernetes/admin.conf" > ~/.kube/config
chmod 600 ~/.kube/config

kubectl get nodes   # should show node1/node2/node3 Ready
```

---

## Step 6 — Install ArgoCD

```bash
ARGOCD_VERSION=v2.10.5

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"

kubectl rollout status deployment/argocd-server -n argocd --timeout=180s
```

Expose via NodePort and get the initial password:

```bash
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}'

ARGOCD_PORT=$(kubectl get svc -n argocd argocd-server -ojson \
  | jq -r '.spec.ports[] | select(.name=="https") | .nodePort')

ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

echo "ArgoCD: https://134.199.193.57:$ARGOCD_PORT"
echo "user: admin  pass: $ARGOCD_PASS"
```

---

## Step 7 — Install ClusterDOS

ClusterDOS is the gitops bootstrap layer. The install manifest is at [clusterdos-src/install.yaml](clusterdos-src/install.yaml).

It points ArgoCD at the `metadeployment/` Helm chart in the ClusterDOS repo and enables:

| GitApp       | Purpose                        |
|--------------|-------------------------------|
| certmanager  | TLS certificate management     |
| ksm          | kube-state-metrics             |
| nfd          | Node Feature Discovery         |
| traefik      | Ingress controller             |

```bash
kubectl apply -f "$REPO_DIR/clusterdos-src/install.yaml"
```

ArgoCD will now sync all enabled gitapps. Watch progress:

```bash
kubectl get applications -n argocd -w
```

Wait until all applications show `Synced / Healthy` before proceeding.

> **Note:** The `config` gitapp requires `clusterdos.clustername` and `clusterdos.ref` to be non-null — both are set to `ayo-interview` and `v0.3.7` in `install.yaml`. If you redeploy against a different ClusterDOS version, update both values.

---

## Step 8 — Deploy hello-aranya

```bash
kubectl apply -f "$REPO_DIR/deploy/namespace.yaml"
kubectl apply -f "$REPO_DIR/deploy/hello-aranya.yaml"

HELLO_PORT=$(kubectl get svc -n ayobami-app hello-aranya-np -ojson \
  | jq -r '.spec.ports[] | select(.name=="http") | .nodePort')

echo "hello-aranya: http://134.199.193.57:$HELLO_PORT"
```

The app runs 2 nginx replicas serving a static page. It also has an Ingress configured for `hello.aranya.example.com` — update the host in [deploy/hello-aranya.yaml](deploy/hello-aranya.yaml) to your real domain before applying if you want TLS via cert-manager.

---

## Step 9 — Automated bootstrap

All of the above is scripted in [setup.sh](setup.sh). Run it from the repo root:

```bash
SSH_KEY=./nodes bash setup.sh
```

---

## Teardown

To destroy and rebuild from scratch, simply reprovision the nodes (e.g. recreate them in your cloud provider) and re-run from Step 1. There is no persistent storage configured by default.

---

## Troubleshooting

**ArgoCD KSM sync fails with `repoURL`/`targetRevision` null**
The `config` gitapp is `internal: true` and inherits `clusterdos.ref` from `install.yaml`. Ensure `clusterdos.ref` and `clusterdos.clustername` are both set (non-null) in `clusterdos-src/install.yaml`.

**`kubemetrics` in ArgoCD shows missing / does nothing**
The gitapp is named `ksm`, not `kubemetrics`. Use `ksm: enabled: true` in `install.yaml`.

**SSH connectivity check fails**
Confirm the private key at `./nodes` matches the `authorized_keys` on each node. The key is an ed25519 key for `root`.
