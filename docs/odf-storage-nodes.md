# Adding ODF Storage Nodes (Day 2)

Add dedicated OpenShift Data Foundation storage nodes to a cluster that is already running, each with an extra raw EBS volume for ODF to consume.

This uses `oc adm node-image create` rather than `openshift-install`. The running cluster generates the node ISO, so there is no need to regenerate the original agent ISO or keep the installer state around. The ISO is then converted to an AMI exactly as in the initial deployment.

The one EC2-specific wrinkle is **when** the ODF data volume gets attached — see [Why the data volume is attached late](#why-the-data-volume-is-attached-late). It is the whole reason this needs its own guide.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                         AWS VPC (10.0.0.0/16)                            │
│                                                                          │
│   ┌──────────────────────────────────────────────────────────────────┐   │
│   │                    Subnet (10.0.1.0/24)                          │   │
│   │                                                                  │   │
│   │   ┌──────────┐  ┌──────────┐  ┌──────────┐   existing           │   │
│   │   │ master-0 │  │ master-1 │  │ master-2 │   control plane      │   │
│   │   │ .101     │  │ .102     │  │ .103     │                      │   │
│   │   └──────────┘  └──────────┘  └──────────┘                      │   │
│   │                                                                  │   │
│   │   ┌──────────┐  ┌──────────┐  ┌──────────┐   existing compute   │   │
│   │   │ worker-0 │  │ worker-1 │  │ worker-2 │   (in ingress TGs)   │   │
│   │   │ .111     │  │ .112     │  │ .113     │                      │   │
│   │   └──────────┘  └──────────┘  └──────────┘                      │   │
│   │                                                                  │   │
│   │   ┌──────────┐  ┌──────────┐  ┌──────────┐   NEW storage nodes  │   │
│   │   │  odf-0   │  │  odf-1   │  │  odf-2   │   labelled + tainted │   │
│   │   │ .121     │  │ .122     │  │ .123     │   (not in ingress)   │   │
│   │   ├──────────┤  ├──────────┤  ├──────────┤                      │   │
│   │   │ 16G  ISO │  │ 16G  ISO │  │ 16G  ISO │   nvme0n1  iso9660   │   │
│   │   │ 120G RHCOS│ │ 120G RHCOS│ │ 120G RHCOS│  nvme1n1  root      │   │
│   │   │ 120G RAW │  │ 120G RAW │  │ 120G RAW │   nvme2n1  ← ODF     │   │
│   │   └──────────┘  └──────────┘  └──────────┘                      │   │
│   └──────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

| Requirement | Details |
|-------------|---------|
| A running cluster | Deployed with [`deploy-multi-node.sh`](../scripts/deploy-multi-node.sh) |
| `resource-ids.env` | From that deployment — supplies `SUBNET_ID`, `SG_ID`, `KEY_NAME`, `BUCKET_NAME` |
| `oc` | Must match the cluster version; `oc adm node-image` requires 4.17+ |
| `qemu-img`, `jq`, `nmstatectl` | Same local tooling as the initial deployment |
| AWS CLI v2 | EC2, S3, IAM permissions (see the main [README](../README.md)) |
| vCPU headroom | 3 × `m5.2xlarge` = 24 additional vCPUs |

## Instance Sizing

ODF is resource-hungry. Red Hat's documented recommendation for internal mode is 16 vCPU and 64 GiB per storage node.

| Type | vCPU / RAM | Verdict |
|------|-----------|---------|
| `m5.xlarge` | 4 / 16 GiB | Below requirements. OSD, MON and MGR pods will contend; expect scheduling pressure |
| `m5.2xlarge` | 8 / 32 GiB | Pragmatic minimum for a working non-production install. Script default |
| `m5.4xlarge` | 16 / 64 GiB | Matches the Red Hat recommendation |

## Automated Deployment

```bash
export INSTALL_DIR=~/ocp-agent-aws
export AWS_REGION=us-east-2
./scripts/add-odf-nodes.sh
```

Takes roughly 35–45 minutes, most of it the EBS snapshot import. Overridable settings:

| Variable | Default | Purpose |
|----------|---------|---------|
| `NODE_COUNT` | `3` | Number of storage nodes |
| `HOSTNAME_PREFIX` | `odf` | Node names become `odf-0`, `odf-1`, … |
| `INSTANCE_TYPE` | `m5.2xlarge` | See sizing table above |
| `ODF_DISK_SIZE` | `120` | GB, raw data disk per node |
| `IP_START` | `121` | First host octet, keeping storage nodes clear of `.111-.113` |
| `DEDICATED` | `true` | Label + `NoSchedule` taint, and skip the ingress target groups |

Setting `DEDICATED=false` makes them general-purpose workers that also run ODF: the storage label is still applied, but no taint, and they are registered in the ingress target groups like the existing workers.

## Step-by-Step Guide

### Step 1 — Pre-create ENIs

Exactly as in the initial deployment: the agent matches hosts by MAC address, and EC2 assigns MACs at launch, so the ENIs must exist before the ISO is generated.

```bash
source ~/ocp-agent-aws/resource-ids.env

for i in 0 1 2; do
  IP="10.0.1.12$((i+1))"
  ENI=$(aws ec2 create-network-interface \
    --subnet-id ${SUBNET_ID} --groups ${SG_ID} --private-ip-address ${IP} \
    --description "OCP odf-${i}" \
    --query 'NetworkInterface.NetworkInterfaceId' --output text)
  MAC=$(aws ec2 describe-network-interfaces --network-interface-ids ${ENI} \
    --query 'NetworkInterfaces[0].MacAddress' --output text)
  echo "odf-${i} ${IP} ${ENI} ${MAC}"
done
```

### Step 2 — Write nodes-config.yaml

See [`examples/odf-nodes/nodes-config.yaml`](../examples/odf-nodes/nodes-config.yaml) for the annotated version. One `hosts` entry per node, carrying the MAC from step 1 and `rootDeviceHints.minSizeGigabytes: 100`.

There is no pull secret or SSH key in this file — both are inherited from the cluster.

> The `--root-device-hint` *flag* passes its value as a string rather than an integer, so it cannot be used for `minSizeGigabytes`. Use the config file on EC2.

### Step 3 — Generate the node ISO

```bash
cd ~/ocp-agent-aws/odf
oc adm node-image create --dir=. -o=node.x86_64.iso
```

This creates a pod in a temporary namespace that pulls the release payload and assembles a customised ISO — about 5–8 minutes. On failure it writes a `report.json` with the error detail.

### Step 4 — Convert the ISO to an AMI

Identical to the initial deployment, with one critical difference: **register the AMI with only two block devices.**

```bash
qemu-img convert -f raw -O raw node.x86_64.iso node.x86_64.raw
aws s3 cp node.x86_64.raw s3://${BUCKET_NAME}/node-odf.x86_64.raw

IMPORT_TASK=$(aws ec2 import-snapshot \
  --description "ODF node image" \
  --disk-container "{\"Format\":\"RAW\",\"UserBucket\":{
    \"S3Bucket\":\"${BUCKET_NAME}\",\"S3Key\":\"node-odf.x86_64.raw\"}}" \
  --query 'ImportTaskId' --output text)

# poll describe-import-snapshot-tasks until completed, then:
AMI_ID=$(aws ec2 register-image \
  --name "ocp-odf-$(date +%Y%m%d%H%M)" \
  --architecture x86_64 --root-device-name /dev/sda1 \
  --boot-mode uefi-preferred --ena-support --virtualization-type hvm \
  --block-device-mappings "[
    {\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"SnapshotId\":\"${SNAP_ID}\",
      \"VolumeSize\":16,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}},
    {\"DeviceName\":\"/dev/sdb\",\"Ebs\":{\"VolumeSize\":120,
      \"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}
  ]" --query 'ImageId' --output text)
```

If `cleanup.sh` has already removed the original deployment bucket, create a new one and re-apply the `vmimport` role policy against it — that policy is scoped to a specific bucket ARN.

### Step 5 — Launch the instances

```bash
aws ec2 run-instances --image-id ${AMI_ID} --instance-type m5.2xlarge \
  --key-name ${KEY_NAME} \
  --network-interfaces "DeviceIndex=0,NetworkInterfaceId=${ENI_ID}" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=ocp-odf-0}]"
```

### Step 6 — Approve CSRs

Each node needs **two** approvals: the kubelet client certificate, requested by `system:serviceaccount:openshift-machine-config-operator:node-bootstrapper`, and then the kubelet serving certificate requested by `system:node:<hostname>`. They arrive about a minute apart, roughly 7–8 minutes after launch.

```bash
oc get csr | grep Pending
oc get csr -o name | xargs oc adm certificate approve
```

Keep watching after the first batch — the serving certificate requests only appear once the nodes have registered.

```bash
oc adm node-image monitor --ip-addresses 10.0.1.121,10.0.1.122,10.0.1.123
```

### Step 7 — Create and attach the data volumes

Only once the nodes are `Ready`:

```bash
VOL=$(aws ec2 create-volume --availability-zone us-east-2a \
  --size 120 --volume-type gp3 \
  --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=ocp-odf-0-data}]" \
  --query 'VolumeId' --output text)

aws ec2 wait volume-available --volume-ids ${VOL}
aws ec2 attach-volume --volume-id ${VOL} --instance-id ${INSTANCE_ID} --device /dev/sdc

# Separately-created volumes default to DeleteOnTermination=false
aws ec2 modify-instance-attribute --instance-id ${INSTANCE_ID} \
  --block-device-mappings '[{"DeviceName":"/dev/sdc","Ebs":{"DeleteOnTermination":true}}]'
```

That last call matters. `cleanup.sh` terminates instances but never deletes standalone volumes, so without it teardown leaves 360 GB of gp3 orphaned — roughly $29/month, silently.

### Step 8 — Label and taint

```bash
for n in odf-0 odf-1 odf-2; do
  oc label node $n cluster.ocs.openshift.io/openshift-storage="" --overwrite
  oc adm taint node $n node.ocs.openshift.io/storage=true:NoSchedule --overwrite
done
```

The taint keeps general workloads off the storage nodes; the ODF operator tolerates it. Skip the taint if you want them to carry application pods too.

### Step 9 — Verify the data disk is raw

```bash
oc debug node/odf-0 -- chroot /host lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTLABEL
```

Expected:

```
nvme0n1        16G disk iso9660           ← agent ISO boot disk
nvme1n1       120G disk                   ← RHCOS install target
|-nvme1n1p1     1M part         BIOS-BOOT
|-nvme1n1p2   127M part vfat    EFI-SYSTEM
|-nvme1n1p3   384M part ext4    boot
`-nvme1n1p4 119.5G part xfs     root
nvme2n1       120G disk                   ← ODF data disk, no partition table
```

If `nvme2n1` carries the partitions and `nvme1n1` is empty, RHCOS was installed onto the ODF disk — see below.

## Why the data volume is attached late

The deployment identifies the RHCOS install target by **size**, not device name:

```yaml
rootDeviceHints:
  minSizeGigabytes: 100
```

That exists because NVMe device ordering is non-deterministic on EC2 — `/dev/nvme0n1` and `/dev/nvme1n1` can swap between instances, so `deviceName` is unusable. Size is the only stable discriminator.

Adding a 120 GB ODF volume to the AMI breaks that discriminator: **two** disks now satisfy `minSizeGigabytes: 100`, and the agent may pick either. The failure is quiet and expensive — the node installs and joins normally, having formatted the disk you intended for ODF, and you only discover it when ODF finds no usable device.

Attaching after the node has joined avoids the problem entirely, and suits ODF regardless: the Local Storage Operator wants raw devices that nothing has touched.

The alternative is asymmetric sizing — make the install target 150 GB, keep ODF at 120 GB, and set `minSizeGigabytes: 140`. It works, but it is fragile (every future disk must respect the size ordering) and it inflates the root volume on every node.

## Installing ODF

Once the nodes are in place, [`install-odf.sh`](../scripts/install-odf.sh) does the whole install:

```bash
export INSTALL_DIR=~/ocp-agent-aws
./scripts/install-odf.sh
```

About 25–30 minutes. Overridable settings:

| Variable | Default | Purpose |
|----------|---------|---------|
| `ODF_CHANNEL` | auto | Derived from the cluster's OCP minor, e.g. `stable-4.21` |
| `RESOURCE_PROFILE` | `lean` | `lean`, `balanced` or `performance` |
| `DEVICE_SIZE` | `120Gi` | Must match the data disk |
| `LOCAL_SC` | `localblock` | StorageClass name for the LSO-backed PVs |

The manifests it applies are in [`examples/odf-nodes/odf-install/`](../examples/odf-nodes/odf-install/) and can be applied by hand in numeric order.

### Step 1 — Local Storage Operator

On `platform: none` there is no cloud volume provisioner, so LSO is what turns the raw disk into a PV. Subscribe to the `stable` channel in `openshift-local-storage` and wait for the CSV to reach `Succeeded`.

### Step 2 — LocalVolumeSet

This is the step with a trap in it. The storage nodes carry a `NoSchedule` taint, and LSO's diskmaker and discovery DaemonSets run **on the nodes themselves** — so the `LocalVolumeSet` must carry a matching toleration:

```yaml
  tolerations:
    - key: node.ocs.openshift.io/storage
      value: "true"
      effect: NoSchedule
```

Without it the DaemonSets are never scheduled, no devices are discovered, no PVs appear, and the `StorageCluster` later sits forever waiting on PVCs that cannot bind. Nothing reports an error — you just get silence.

`minSize: 100Gi` includes the 120 GB data disk (~111.8 GiB) and excludes the 16 GB ISO disk. The 120 GB RHCOS target is the same size but is skipped automatically, because LSO ignores devices that already carry a partition table.

Expect one `Available` PV per node:

```
local-pv-73ad36c5   120Gi   RWO   Delete   Available   localblock
local-pv-992be2b0   120Gi   RWO   Delete   Available   localblock
local-pv-e48d130    120Gi   RWO   Delete   Available   localblock
```

### Step 3 — ODF operator

Subscribing to `odf-operator` also creates an `odf-dependencies` Subscription, which pulls in `ocs-operator`, `rook-ceph-operator`, `mcg-operator`, `cephcsi-operator`, `odf-csi-addons-operator` and the rest — **11 CSVs** on 4.21.

Those bundles sit in `BundleUnpacking / UnpackingInProgress` for several minutes with nothing else visible, and `storageclusters.ocs.openshift.io` does not exist until they land. That wait is normal. Confirm the catalog is healthy rather than assuming it has stalled:

```bash
oc get sub odf-dependencies -n openshift-storage \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
```

### Step 4 — StorageCluster

Internal mode, `replica: 3`, `portable: false` because local disks cannot migrate between nodes.

`resourceProfile: lean` matters on `m5.2xlarge`. ODF's default profile is sized for 16 vCPU / 64 GiB nodes; with 8 vCPU / 32 GiB the default requests do not fit and pods stay `Pending`.

Reaching `Ready` takes 10–15 minutes. OSDs are created one at a time, so mid-rollout you will see warnings that resolve themselves:

```
message: Processing OSD 0 on PVC "ocs-deviceset-localblock-0-data-0fz9zb"
detail:  1 osds down
detail:  Reduced data availability: 4 pgs inactive, 4 pgs peering
```

### Step 5 — Enable the console plugin

**A Subscription-based install does not enable the ODF console plugin.** Only the web console's OperatorHub flow does that. The `odf-console` pod runs and the `ConsolePlugin` CR is registered, but it is absent from the console operator's plugin list, so Data Foundation never appears in the UI:

```bash
oc patch console.operator.openshift.io cluster --type=json \
  -p '[{"op":"add","path":"/spec/plugins/-","value":"odf-console"}]'
```

The console pods redeploy; hard-refresh any open browser tab.

### Verify

```bash
oc get storagecluster -n openshift-storage
oc get cephcluster -n openshift-storage
oc get sc
```

Expected on success:

```
ocs-storagecluster   Ready   4.21.13

localblock
ocs-storagecluster-ceph-rbd
ocs-storagecluster-ceph-rgw
ocs-storagecluster-cephfs
openshift-storage.noobaa.io
```

A healthy fresh install still reports three `AUTH_INSECURE_*` warnings about Ceph key types. They are defaults, not a fault. A transient `PG_AVAILABILITY` warning clears within a minute or two of the last OSD joining.

Prove it end to end by binding a PVC:

```bash
oc create -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: odf-smoke-test
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ocs-storagecluster-ceph-rbd
  resources:
    requests:
      storage: 5Gi
EOF
oc get pvc odf-smoke-test -n default
```

### Capacity

Three nodes × 120 GiB = 360 GiB raw. With Ceph's 3-way replication that is roughly **120 GiB usable**.

## Resource Summary

Per invocation with the defaults:

| Resource | Count | Purpose |
|----------|-------|---------|
| ENIs | 3 | Fixed MACs at `10.0.1.121-123` |
| EC2 instances | 3 | `m5.2xlarge` storage nodes |
| EBS volumes | 9 | Per node: 16 GB ISO + 120 GB RHCOS (from AMI) + 120 GB raw ODF |
| EBS snapshot | 1 | Imported node ISO |
| AMI | 1 | Registered from that snapshot |
| S3 object | 1 | Temporary raw disk upload |

Nothing is added to the NLBs or Route 53 when `DEDICATED=true`.

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Attach the data volume after the node joins | Keeps `minSizeGigabytes` unambiguous. The central constraint of this guide |
| `oc adm node-image create` over re-running the installer | Day-2 flow driven by the running cluster; no installer state required |
| `DeleteOnTermination=true` on data volumes | `cleanup.sh` only terminates instances, so the default of `false` orphans them |
| Storage nodes start at `.121` | Visually separates them from the `.111-.113` compute workers |
| Not registered in ingress target groups | Router traffic has no business on dedicated storage nodes |
| `m5.2xlarge` default | `m5.xlarge` is below ODF's requirements; `m5.4xlarge` matches the recommendation but doubles the cost |

## Cleanup

The ODF nodes are torn down by the shared cleanup script along with the rest of the cluster:

```bash
./scripts/cleanup.sh ~/ocp-agent-aws/resource-ids.env
```

It discovers the instances and ENIs through the VPC and subnet filters, the data volumes follow the instances via `DeleteOnTermination`, and `add-odf-nodes.sh` records `ODF_AMI_ID` and `ODF_SNAP_ID` into `resource-ids.env` so the extra image and snapshot are removed too.

To remove only the storage nodes and keep the cluster:

```bash
source ~/ocp-agent-aws/odf/odf-resources.env
for n in "${ODF_HOSTNAMES[@]}"; do
  oc adm cordon $n && oc adm drain $n --ignore-daemonsets --delete-emptydir-data
  oc delete node $n
done
aws ec2 terminate-instances --instance-ids "${ODF_INSTANCE_IDS[@]}"
aws ec2 wait instance-terminated --instance-ids "${ODF_INSTANCE_IDS[@]}"
for e in "${ODF_ENI_IDS[@]}"; do aws ec2 delete-network-interface --network-interface-id $e; done
```

Drain ODF nodes properly — evicting OSDs without letting Ceph rebalance risks data loss.

## Troubleshooting

### RHCOS installed onto the ODF disk

`nvme2n1` holds the partition table and `nvme1n1` is empty. The ODF volume was present at install time and matched `minSizeGigabytes`. Terminate the node, detach the data volume, and relaunch with only the two AMI block devices.

### Nodes never appear, no CSRs

CSRs typically arrive 7–8 minutes after launch. If nothing appears after 15 minutes, the agent probably could not match the host by MAC. Confirm the MACs in `nodes-config.yaml` match the ENIs actually attached:

```bash
aws ec2 describe-network-interfaces --network-interface-ids ${ENI_ID} \
  --query 'NetworkInterfaces[0].MacAddress' --output text
```

### Nodes join but stay `NotReady`

Usually the second CSR is still pending. The kubelet serving certificate request only appears after the node registers:

```bash
oc get csr | grep Pending
```

### `oc adm node-image create` fails

Check `report.json` in the working directory. The most common causes are an unreachable cluster and a release payload the cluster cannot pull.

### ODF finds no available devices

Confirm the disk is genuinely raw — a filesystem signature, even a stale one, makes the Local Storage Operator skip it:

```bash
oc debug node/odf-0 -- chroot /host lsblk -o NAME,SIZE,FSTYPE
```

Also confirm the node carries `cluster.ocs.openshift.io/openshift-storage` and that your `LocalVolumeSet` node selector matches it.
