#!/usr/bin/env bash
set -euo pipefail

#
# Add dedicated OpenShift Data Foundation (ODF) storage nodes to a running
# OpenShift cluster on AWS EC2.
#
# Uses the day-2 `oc adm node-image create` flow: the running cluster generates
# a node ISO, which is converted to an AMI exactly as in the initial deployment.
# Each node gets an additional raw EBS volume for ODF.
#
# IMPORTANT: the ODF data volume is attached AFTER the node has joined, not
# baked into the AMI. See "Why the data volume is attached late" in
# docs/odf-storage-nodes.md — attaching it up front makes
# rootDeviceHints.minSizeGigabytes ambiguous and the agent may install RHCOS
# onto the ODF volume.
#
# Prerequisites:
#   - A running cluster deployed with deploy-multi-node.sh
#   - ${INSTALL_DIR}/resource-ids.env from that deployment
#   - oc, qemu-img, aws CLI v2, jq, nmstatectl
#
# Usage:
#   export INSTALL_DIR=~/ocp-agent-aws
#   export AWS_REGION=us-east-2
#   ./add-odf-nodes.sh
#

# ── Configuration ──────────────────────────────────────────────────────────────

INSTALL_DIR="${INSTALL_DIR:?Set INSTALL_DIR (e.g. ~/ocp-agent-aws)}"
AWS_REGION="${AWS_REGION:-us-east-2}"
AZ="${AZ:-${AWS_REGION}a}"

NODE_COUNT="${NODE_COUNT:-3}"
HOSTNAME_PREFIX="${HOSTNAME_PREFIX:-odf}"
INSTANCE_TYPE="${INSTANCE_TYPE:-m5.2xlarge}"   # 8 vCPU, 32 GiB — pragmatic ODF minimum
ISO_DISK_SIZE="${ISO_DISK_SIZE:-16}"           # GB — agent ISO boot disk
INSTALL_DISK_SIZE="${INSTALL_DISK_SIZE:-120}"  # GB — RHCOS install target
ODF_DISK_SIZE="${ODF_DISK_SIZE:-120}"          # GB — raw ODF data disk
VPC_DNS="${VPC_DNS:-10.0.0.2}"

# Storage nodes start at .121 to keep them visually distinct from the
# .111-.113 compute workers created by deploy-multi-node.sh.
IP_PREFIX="${IP_PREFIX:-10.0.1}"
IP_START="${IP_START:-121}"

# Dedicate the nodes to ODF: label + NoSchedule taint, and keep them out of the
# ingress target groups. Set to false to make them general-purpose workers.
DEDICATED="${DEDICATED:-true}"

WORKDIR="${INSTALL_DIR}/odf"
STATE_FILE="${WORKDIR}/odf-resources.env"

# ── Helpers ────────────────────────────────────────────────────────────────────

log() { echo "$(date +%H:%M:%S) ── $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

for cmd in oc qemu-img aws jq nmstatectl; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found in PATH"
done

[[ -f "${INSTALL_DIR}/resource-ids.env" ]] \
  || die "No resource-ids.env in ${INSTALL_DIR} — was this cluster deployed with deploy-multi-node.sh?"
# shellcheck disable=SC1091
source "${INSTALL_DIR}/resource-ids.env"

export KUBECONFIG="${KUBECONFIG:-${INSTALL_DIR}/auth/kubeconfig}"
[[ -f "${KUBECONFIG}" ]] || die "kubeconfig not found: ${KUBECONFIG}"

oc get clusterversion >/dev/null 2>&1 || die "Cannot reach the cluster with ${KUBECONFIG}"

mkdir -p "${WORKDIR}"

save_state() {
  cat > "${STATE_FILE}" <<EOF
ODF_HOSTNAMES=(${ODF_HOSTNAMES[*]:-})
ODF_IPS=(${ODF_IPS[*]:-})
ODF_ENI_IDS=(${ODF_ENI_IDS[*]:-})
ODF_MACS=(${ODF_MACS[*]:-})
ODF_INSTANCE_IDS=(${ODF_INSTANCE_IDS[*]:-})
ODF_DATA_VOLUMES=(${ODF_DATA_VOLUMES[*]:-})
ODF_BUCKET_NAME=${ODF_BUCKET_NAME:-}
ODF_SNAP_ID=${ODF_SNAP_ID:-}
ODF_AMI_ID=${ODF_AMI_ID:-}
EOF
}

# Make the ODF AMI and snapshot visible to cleanup.sh, which reads the main
# resource-ids.env. Without this they survive teardown as orphans.
record_for_cleanup() {
  grep -v -E '^(ODF_AMI_ID|ODF_SNAP_ID)=' "${INSTALL_DIR}/resource-ids.env" \
    > "${INSTALL_DIR}/resource-ids.env.tmp" || true
  {
    echo "ODF_AMI_ID=${ODF_AMI_ID:-}"
    echo "ODF_SNAP_ID=${ODF_SNAP_ID:-}"
  } >> "${INSTALL_DIR}/resource-ids.env.tmp"
  mv "${INSTALL_DIR}/resource-ids.env.tmp" "${INSTALL_DIR}/resource-ids.env"
}

log "Adding ${NODE_COUNT} ODF node(s) to cluster ${CLUSTER_NAME}"
log "  instance type: ${INSTANCE_TYPE} | ODF disk: ${ODF_DISK_SIZE}GB | dedicated: ${DEDICATED}"

# ── Step 1: Pre-create ENIs for deterministic MACs ─────────────────────────────

log "Creating ENIs..."
ODF_HOSTNAMES=(); ODF_IPS=(); ODF_ENI_IDS=(); ODF_MACS=()
ODF_INSTANCE_IDS=(); ODF_DATA_VOLUMES=()

for ((i=0; i<NODE_COUNT; i++)); do
  host="${HOSTNAME_PREFIX}-${i}"
  ip="${IP_PREFIX}.$((IP_START + i))"
  eni=$(aws ec2 create-network-interface \
    --subnet-id "${SUBNET_ID}" --groups "${SG_ID}" --private-ip-address "${ip}" \
    --description "OCP ${host}" \
    --query 'NetworkInterface.NetworkInterfaceId' --output text)
  mac=$(aws ec2 describe-network-interfaces --network-interface-ids "${eni}" \
    --query 'NetworkInterfaces[0].MacAddress' --output text)
  ODF_HOSTNAMES+=("${host}"); ODF_IPS+=("${ip}")
  ODF_ENI_IDS+=("${eni}"); ODF_MACS+=("${mac}")
  log "  ${host}: ${ip} ${eni} (${mac})"
done
save_state

# ── Step 2: Generate nodes-config.yaml ─────────────────────────────────────────

log "Generating nodes-config.yaml..."
echo "hosts:" > "${WORKDIR}/nodes-config.yaml"
for ((i=0; i<NODE_COUNT; i++)); do
  cat >> "${WORKDIR}/nodes-config.yaml" <<EOF
  - hostname: ${ODF_HOSTNAMES[$i]}
    interfaces:
      - name: ens5
        macAddress: "${ODF_MACS[$i]}"
    rootDeviceHints:
      minSizeGigabytes: 100
    networkConfig:
      interfaces:
        - name: ens5
          type: ethernet
          state: up
          ipv4:
            enabled: true
            dhcp: true
      dns-resolver:
        config:
          server:
            - ${VPC_DNS}
EOF
done

# ── Step 3: Generate the node ISO from the running cluster ─────────────────────

log "Generating node ISO via 'oc adm node-image create' (takes ~5-8 minutes)..."
( cd "${WORKDIR}" && oc adm node-image create --dir=. -o=node.x86_64.iso )
[[ -f "${WORKDIR}/node.x86_64.iso" ]] || die "node ISO was not produced — see ${WORKDIR}/report.json"
log "ISO: $(du -h "${WORKDIR}/node.x86_64.iso" | cut -f1)"

# ── Step 4: Convert ISO to AMI ─────────────────────────────────────────────────

log "Converting ISO to raw disk..."
qemu-img convert -f raw -O raw "${WORKDIR}/node.x86_64.iso" "${WORKDIR}/node.x86_64.raw"

# The deployment bucket is deleted by cleanup.sh, so fall back to a fresh one.
ODF_BUCKET_NAME="${BUCKET_NAME:-}"
if [[ -z "${ODF_BUCKET_NAME}" ]] || ! aws s3 ls "s3://${ODF_BUCKET_NAME}" >/dev/null 2>&1; then
  ODF_BUCKET_NAME="openshift-node-iso-${CLUSTER_NAME}-$(date +%s)"
  log "Creating S3 bucket ${ODF_BUCKET_NAME}..."
  aws s3 mb "s3://${ODF_BUCKET_NAME}" >/dev/null
fi

log "Uploading to s3://${ODF_BUCKET_NAME}..."
aws s3 cp "${WORKDIR}/node.x86_64.raw" "s3://${ODF_BUCKET_NAME}/node-odf.x86_64.raw" --quiet

# The vmimport role's policy is scoped to a specific bucket by the deploy
# script, so re-grant for whichever bucket we just used.
aws iam put-role-policy --role-name vmimport --policy-name vmimport-s3-policy \
  --policy-document "{
    \"Version\":\"2012-10-17\",\"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"s3:GetBucketLocation\",\"s3:GetObject\",\"s3:ListBucket\"],
     \"Resource\":[\"arn:aws:s3:::${ODF_BUCKET_NAME}\",\"arn:aws:s3:::${ODF_BUCKET_NAME}/*\"]},
    {\"Effect\":\"Allow\",\"Action\":[\"ec2:ModifySnapshotAttribute\",\"ec2:CopySnapshot\",
     \"ec2:RegisterImage\",\"ec2:Describe*\"],\"Resource\":\"*\"}]
  }"

log "Importing EBS snapshot (takes 5-10 minutes)..."
IMPORT_TASK=$(aws ec2 import-snapshot \
  --description "${CLUSTER_NAME} ODF node image" \
  --disk-container "{\"Format\":\"RAW\",\"UserBucket\":{\"S3Bucket\":\"${ODF_BUCKET_NAME}\",\"S3Key\":\"node-odf.x86_64.raw\"}}" \
  --query 'ImportTaskId' --output text)

while true; do
  STATUS_JSON=$(aws ec2 describe-import-snapshot-tasks --import-task-ids "${IMPORT_TASK}" \
    --query 'ImportSnapshotTasks[0].SnapshotTaskDetail' --output json)
  STAT=$(echo "${STATUS_JSON}" | jq -r '.Status')
  PROG=$(echo "${STATUS_JSON}" | jq -r '.Progress // "?"')
  log "  Snapshot import: ${STAT} (${PROG}%)"
  [[ "${STAT}" == "completed" ]] && { ODF_SNAP_ID=$(echo "${STATUS_JSON}" | jq -r '.SnapshotId'); break; }
  [[ "${STAT}" == "error" ]] && die "Snapshot import failed"
  sleep 20
done
save_state

# Only two block devices here. A third device sized >= minSizeGigabytes would
# make the root device hint ambiguous; the ODF disk is attached in step 7.
log "Registering AMI (${ISO_DISK_SIZE}GB boot + ${INSTALL_DISK_SIZE}GB install target)..."
ODF_AMI_ID=$(aws ec2 register-image \
  --name "${CLUSTER_NAME}-odf-$(date +%Y%m%d%H%M)" \
  --description "OpenShift ${CLUSTER_NAME} ODF node image" \
  --architecture x86_64 --root-device-name /dev/sda1 \
  --boot-mode uefi-preferred --ena-support --virtualization-type hvm \
  --block-device-mappings "[
    {\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"SnapshotId\":\"${ODF_SNAP_ID}\",
      \"VolumeSize\":${ISO_DISK_SIZE},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}},
    {\"DeviceName\":\"/dev/sdb\",\"Ebs\":{\"VolumeSize\":${INSTALL_DISK_SIZE},
      \"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}
  ]" --query 'ImageId' --output text)
log "AMI: ${ODF_AMI_ID}"
save_state
record_for_cleanup

# ── Step 5: Launch instances ───────────────────────────────────────────────────

log "Launching ${NODE_COUNT} x ${INSTANCE_TYPE}..."
for ((i=0; i<NODE_COUNT; i++)); do
  iid=$(aws ec2 run-instances --image-id "${ODF_AMI_ID}" --instance-type "${INSTANCE_TYPE}" \
    --key-name "${KEY_NAME}" \
    --network-interfaces "DeviceIndex=0,NetworkInterfaceId=${ODF_ENI_IDS[$i]}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER_NAME}-${ODF_HOSTNAMES[$i]}}]" \
    --query 'Instances[0].InstanceId' --output text)
  ODF_INSTANCE_IDS+=("${iid}")
  log "  ${ODF_HOSTNAMES[$i]}: ${iid}"
done
aws ec2 wait instance-running --instance-ids "${ODF_INSTANCE_IDS[@]}"
log "All ${NODE_COUNT} instances running"
save_state

# ── Step 6: Approve CSRs and wait for the nodes to join ────────────────────────

# Each node needs two approvals: the kubelet client cert (requested by the
# node-bootstrapper service account) and then the kubelet serving cert. They
# appear a minute or so apart, roughly 7-8 minutes after launch.
log "Waiting for nodes to join and approving CSRs (takes ~10 minutes)..."
for _ in $(seq 1 40); do
  PENDING=$(oc get csr --no-headers 2>/dev/null | awk '$NF=="Pending"{print $1}')
  for csr in ${PENDING}; do
    requester=$(oc get csr "${csr}" -o jsonpath='{.spec.username}' 2>/dev/null || true)
    log "  approving ${csr} (${requester})"
    oc adm certificate approve "${csr}" >/dev/null 2>&1 || true
  done

  ready=0
  for host in "${ODF_HOSTNAMES[@]}"; do
    state=$(oc get node "${host}" --no-headers 2>/dev/null | awk '{print $2}')
    [[ "${state}" == "Ready" ]] && ready=$((ready + 1))
  done
  log "  ${ready}/${NODE_COUNT} node(s) Ready"
  [[ "${ready}" -eq "${NODE_COUNT}" ]] && break
  sleep 30
done

for host in "${ODF_HOSTNAMES[@]}"; do
  oc get node "${host}" >/dev/null 2>&1 || die "${host} never joined the cluster"
done

# ── Step 7: Create and attach the ODF data volumes ─────────────────────────────

log "Creating ${ODF_DISK_SIZE}GB ODF data volumes..."
for ((i=0; i<NODE_COUNT; i++)); do
  vol=$(aws ec2 create-volume --availability-zone "${AZ}" \
    --size "${ODF_DISK_SIZE}" --volume-type gp3 \
    --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=${CLUSTER_NAME}-${ODF_HOSTNAMES[$i]}-data}]" \
    --query 'VolumeId' --output text)
  ODF_DATA_VOLUMES+=("${vol}")
  log "  ${ODF_HOSTNAMES[$i]}: ${vol}"
done
aws ec2 wait volume-available --volume-ids "${ODF_DATA_VOLUMES[@]}"
save_state

log "Attaching data volumes as /dev/sdc..."
for ((i=0; i<NODE_COUNT; i++)); do
  aws ec2 attach-volume --volume-id "${ODF_DATA_VOLUMES[$i]}" \
    --instance-id "${ODF_INSTANCE_IDS[$i]}" --device /dev/sdc >/dev/null
done
aws ec2 wait volume-in-use --volume-ids "${ODF_DATA_VOLUMES[@]}"

# Separately-created volumes default to DeleteOnTermination=false, and
# cleanup.sh only terminates instances — the volumes would be left orphaned.
log "Setting DeleteOnTermination on data volumes..."
for ((i=0; i<NODE_COUNT; i++)); do
  aws ec2 modify-instance-attribute --instance-id "${ODF_INSTANCE_IDS[$i]}" \
    --block-device-mappings '[{"DeviceName":"/dev/sdc","Ebs":{"DeleteOnTermination":true}}]'
done

# ── Step 8: Label and taint for ODF ────────────────────────────────────────────

if [[ "${DEDICATED}" == "true" ]]; then
  log "Labelling and tainting nodes as dedicated storage nodes..."
  for host in "${ODF_HOSTNAMES[@]}"; do
    oc label node "${host}" cluster.ocs.openshift.io/openshift-storage="" --overwrite >/dev/null
    oc adm taint node "${host}" node.ocs.openshift.io/storage=true:NoSchedule --overwrite >/dev/null
  done
else
  log "Labelling nodes for ODF (no taint; also registering in ingress target groups)..."
  for host in "${ODF_HOSTNAMES[@]}"; do
    oc label node "${host}" cluster.ocs.openshift.io/openshift-storage="" --overwrite >/dev/null
  done
  for ip in "${ODF_IPS[@]}"; do
    aws elbv2 register-targets --target-group-arn "${HTTP_TG_ARN}" --targets "Id=${ip}" >/dev/null
    aws elbv2 register-targets --target-group-arn "${HTTPS_TG_ARN}" --targets "Id=${ip}" >/dev/null
  done
fi

# ── Step 9: Verify ─────────────────────────────────────────────────────────────

log "Verifying the data disk is raw on each node..."
for host in "${ODF_HOSTNAMES[@]}"; do
  echo "── ${host}"
  oc debug "node/${host}" --quiet -- chroot /host bash -c \
    'echo "  root: $(findmnt -no SOURCE /sysroot 2>/dev/null || findmnt -no SOURCE /)"; lsblk -dno NAME,SIZE,FSTYPE | grep -v loop | sed "s/^/  /"' 2>/dev/null || true
done

echo ""
log "═══════════════════════════════════════════════════════════"
log "  ${NODE_COUNT} ODF node(s) added"
log "═══════════════════════════════════════════════════════════"
echo ""
oc get nodes
echo ""
echo "Data volumes : ${ODF_DATA_VOLUMES[*]}"
echo "State        : ${STATE_FILE}"
echo ""
echo "The data disk is raw and unformatted. Next: install the ODF operator and"
echo "create a StorageCluster against it (see docs/odf-storage-nodes.md)."
