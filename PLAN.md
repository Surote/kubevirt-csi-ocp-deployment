# KubeVirt CSI: guest PVCs on the underlay's lvms-vg1

## Goal

A PVC on the guest cluster `ocp-vm-sno` with `storageClassName: kubevirt` becomes a DataVolume on `lvms-vg1` in `swongpai-virt` on the underlay `ocp-sno`. That DataVolume is hot-plugged into the guest node VM where the pod runs.

```
guest PVC (sc: kubevirt) ──► kubevirt-csi-controller (guest, holds infra kubeconfig)
                               │ creates DV in swongpai-virt (lvms-vg1, Block RWO)
                               │ addvolume on VM worker-N
                               ▼
                    virt-launcher hot-plugs a SCSI disk (serial = DV UID)
                               ▼
kubevirt-csi-node (guest DaemonSet) finds the disk by serial, formats, mounts
```

## What the clusters have (measured 2026-11-23, read-only)

| | `ocp-sno` (underlay) | `ocp-vm-sno` (guest) |
| --- | --- | --- |
| Version | 4.22.21, SNO, node `master` | 5.0.1, 3 masters + 3 workers, platform `None` |
| Virt | OpenShift Virtualization 4.22.16, feature gate `DeclarativeHotplugVolumes` (not `HotplugVolumes`) | n/a |
| Storage | `lvms-vg1` default, WFFC, thin pool, StorageProfile Block RWO first. VolumeSnapshotClass `lvms-vg1`, none marked default | `nfs-csi` default. CSI snapshot controller and CRDs already installed |
| Guest VMs | `swongpai-virt/{master,worker}-{0,1,2}`, CD-ROM already a hotplug PVC, so hotplug works here | nodes have no `providerID` and no CSI annotations |
| Identity | VMI `firmware.uuid` == guest node `systemUUID` for all 6 nodes | |
| API TLS | serving cert signed by `kube-apiserver-lb-signer`, which the SA `ca.crt` verifies | |

## Decisions and why

1. **Upstream `kubevirt/csi-driver`, pinned.** Red Hat ships this driver only inside Hosted Control Planes on KubeVirt. On an Assisted-installed cluster it is community software with no Red Hat support. Upstream has no releases, so the manifests are pinned to commit `b7b6b9aa` and the image to digest `sha256:44c98353…`.
2. **Split deployment.** The controller runs in the guest and reaches the underlay with a kubeconfig. The underlay gets only a ServiceAccount and a Role scoped to `swongpai-virt`. Nothing is installed in `openshift-cnv`.
3. **Node identity from annotations.** The driver resolves a node's VM from `providerID: kubevirt://` or from `csi.kubevirt.io/infra-vm-name` and `csi.kubevirt.io/infra-vm-namespace`. These nodes have no providerID, so `install.sh` annotates them by matching SMBIOS UUID, not by trimming names.
4. **`--enable-vmi-hotplug-fallback=false`.** This is required with `DeclarativeHotplugVolumes`. Without it, unplug falls back to a VMI call that virt-api rejects.
5. **`lvms-vg1` (Block).** The driver does not wait for the DV to bind, so WFFC is fine. Block avoids a filesystem-in-file layer. The allowList holds only `lvms-vg1`, so a guest admin cannot pick other underlay classes.
6. **The guest default stays `nfs-csi`.** The new `kubevirt` class is opt-in. To flip the default, see step 6.
7. **Skip the upstream snapshot CRDs and controller.** OpenShift already ships them.
8. **Two kustomizations.** Upstream `tenant/base` and `controller-tenant/base` both define `ClusterRoleBinding/csi-snapshotter-role` with different subjects. The controller's copy is renamed to `kubevirt-csi-controller-snapshotter`, so reruns don't flip it.

## Files

```
infra/rbac.yaml                 underlay: SA kubevirt-csi, token Secret, Role/RoleBinding in swongpai-virt, PV get
tenant/common/                  guest: Namespace, CSIDriver, node DaemonSet, RBAC, driver-config, StorageClass, VolumeSnapshotClass
tenant/controller/              guest: controller Deployment (+hotplug flag), renamed snapshotter binding
bin/install.sh                  steps 0-5, rerunnable
bin/verify.sh                   end-to-end proof, cleans up
```

Already checked without changing either cluster:
- [x] Both kustomizations render offline, with no duplicate object ids
- [x] Server-side dry-run passes for every cluster-scoped object on both clusters (namespaced objects only fail because the namespace is absent in a dry run)
- [x] The node → VM mapping resolves for all 6 nodes
- [x] The underlay API cert verifies against the SA CA from this bastion
- [x] Both scripts pass `bash -n`

## Steps

Run from this folder. `bin/install.sh` does steps 0 to 5. The commands below are what it runs.

### 0. Preflight: guest nodes reach the underlay API

The guest nodes sit on 172.16.25.0/24 and the underlay API is 172.16.4.101. This bastion reaches it. The guest nodes are unproven.

```bash
oc --context ocp-vm-sno debug node/worker-0.lab.rhdemo.local -q -- chroot /host \
  curl -sk -o /dev/null -w '%{http_code}\n' https://api.ocpcluster.yumtech.info:6443/version   # expect 200
```

- [ ] Prints `200`. If not, fix routing or firewall from 172.16.25.0/24 to 172.16.4.101:6443 first.

### 1. Underlay: identity

```bash
oc --context ocp-sno apply -f infra/rbac.yaml
```

- [ ] `oc --context ocp-sno auth can-i update virtualmachines/addvolume -n swongpai-virt --as system:serviceaccount:swongpai-virt:kubevirt-csi --subresource` → `yes`
- [ ] Same check with `create datavolumes.cdi.kubevirt.io` → `yes`. With `-n default` → `no`.

### 2. Guest: annotate nodes

```bash
oc --context ocp-vm-sno annotate node worker-0.lab.rhdemo.local --overwrite \
  csi.kubevirt.io/infra-vm-name=worker-0 csi.kubevirt.io/infra-vm-namespace=swongpai-virt
# ...same for master-0..2, worker-1..2 (the script matches by systemUUID)
```

- [ ] `oc --context ocp-vm-sno get nodes -o custom-columns=N:.metadata.name,VM:.metadata.annotations.csi\.kubevirt\.io/infra-vm-name` shows all 6.

### 3. Guest: infra kubeconfig secret

The script builds a kubeconfig from the token Secret's `token` and `ca.crt` and the server `https://api.ocpcluster.yumtech.info:6443`. It stores it as `kubevirt-csi-driver/infra-cluster-credentials`, key `kubeconfig`.

- [ ] `oc --context ocp-vm-sno get secret infra-cluster-credentials -n kubevirt-csi-driver` exists.

### 4. Guest: driver and controller

```bash
oc --context ocp-vm-sno apply -k tenant/common
oc --context ocp-vm-sno apply -k tenant/controller
```

- [ ] `oc --context ocp-vm-sno get pods -n kubevirt-csi-driver` shows 6 node pods and 1 controller pod, all Running.
- [ ] Node pod log has `Node name: "worker-0.lab.rhdemo.local", Node ID: "swongpai-virt/worker-0"`.

### 5. Guest: driver registered on every node

- [ ] `oc --context ocp-vm-sno get csinode -o json | jq '[.items[]|select(any(.spec.drivers[]?;.name=="csi.kubevirt.io"))]|length'` → `6`

### 6. Prove it: `bin/verify.sh`

It runs two PVCs (filesystem and Block) under one pod on a worker and checks:
- [ ] both PVCs Bound, pod Ready
- [ ] each PV's volumeHandle is a DV in `swongpai-virt` with `storageClassName: lvms-vg1`
- [ ] that DV appears in the backing VM's `spec.template.spec.volumes` (hot-plugged)
- [ ] the file reads back, and `/dev/xblk` is a block device
- [ ] the PVC expands from 1Gi to 2Gi (underlay `ExpandDisks` gate is on)
- [ ] the VolumeSnapshot reaches `readyToUse` through `lvms-vg1` snapshots
- [ ] after namespace delete, the underlay DVs are gone (unplugged and deleted)

Optional, after it passes. To make `kubevirt` the guest default:

```bash
oc --context ocp-vm-sno annotate sc nfs-csi storageclass.kubernetes.io/is-default-class=false --overwrite
oc --context ocp-vm-sno annotate sc kubevirt storageclass.kubernetes.io/is-default-class=true --overwrite
```

## Rollback

```bash
oc --context ocp-vm-sno get pvc -A -o json | jq -r '.items[]|select(.spec.storageClassName=="kubevirt")|"\(.metadata.namespace)/\(.metadata.name)"'  # must be empty
oc --context ocp-vm-sno delete -k tenant/controller; oc --context ocp-vm-sno delete -k tenant/common
oc --context ocp-vm-sno annotate nodes --all csi.kubevirt.io/infra-vm-name- csi.kubevirt.io/infra-vm-namespace-
oc --context ocp-sno delete -f infra/rbac.yaml
oc --context ocp-sno get dv -n swongpai-virt -l csi-driver/cluster=ocp-vm-sno   # must be empty
```

## Limits to know

- **RWO only.** `lvms-vg1` is single-node, so `ReadWriteMany` PVCs on `kubevirt` fail. Keep `nfs-csi` for RWX.
- **Shared thin pool.** Every guest PVC takes space from the same thin pool (overprovision ratio 10) as the other ~30 VMs on this SNO. Watch the thin pool's data usage on the underlay.
- **Stopping a guest node VM detaches its volumes.** The hot-plugged disks belong to that VM, so pods on it lose storage until it returns.
- **The token Secret is long-lived.** Rotate it by deleting `kubevirt-csi-token` on the underlay and rerunning `bin/install.sh`.

## Still unproven

- Guest node → underlay API reachability (step 0).
- The pinned `latest` image against 4.22 CNV with `DeclarativeHotplugVolumes`. The code path supports it, but no run has exercised it here. `verify.sh` is the test.
- Whether the guest's RHCOS 10 kernel sees hot-plugged SCSI disks without a manual rescan. The driver rescans, and `verify.sh` will show it.
