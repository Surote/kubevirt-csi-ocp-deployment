#!/usr/bin/env bash
# Connect the guest cluster (ocp-vm-sno) to the underlay's lvms-vg1 StorageClass
# (ocp-sno) through the KubeVirt CSI driver. Safe to rerun: every step applies
# the desired state and changes nothing when it already holds.
set -euo pipefail
cd "$(dirname "$0")/.."

INFRA=${INFRA:-ocp-sno}
GUEST=${GUEST:-ocp-vm-sno}
INFRA_NS=${INFRA_NS:-swongpai-virt}
CSI_NS=kubevirt-csi-driver
U="oc --context $INFRA"
G="oc --context $GUEST"

step() { printf '\n=== %s\n' "$*"; }

step "0. preflight: guest nodes reach the underlay API"
server=$($U config view --minify -o jsonpath='{.clusters[0].cluster.server}')
node=$($G get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}')
$G debug "node/$node" -q -- chroot /host curl -sk -o /dev/null -w '%{http_code}\n' "$server/version" \
  | grep -qx 200 || { echo "guest node $node cannot reach $server"; exit 1; }
echo "ok: $node -> $server"

step "1. underlay: service account, RBAC, token ($INFRA)"
$U apply -f infra/rbac.yaml
for _ in $(seq 30); do
  token=$($U get secret kubevirt-csi-token -n "$INFRA_NS" -o jsonpath='{.data.token}' | base64 -d)
  [ -n "$token" ] && break; sleep 2
done
[ -n "$token" ] || { echo "token never populated"; exit 1; }
ca=$($U get secret kubevirt-csi-token -n "$INFRA_NS" -o jsonpath='{.data.ca\.crt}')

step "2. guest: annotate each node with the VM that backs it"
# Match on SMBIOS UUID: guest node .status.nodeInfo.systemUUID == VMI .spec.domain.firmware.uuid.
# Names alone differ (worker-0.lab.rhdemo.local vs worker-0).
declare -A vm_by_uuid
while read -r uuid vm; do vm_by_uuid[$uuid]=$vm; done < <(
  $U get vmi -n "$INFRA_NS" -o jsonpath='{range .items[*]}{.spec.domain.firmware.uuid}{" "}{.metadata.name}{"\n"}{end}')
while read -r n uuid; do
  vm=${vm_by_uuid[$uuid]:-}
  [ -n "$vm" ] || { echo "no VMI in $INFRA_NS has firmware uuid $uuid (node $n)"; exit 1; }
  $G annotate node "$n" --overwrite \
    csi.kubevirt.io/infra-vm-name="$vm" csi.kubevirt.io/infra-vm-namespace="$INFRA_NS"
done < <($G get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.nodeInfo.systemUUID}{"\n"}{end}')

step "3. guest: namespace and infra kubeconfig secret"
$G apply -f tenant/common/namespace.yaml
kc=$(mktemp); trap 'rm -f "$kc"' EXIT
cat > "$kc" <<KC
apiVersion: v1
kind: Config
clusters:
- name: infra
  cluster:
    server: $server
    certificate-authority-data: $ca
users:
- name: kubevirt-csi
  user:
    token: $token
contexts:
- name: infra
  context: {cluster: infra, user: kubevirt-csi, namespace: $INFRA_NS}
current-context: infra
KC
$G create secret generic infra-cluster-credentials -n "$CSI_NS" --from-file=kubeconfig="$kc" \
  --dry-run=client -o yaml | $G apply -f -

step "4. guest: driver (node DaemonSet, CSIDriver, StorageClass), then controller"
$G apply -k tenant/common
$G apply -k tenant/controller
# Pods read annotations and the secret only at start, so roll them after any change.
$G rollout restart ds/kubevirt-csi-node deploy/kubevirt-csi-controller -n "$CSI_NS"
$G rollout status ds/kubevirt-csi-node -n "$CSI_NS" --timeout=5m
$G rollout status deploy/kubevirt-csi-controller -n "$CSI_NS" --timeout=5m

step "5. guest: every node registered the driver"
want=$($G get nodes --no-headers | wc -l)
have=$($G get csinode -o json | jq '[.items[] | select(any(.spec.drivers[]?; .name=="csi.kubevirt.io"))] | length')
[ "$want" = "$have" ] || { echo "csi.kubevirt.io registered on $have of $want nodes"; exit 1; }
echo "ok: csi.kubevirt.io on $have/$want nodes. Next: bin/verify.sh"
