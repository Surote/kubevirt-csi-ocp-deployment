#!/usr/bin/env bash
# Prove the guest can provision, attach, write, expand, snapshot and release a
# volume backed by the underlay's lvms-vg1. Cleans up after itself.
set -euo pipefail
cd "$(dirname "$0")/.."
INFRA=${INFRA:-ocp-sno}; GUEST=${GUEST:-ocp-vm-sno}; INFRA_NS=${INFRA_NS:-swongpai-virt}
U="oc --context $INFRA"; G="oc --context $GUEST"; NS=kubevirt-csi-verify
pass() { echo "PASS: $*"; }; fail() { echo "FAIL: $*"; exit 1; }
cleanup() { $G delete ns "$NS" --ignore-not-found --wait=false >/dev/null; }
trap cleanup EXIT

$G create ns "$NS" --dry-run=client -o yaml | $G apply -f - >/dev/null
$G apply -n "$NS" -f - <<'Y'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: fs}
spec:
  storageClassName: kubevirt
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: blk}
spec:
  storageClassName: kubevirt
  volumeMode: Block
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: writer}
spec:
  nodeSelector: {node-role.kubernetes.io/worker: ""}
  containers:
  - name: c
    image: registry.access.redhat.com/ubi9/ubi-minimal
    command: [sh, -c, "echo hello-from-underlay > /data/f && sync && sleep infinity"]
    volumeMounts: [{name: fs, mountPath: /data}]
    volumeDevices: [{name: blk, devicePath: /dev/xblk}]
  volumes:
  - {name: fs, persistentVolumeClaim: {claimName: fs}}
  - {name: blk, persistentVolumeClaim: {claimName: blk}}
Y
$G wait -n "$NS" pod/writer --for=condition=Ready --timeout=5m || fail "pod never Ready"
pass "PVCs bound and pod running: $($G get pvc -n "$NS" --no-headers | awk '{print $1"="$2}' | xargs)"

node=$($G get pod writer -n "$NS" -o jsonpath='{.spec.nodeName}')
vm=$($G get node "$node" -o jsonpath='{.metadata.annotations.csi\.kubevirt\.io/infra-vm-name}')
for c in fs blk; do
  pv=$($G get pvc "$c" -n "$NS" -o jsonpath='{.spec.volumeName}')
  dv=$($G get pv "$pv" -o jsonpath='{.spec.csi.volumeHandle}')
  $U get dv "$dv" -n "$INFRA_NS" -o jsonpath='{.spec.storage.storageClassName}{"\n"}' | grep -qx lvms-vg1 \
    || fail "$c: underlay DV $dv missing or not on lvms-vg1"
  $U get vm "$vm" -n "$INFRA_NS" -o json | jq -e --arg d "$dv" \
    '.spec.template.spec.volumes[] | select(.name==$d)' >/dev/null || fail "$c: $dv not hot-plugged into VM $vm"
  pass "$c -> underlay DV $INFRA_NS/$dv on lvms-vg1, hot-plugged into VM $vm"
done
[ "$($G exec -n "$NS" writer -- cat /data/f)" = hello-from-underlay ] && pass "filesystem read-back" || fail "read-back"
$G exec -n "$NS" writer -- sh -c 'test -b /dev/xblk' && pass "block device present" || fail "no block device"

$G patch pvc fs -n "$NS" --type=merge -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}' >/dev/null
for _ in $(seq 60); do
  [ "$($G get pvc fs -n "$NS" -o jsonpath='{.status.capacity.storage}')" = 2Gi ] && break; sleep 5; done
[ "$($G get pvc fs -n "$NS" -o jsonpath='{.status.capacity.storage}')" = 2Gi ] && pass "expanded to 2Gi" || fail "expansion"

$G apply -n "$NS" -f - <<'Y' >/dev/null
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata: {name: fs-snap}
spec: {volumeSnapshotClassName: kubevirt-csi-snapclass, source: {persistentVolumeClaimName: fs}}
Y
$G wait -n "$NS" volumesnapshot/fs-snap --for=jsonpath='{.status.readyToUse}'=true --timeout=5m \
  && pass "snapshot readyToUse" || fail "snapshot"

dvs=$($G get pv -o json | jq -r --arg ns "$NS" '.items[] | select(.spec.claimRef.namespace==$ns) | .spec.csi.volumeHandle')
$G delete ns "$NS" --wait=true --timeout=5m >/dev/null; trap - EXIT
for _ in $(seq 60); do
  left=$(for d in $dvs; do $U get dv "$d" -n "$INFRA_NS" --ignore-not-found -o name; done)
  [ -z "$left" ] && break; sleep 5; done
[ -z "$left" ] && pass "underlay DVs deleted and unplugged after cleanup" || fail "leftover on underlay: $left"
