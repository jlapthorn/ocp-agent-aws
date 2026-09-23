#!/usr/bin/env bash
set -euo pipefail

#
# Deploy a Single Node OpenShift (SNO) cluster on AWS EC2 using the Agent-Based Installer.
#
# Usage:
#   export CLUSTER_NAME=sno
#   export BASE_DOMAIN=example.com
#   export INSTALL_DIR=~/sno-agent-aws
#   export PULL_SECRET_FILE=~/pull-secret.json
#   export SSH_KEY_FILE=~/.ssh/id_ed25519.pub
#   export AWS_REGION=us-east-2
#   ./deploy-sno.sh
#

# ── Configuration ──────────────────────────────────────────────────────────────

CLUSTER_NAME="${CLUSTER_NAME:?Set CLUSTER_NAME (e.g. sno)}"
BASE_DOMAIN="${BASE_DOMAIN:?Set BASE_DOMAIN (e.g. example.com)}"
INSTALL_DIR="${INSTALL_DIR:?Set INSTALL_DIR (e.g. ~/sno-agent-aws)}"
PULL_SECRET_FILE="${PULL_SECRET_FILE:?Set PULL_SECRET_FILE}"
SSH_KEY_FILE="${SSH_KEY_FILE:?Set SSH_KEY_FILE}"
AWS_REGION="${AWS_REGION:-us-east-2}"
AZ="${AWS_REGION}a"

VPC_CIDR="10.0.0.0/16"
SUBNET_CIDR="10.0.1.0/24"
VPC_DNS="10.0.0.2"
NODE_IP="10.0.1.100"
INSTANCE_TYPE="m6i.2xlarge"    # 8 vCPU, 32 GiB RAM
ISO_DISK_SIZE=16
INSTALL_DISK_SIZE=120
KEY_NAME="ocp-agent-key"

# ── Helpers ────────────────────────────────────────────────────────────────────

log() { echo "$(date +%H:%M:%S) ── $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

for cmd in openshift-install oc qemu-img aws jq; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found in PATH"
done
[[ -f "$PULL_SECRET_FILE" ]] || die "Pull secret not found: $PULL_SECRET_FILE"
[[ -f "$SSH_KEY_FILE" ]] || die "SSH key not found: $SSH_KEY_FILE"

mkdir -p "${INSTALL_DIR}"

# ── Step 1: VPC and Networking ─────────────────────────────────────────────────

log "Creating VPC and networking..."
VPC_ID=$(aws ec2 create-vpc --cidr-block ${VPC_CIDR} --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id ${VPC_ID} --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id ${VPC_ID} --enable-dns-hostnames '{"Value":true}'
aws ec2 create-tags --resources ${VPC_ID} --tags Key=Name,Value=${CLUSTER_NAME}-vpc

SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id ${VPC_ID} --cidr-block ${SUBNET_CIDR} --availability-zone ${AZ} \
  --query 'Subnet.SubnetId' --output text)
aws ec2 modify-subnet-attribute --subnet-id ${SUBNET_ID} --map-public-ip-on-launch

IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id ${IGW_ID} --vpc-id ${VPC_ID}
RTB_ID=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'RouteTables[0].RouteTableId' --output text)
aws ec2 create-route --route-table-id ${RTB_ID} \
  --destination-cidr-block 0.0.0.0/0 --gateway-id ${IGW_ID} >/dev/null

SG_ID=$(aws ec2 create-security-group \
  --group-name ${CLUSTER_NAME}-sg \
  --description "SNO OpenShift security group" \
  --vpc-id ${VPC_ID} --query 'GroupId' --output text)

for PORT in 22 80 443 6443 22623; do
  aws ec2 authorize-security-group-ingress \
    --group-id ${SG_ID} --protocol tcp --port ${PORT} --cidr 0.0.0.0/0 >/dev/null
done
aws ec2 authorize-security-group-ingress \
  --group-id ${SG_ID} --protocol tcp --port 30000-32767 --cidr 0.0.0.0/0 >/dev/null

log "VPC: ${VPC_ID} | Subnet: ${SUBNET_ID} | SG: ${SG_ID}"

# ── Step 2: ENI, EIP, Key Pair ─────────────────────────────────────────────────

log "Creating ENI..."
ENI_ID=$(aws ec2 create-network-interface \
  --subnet-id ${SUBNET_ID} --groups ${SG_ID} \
  --private-ip-address ${NODE_IP} \
  --description "SNO OpenShift ENI" \
  --query 'NetworkInterface.NetworkInterfaceId' --output text)
ENI_MAC=$(aws ec2 describe-network-interfaces \
  --network-interface-ids ${ENI_ID} \
  --query 'NetworkInterfaces[0].MacAddress' --output text)
log "ENI: ${ENI_ID} (MAC: ${ENI_MAC})"

log "Allocating Elastic IP..."
EIP_ALLOC=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
EIP_ADDR=$(aws ec2 describe-addresses --allocation-ids ${EIP_ALLOC} \
  --query 'Addresses[0].PublicIp' --output text)
log "EIP: ${EIP_ADDR}"

aws ec2 import-key-pair --key-name ${KEY_NAME} \
  --public-key-material fileb://${SSH_KEY_FILE} 2>/dev/null || true

# ── Step 3: DNS ────────────────────────────────────────────────────────────────

log "Creating DNS records..."
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "${BASE_DOMAIN}" \
  --query 'HostedZones[0].Id' --output text | sed 's|/hostedzone/||')
[[ -z "${ZONE_ID}" || "${ZONE_ID}" == "None" ]] && die "No Route 53 zone for ${BASE_DOMAIN}"

aws route53 change-resource-record-sets --hosted-zone-id ${ZONE_ID} \
  --change-batch "{
    \"Changes\": [
      {\"Action\":\"UPSERT\",\"ResourceRecordSet\":{
        \"Name\":\"api.${CLUSTER_NAME}.${BASE_DOMAIN}\",\"Type\":\"A\",\"TTL\":300,
        \"ResourceRecords\":[{\"Value\":\"${EIP_ADDR}\"}]}},
      {\"Action\":\"UPSERT\",\"ResourceRecordSet\":{
        \"Name\":\"api-int.${CLUSTER_NAME}.${BASE_DOMAIN}\",\"Type\":\"A\",\"TTL\":300,
        \"ResourceRecords\":[{\"Value\":\"${EIP_ADDR}\"}]}},
      {\"Action\":\"UPSERT\",\"ResourceRecordSet\":{
        \"Name\":\"*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}\",\"Type\":\"A\",\"TTL\":300,
        \"ResourceRecords\":[{\"Value\":\"${EIP_ADDR}\"}]}}
    ]
  }" >/dev/null
log "DNS configured"

# ── Step 4: Generate Agent ISO ─────────────────────────────────────────────────

PULL_SECRET=$(cat "${PULL_SECRET_FILE}")
SSH_KEY=$(cat "${SSH_KEY_FILE}")

cat > "${INSTALL_DIR}/install-config.yaml" <<EOF
apiVersion: v1
metadata:
  name: ${CLUSTER_NAME}
baseDomain: ${BASE_DOMAIN}
networking:
  networkType: OVNKubernetes
  machineNetwork:
    - cidr: ${SUBNET_CIDR}
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  serviceNetwork:
    - 172.30.0.0/16
compute:
  - name: worker
    replicas: 0
controlPlane:
  name: master
  replicas: 1
platform:
  none: {}
pullSecret: '${PULL_SECRET}'
sshKey: '${SSH_KEY}'
EOF

cat > "${INSTALL_DIR}/agent-config.yaml" <<EOF
apiVersion: v1beta1
kind: AgentConfig
metadata:
  name: ${CLUSTER_NAME}
rendezvousIP: ${NODE_IP}
hosts:
  - hostname: ${CLUSTER_NAME}
    role: master
    rootDeviceHints:
      minSizeGigabytes: 100
    interfaces:
      - name: ens5
        macAddress: "${ENI_MAC}"
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

log "Generating agent ISO..."
cd "${INSTALL_DIR}"
openshift-install agent create image --dir=. --log-level=info

# ── Step 5: Convert ISO to AMI ─────────────────────────────────────────────────

log "Converting ISO to raw disk..."
qemu-img convert -f raw -O raw agent.x86_64.iso agent.x86_64.raw

BUCKET_NAME="openshift-agent-iso-${CLUSTER_NAME}-$(date +%s)"
aws s3 mb s3://${BUCKET_NAME} >/dev/null
aws s3 cp agent.x86_64.raw s3://${BUCKET_NAME}/agent.x86_64.raw --quiet

aws iam create-role --role-name vmimport \
  --assume-role-policy-document '{
    "Version":"2012-10-17","Statement":[{"Effect":"Allow",
    "Principal":{"Service":"vmie.amazonaws.com"},
    "Action":"sts:AssumeRole",
    "Condition":{"StringEquals":{"sts:Externalid":"vmimport"}}}]
  }' 2>/dev/null || true

aws iam put-role-policy --role-name vmimport --policy-name vmimport-s3-policy \
  --policy-document "{
    \"Version\":\"2012-10-17\",\"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"s3:GetBucketLocation\",\"s3:GetObject\",\"s3:ListBucket\"],
     \"Resource\":[\"arn:aws:s3:::${BUCKET_NAME}\",\"arn:aws:s3:::${BUCKET_NAME}/*\"]},
    {\"Effect\":\"Allow\",\"Action\":[\"ec2:ModifySnapshotAttribute\",\"ec2:CopySnapshot\",
     \"ec2:RegisterImage\",\"ec2:Describe*\"],\"Resource\":\"*\"}]
  }"

log "Importing EBS snapshot..."
IMPORT_TASK=$(aws ec2 import-snapshot \
  --description "${CLUSTER_NAME} agent ISO" \
  --disk-container "{\"Format\":\"RAW\",\"UserBucket\":{\"S3Bucket\":\"${BUCKET_NAME}\",\"S3Key\":\"agent.x86_64.raw\"}}" \
  --query 'ImportTaskId' --output text)

while true; do
  STATUS_JSON=$(aws ec2 describe-import-snapshot-tasks \
    --import-task-ids ${IMPORT_TASK} \
    --query 'ImportSnapshotTasks[0].SnapshotTaskDetail' --output json)
  STAT=$(echo "$STATUS_JSON" | jq -r '.Status')
  PROG=$(echo "$STATUS_JSON" | jq -r '.Progress // "?"')
  log "  ${STAT} (${PROG}%)"
  [[ "$STAT" == "completed" ]] && { SNAP_ID=$(echo "$STATUS_JSON" | jq -r '.SnapshotId'); break; }
  [[ "$STAT" == "error" ]] && die "Snapshot import failed"
  sleep 15
done

AMI_ID=$(aws ec2 register-image \
  --name "${CLUSTER_NAME}-agent-$(date +%Y%m%d%H%M)" \
  --architecture x86_64 --root-device-name /dev/sda1 \
  --boot-mode uefi-preferred --ena-support --virtualization-type hvm \
  --block-device-mappings "[
    {\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"SnapshotId\":\"${SNAP_ID}\",
      \"VolumeSize\":${ISO_DISK_SIZE},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}},
    {\"DeviceName\":\"/dev/sdb\",\"Ebs\":{\"VolumeSize\":${INSTALL_DISK_SIZE},
      \"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}
  ]" --query 'ImageId' --output text)
log "AMI: ${AMI_ID}"

# ── Step 6: Launch Instance ────────────────────────────────────────────────────

log "Launching instance..."
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id ${AMI_ID} --instance-type ${INSTANCE_TYPE} \
  --key-name ${KEY_NAME} \
  --network-interfaces "DeviceIndex=0,NetworkInterfaceId=${ENI_ID}" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER_NAME}-node}]" \
  --query 'Instances[0].InstanceId' --output text)
aws ec2 wait instance-running --instance-ids ${INSTANCE_ID}

aws ec2 associate-address --allocation-id ${EIP_ALLOC} --network-interface-id ${ENI_ID} >/dev/null
log "Instance ${INSTANCE_ID} running at ${EIP_ADDR}"

# Save resource IDs
cat > "${INSTALL_DIR}/resource-ids.env" <<EOF
VPC_ID=${VPC_ID}
SUBNET_ID=${SUBNET_ID}
IGW_ID=${IGW_ID}
SG_ID=${SG_ID}
ENI_ID=${ENI_ID}
EIP_ALLOC=${EIP_ALLOC}
EIP_ADDR=${EIP_ADDR}
BUCKET_NAME=${BUCKET_NAME}
SNAP_ID=${SNAP_ID}
AMI_ID=${AMI_ID}
INSTANCE_ID=${INSTANCE_ID}
ZONE_ID=${ZONE_ID}
KEY_NAME=${KEY_NAME}
EOF

# ── Step 7: Monitor Installation ───────────────────────────────────────────────

log "Monitoring installation (25-40 minutes)..."
openshift-install agent wait-for install-complete --dir=. --log-level=info

export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"
echo ""
log "═══════════════════════════════════"
log "  SNO cluster installation complete!"
log "═══════════════════════════════════"
echo ""
echo "Console:  https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
echo "API:      https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443"
echo "Password: $(cat ${INSTALL_DIR}/auth/kubeadmin-password)"
echo "Config:   export KUBECONFIG=${INSTALL_DIR}/auth/kubeconfig"
