#!/usr/bin/env bash
set -euo pipefail

#
# Deploy a Single Node OpenShift (SNO) cluster on AWS EC2 using the Agent-Based
# Installer in a disconnected (mirror registry) configuration.
#
# This script:
#   1. Creates a VPC with networking
#   2. Deploys an Amazon Linux 2023 instance running a Docker v2 registry
#   3. Mirrors OCP release images to the registry with oc-mirror v2
#   4. Generates an agent ISO configured to pull from the mirror
#   5. Converts the ISO to an AMI and launches the SNO instance
#
# Usage:
#   export CLUSTER_NAME=sno
#   export BASE_DOMAIN=example.com
#   export INSTALL_DIR=~/sno-disconnected-aws
#   export PULL_SECRET_FILE=~/pull-secret.json
#   export SSH_KEY_FILE=~/.ssh/id_ed25519.pub
#   export AWS_REGION=us-east-2
#   ./deploy-sno-disconnected.sh
#

# ── Configuration ──────────────────────────────────────────────────────────────

CLUSTER_NAME="${CLUSTER_NAME:?Set CLUSTER_NAME (e.g. sno)}"
BASE_DOMAIN="${BASE_DOMAIN:?Set BASE_DOMAIN (e.g. example.com)}"
INSTALL_DIR="${INSTALL_DIR:?Set INSTALL_DIR (e.g. ~/sno-disconnected-aws)}"
PULL_SECRET_FILE="${PULL_SECRET_FILE:?Set PULL_SECRET_FILE}"
SSH_KEY_FILE="${SSH_KEY_FILE:?Set SSH_KEY_FILE}"
AWS_REGION="${AWS_REGION:-us-east-2}"
AZ="${AWS_REGION}a"

VPC_CIDR="10.0.0.0/16"
SUBNET_CIDR="10.0.1.0/24"
VPC_DNS="10.0.0.2"
NODE_IP="10.0.1.100"
REGISTRY_IP="10.0.1.50"
REGISTRY_PORT=5000
REGISTRY_USER="registry"
REGISTRY_PASS="registry"
REGISTRY_INSTANCE_TYPE="t3.medium"
INSTANCE_TYPE="m6i.2xlarge"
ISO_DISK_SIZE=16
INSTALL_DISK_SIZE=120
KEY_NAME="ocp-agent-key"
OCP_VERSION="4.22.11"
OCP_CHANNEL="stable-4.22"
MIRROR_WORKSPACE="${INSTALL_DIR}/mirror"

# ── Helpers ────────────────────────────────────────────────────────────────────

log() { echo "$(date +%H:%M:%S) ── $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

for cmd in openshift-install oc oc-mirror qemu-img aws jq; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found in PATH"
done
[[ -f "$PULL_SECRET_FILE" ]] || die "Pull secret not found: $PULL_SECRET_FILE"
[[ -f "$SSH_KEY_FILE" ]] || die "SSH key not found: $SSH_KEY_FILE"

mkdir -p "${INSTALL_DIR}"

save_state() {
  cat > "${INSTALL_DIR}/resource-ids.env" <<EOF
CLUSTER_NAME=${CLUSTER_NAME:-}
BASE_DOMAIN=${BASE_DOMAIN:-}
VPC_ID=${VPC_ID:-}
SUBNET_ID=${SUBNET_ID:-}
IGW_ID=${IGW_ID:-}
SG_ID=${SG_ID:-}
REGISTRY_ENI_ID=${REGISTRY_ENI_ID:-}
REGISTRY_EIP_ALLOC=${REGISTRY_EIP_ALLOC:-}
REGISTRY_EIP_ADDR=${REGISTRY_EIP_ADDR:-}
REGISTRY_INSTANCE_ID=${REGISTRY_INSTANCE_ID:-}
ENI_ID=${ENI_ID:-}
EIP_ALLOC=${EIP_ALLOC:-}
EIP_ADDR=${EIP_ADDR:-}
BUCKET_NAME=${BUCKET_NAME:-}
SNAP_ID=${SNAP_ID:-}
AMI_ID=${AMI_ID:-}
INSTANCE_ID=${INSTANCE_ID:-}
ZONE_ID=${ZONE_ID:-}
KEY_NAME=${KEY_NAME:-}
EOF
}

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
  --description "Disconnected SNO OpenShift security group" \
  --vpc-id ${VPC_ID} --query 'GroupId' --output text)

for PORT in 22 80 443 5000 6443 22623; do
  aws ec2 authorize-security-group-ingress \
    --group-id ${SG_ID} --protocol tcp --port ${PORT} --cidr 0.0.0.0/0 >/dev/null
done
aws ec2 authorize-security-group-ingress \
  --group-id ${SG_ID} --protocol tcp --port 30000-32767 --cidr 0.0.0.0/0 >/dev/null

log "VPC: ${VPC_ID} | Subnet: ${SUBNET_ID} | SG: ${SG_ID}"
save_state

# ── Step 2: Registry Instance ─────────────────────────────────────────────────

log "Creating registry ENI..."
REGISTRY_ENI_ID=$(aws ec2 create-network-interface \
  --subnet-id ${SUBNET_ID} --groups ${SG_ID} \
  --private-ip-address ${REGISTRY_IP} \
  --description "Mirror registry ENI" \
  --query 'NetworkInterface.NetworkInterfaceId' --output text)

log "Allocating registry EIP..."
REGISTRY_EIP_ALLOC=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
REGISTRY_EIP_ADDR=$(aws ec2 describe-addresses --allocation-ids ${REGISTRY_EIP_ALLOC} \
  --query 'Addresses[0].PublicIp' --output text)
log "Registry EIP: ${REGISTRY_EIP_ADDR}"

aws ec2 import-key-pair --key-name ${KEY_NAME} \
  --public-key-material fileb://${SSH_KEY_FILE} 2>/dev/null || true

log "Resolving Amazon Linux 2023 AMI..."
AL2023_AMI=$(aws ec2 describe-images --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' --output text)
log "AL2023 AMI: ${AL2023_AMI}"

log "Launching registry instance..."
USERDATA=$(cat <<USERDATA
#!/bin/bash
set -ex
dnf install -y docker openssl httpd-tools
systemctl enable --now docker
mkdir -p /opt/registry/{certs,data,auth}
openssl req -newkey rsa:4096 -nodes -sha256 \
  -keyout /opt/registry/certs/domain.key \
  -x509 -days 365 \
  -subj "/CN=${REGISTRY_IP}" \
  -addext "subjectAltName=IP:${REGISTRY_IP},IP:127.0.0.1" \
  -out /opt/registry/certs/domain.crt
htpasswd -bBc /opt/registry/auth/htpasswd ${REGISTRY_USER} ${REGISTRY_PASS}
docker run -d --name mirror-registry -p ${REGISTRY_PORT}:5000 --restart=always \
  -v /opt/registry/data:/var/lib/registry \
  -v /opt/registry/certs:/certs \
  -v /opt/registry/auth:/auth \
  -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/domain.crt \
  -e REGISTRY_HTTP_TLS_KEY=/certs/domain.key \
  -e REGISTRY_AUTH=htpasswd \
  -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
  docker.io/library/registry:2
USERDATA
)

REGISTRY_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id ${AL2023_AMI} --instance-type ${REGISTRY_INSTANCE_TYPE} \
  --key-name ${KEY_NAME} \
  --network-interfaces "DeviceIndex=0,NetworkInterfaceId=${REGISTRY_ENI_ID}" \
  --user-data "$(echo "${USERDATA}" | base64 -w0)" \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":200,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER_NAME}-registry}]" \
  --query 'Instances[0].InstanceId' --output text)
aws ec2 wait instance-running --instance-ids ${REGISTRY_INSTANCE_ID}

aws ec2 associate-address --allocation-id ${REGISTRY_EIP_ALLOC} \
  --network-interface-id ${REGISTRY_ENI_ID} >/dev/null
log "Registry instance ${REGISTRY_INSTANCE_ID} running at ${REGISTRY_EIP_ADDR}"
save_state

log "Waiting for registry to be ready (installing packages + starting container)..."
READY=false
for i in $(seq 1 60); do
  if curl -sk --connect-timeout 5 \
    "https://${REGISTRY_EIP_ADDR}:${REGISTRY_PORT}/v2/" \
    -u "${REGISTRY_USER}:${REGISTRY_PASS}" 2>/dev/null | grep -q '{}'; then
    READY=true
    break
  fi
  sleep 10
done
[[ "${READY}" == "true" ]] || die "Registry did not become ready within 10 minutes"
log "Registry is ready at ${REGISTRY_EIP_ADDR}:${REGISTRY_PORT}"

log "Retrieving registry CA certificate..."
SSH_KEY_PRIV="${SSH_KEY_FILE%.pub}"
[[ -f "${SSH_KEY_PRIV}" ]] || die "Private SSH key not found: ${SSH_KEY_PRIV}"
for i in $(seq 1 6); do
  REGISTRY_CA_CERT=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    -i "${SSH_KEY_PRIV}" ec2-user@${REGISTRY_EIP_ADDR} \
    'cat /opt/registry/certs/domain.crt' 2>/dev/null) && break
  sleep 5
done
[[ -n "${REGISTRY_CA_CERT}" ]] || die "Failed to retrieve CA certificate from registry"
echo "${REGISTRY_CA_CERT}" > "${INSTALL_DIR}/registry-ca.crt"
log "CA certificate saved to ${INSTALL_DIR}/registry-ca.crt"

# ── Step 3: Mirror OCP Images ─────────────────────────────────────────────────

mkdir -p "${MIRROR_WORKSPACE}"

cat > "${MIRROR_WORKSPACE}/imageset-config.yaml" <<EOF
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    architectures:
      - amd64
    channels:
      - name: ${OCP_CHANNEL}
        minVersion: ${OCP_VERSION}
        maxVersion: ${OCP_VERSION}
EOF

log "Preparing authentication for mirror registry..."
REGISTRY_AUTH_B64=$(echo -n "${REGISTRY_USER}:${REGISTRY_PASS}" | base64 -w0)
DOCKER_CONFIG_DIR=$(mktemp -d)
jq --arg reg "${REGISTRY_EIP_ADDR}:${REGISTRY_PORT}" \
   --arg auth "${REGISTRY_AUTH_B64}" \
   '.auths[$reg] = {"auth": $auth}' "${PULL_SECRET_FILE}" \
   > "${DOCKER_CONFIG_DIR}/config.json"

log "Mirroring OCP ${OCP_VERSION} to registry (this takes 15-30 minutes)..."
DOCKER_CONFIG="${DOCKER_CONFIG_DIR}" oc-mirror \
  -c "${MIRROR_WORKSPACE}/imageset-config.yaml" \
  --workspace "file://${MIRROR_WORKSPACE}" \
  "docker://${REGISTRY_EIP_ADDR}:${REGISTRY_PORT}" \
  --dest-tls-verify=false \
  --v2

rm -rf "${DOCKER_CONFIG_DIR}"

IDMS_DIR="${MIRROR_WORKSPACE}/working-dir/cluster-resources"
IDMS_FILE=$(find "${IDMS_DIR}" -name "idms-*.yaml" -type f 2>/dev/null | head -1)
[[ -n "${IDMS_FILE}" ]] || die "No IDMS file found in ${IDMS_DIR} — oc-mirror may have failed"
log "Mirror complete. IDMS: ${IDMS_FILE}"

log "Parsing IDMS for imageContentSources..."
IMAGE_CONTENT_SOURCES=$(awk -v eip="${REGISTRY_EIP_ADDR}" -v pip="${REGISTRY_IP}" '
  /^  imageDigestMirrors:/ { in_mirrors=1; next }
  in_mirrors && /^  - mirrors:/ { next }
  in_mirrors && /^    - / && !/source:/ {
    mirror=$2; gsub(eip, pip, mirror); current_mirror=mirror; next
  }
  in_mirrors && /source:/ {
    src=$2
    printf "\n  - mirrors:\n    - %s\n    source: %s", current_mirror, src
    next
  }
  in_mirrors && /^[^ ]/ { in_mirrors=0 }
' "${IDMS_DIR}"/idms-*.yaml)

[[ -n "${IMAGE_CONTENT_SOURCES}" ]] || die "Failed to parse imageContentSources from IDMS"
log "Extracted imageContentSources entries"

# ── Step 4: OCP Node ENI, EIP, DNS ────────────────────────────────────────────

log "Creating OCP node ENI..."
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
save_state

# ── Step 5: Generate Agent ISO ─────────────────────────────────────────────────

PULL_SECRET=$(cat "${PULL_SECRET_FILE}")
SSH_KEY=$(cat "${SSH_KEY_FILE}")

INSTALL_PULL_SECRET=$(jq --arg reg "${REGISTRY_IP}:${REGISTRY_PORT}" \
  --arg auth "${REGISTRY_AUTH_B64}" \
  '.auths[$reg] = {"auth": $auth}' "${PULL_SECRET_FILE}" | jq -c .)

CA_BUNDLE=$(cat "${INSTALL_DIR}/registry-ca.crt")

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
imageContentSources:${IMAGE_CONTENT_SOURCES}
additionalTrustBundle: |
$(echo "${CA_BUNDLE}" | sed 's/^/  /')
pullSecret: '${INSTALL_PULL_SECRET}'
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

# ── Step 6: Convert ISO to AMI ─────────────────────────────────────────────────

log "Converting ISO to raw disk..."
qemu-img convert -f raw -O raw agent.x86_64.iso agent.x86_64.raw

BUCKET_NAME="openshift-agent-iso-${CLUSTER_NAME}-$(date +%s)"
aws s3 mb s3://${BUCKET_NAME} >/dev/null
aws s3 cp agent.x86_64.raw s3://${BUCKET_NAME}/agent.x86_64.raw --quiet

ROLE_CREATED=false
aws iam create-role --role-name vmimport \
  --assume-role-policy-document '{
    "Version":"2012-10-17","Statement":[{"Effect":"Allow",
    "Principal":{"Service":"vmie.amazonaws.com"},
    "Action":"sts:AssumeRole",
    "Condition":{"StringEquals":{"sts:Externalid":"vmimport"}}}]
  }' 2>/dev/null && ROLE_CREATED=true || true

aws iam put-role-policy --role-name vmimport --policy-name vmimport-s3-policy \
  --policy-document "{
    \"Version\":\"2012-10-17\",\"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"s3:GetBucketLocation\",\"s3:GetObject\",\"s3:ListBucket\"],
     \"Resource\":[\"arn:aws:s3:::${BUCKET_NAME}\",\"arn:aws:s3:::${BUCKET_NAME}/*\"]},
    {\"Effect\":\"Allow\",\"Action\":[\"ec2:ModifySnapshotAttribute\",\"ec2:CopySnapshot\",
     \"ec2:RegisterImage\",\"ec2:Describe*\"],\"Resource\":\"*\"}]
  }"

if [[ "${ROLE_CREATED}" == "true" ]]; then
  log "Waiting for vmimport IAM role to propagate..."
  sleep 15
fi

log "Importing EBS snapshot..."
IMPORT_TASK=$(aws ec2 import-snapshot \
  --description "${CLUSTER_NAME} disconnected agent ISO" \
  --disk-container "{\"Format\":\"RAW\",\"UserBucket\":{\"S3Bucket\":\"${BUCKET_NAME}\",\"S3Key\":\"agent.x86_64.raw\"}}" \
  --query 'ImportTaskId' --output text)
[[ -z "${IMPORT_TASK}" || "${IMPORT_TASK}" == "None" ]] && die "import-snapshot returned empty task ID — check vmimport role and S3 permissions"

while true; do
  STATUS_JSON=$(aws ec2 describe-import-snapshot-tasks \
    --import-task-ids ${IMPORT_TASK} \
    --query 'ImportSnapshotTasks[0].SnapshotTaskDetail' --output json)
  STAT=$(echo "$STATUS_JSON" | jq -r '.Status')
  PROG=$(echo "$STATUS_JSON" | jq -r '.Progress // "?"')
  log "  ${STAT} (${PROG}%)"
  if [[ "$STAT" == "completed" ]]; then
    SNAP_ID=$(echo "$STATUS_JSON" | jq -r '.SnapshotId')
    [[ -z "${SNAP_ID}" || "${SNAP_ID}" == "null" ]] && die "Snapshot import completed but no SnapshotId returned"
    break
  fi
  [[ "$STAT" == "error" ]] && die "Snapshot import failed: $(echo "$STATUS_JSON" | jq -r '.StatusMessage // "unknown error"')"
  sleep 15
done

AMI_ID=$(aws ec2 register-image \
  --name "${CLUSTER_NAME}-disconnected-agent-$(date +%Y%m%d%H%M)" \
  --architecture x86_64 --root-device-name /dev/sda1 \
  --boot-mode uefi-preferred --ena-support --virtualization-type hvm \
  --block-device-mappings "[
    {\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"SnapshotId\":\"${SNAP_ID}\",
      \"VolumeSize\":${ISO_DISK_SIZE},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}},
    {\"DeviceName\":\"/dev/sdb\",\"Ebs\":{\"VolumeSize\":${INSTALL_DISK_SIZE},
      \"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}
  ]" --query 'ImageId' --output text)
log "AMI: ${AMI_ID}"

# ── Step 7: Launch Instance ────────────────────────────────────────────────────

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
save_state

# ── Step 8: Monitor Installation ───────────────────────────────────────────────

log "Monitoring installation (25-40 minutes)..."
openshift-install agent wait-for install-complete --dir=. --log-level=info

export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"
echo ""
log "═══════════════════════════════════"
log "  Disconnected SNO installation complete!"
log "═══════════════════════════════════"
echo ""
echo "Console:  https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
echo "API:      https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443"
echo "Password: $(cat ${INSTALL_DIR}/auth/kubeadmin-password)"
echo "Config:   export KUBECONFIG=${INSTALL_DIR}/auth/kubeconfig"
echo "Registry: https://${REGISTRY_EIP_ADDR}:${REGISTRY_PORT}/v2/_catalog"
