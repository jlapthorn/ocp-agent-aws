#!/usr/bin/env bash
set -euo pipefail

#
# Deploy a 3+3 OpenShift cluster on AWS EC2 using the Agent-Based Installer.
#
# Prerequisites:
#   - openshift-install, oc, qemu-img, aws CLI v2, jq
#   - A Route 53 hosted zone for your base domain
#   - A pull secret (pull-secret.json) and SSH key pair
#
# Usage:
#   export CLUSTER_NAME=ocp
#   export BASE_DOMAIN=example.com
#   export INSTALL_DIR=~/ocp-agent-aws
#   export PULL_SECRET_FILE=~/pull-secret.json
#   export SSH_KEY_FILE=~/.ssh/id_ed25519.pub
#   export AWS_REGION=us-east-2
#   ./deploy-multi-node.sh
#

# ── Configuration ──────────────────────────────────────────────────────────────

CLUSTER_NAME="${CLUSTER_NAME:?Set CLUSTER_NAME (e.g. ocp)}"
BASE_DOMAIN="${BASE_DOMAIN:?Set BASE_DOMAIN (e.g. example.com)}"
INSTALL_DIR="${INSTALL_DIR:?Set INSTALL_DIR (e.g. ~/ocp-agent-aws)}"
PULL_SECRET_FILE="${PULL_SECRET_FILE:?Set PULL_SECRET_FILE}"
SSH_KEY_FILE="${SSH_KEY_FILE:?Set SSH_KEY_FILE}"
AWS_REGION="${AWS_REGION:-us-east-2}"
AZ="${AWS_REGION}a"

VPC_CIDR="10.0.0.0/16"
SUBNET_CIDR="10.0.1.0/24"
VPC_DNS="10.0.0.2"

MASTER_IPS=("10.0.1.101" "10.0.1.102" "10.0.1.103")
WORKER_IPS=("10.0.1.111" "10.0.1.112" "10.0.1.113")
MASTER_HOSTNAMES=("master-0" "master-1" "master-2")
WORKER_HOSTNAMES=("worker-0" "worker-1" "worker-2")

MASTER_INSTANCE_TYPE="m5.2xlarge"   # 32 GiB RAM — masters require ≥16 GiB usable
WORKER_INSTANCE_TYPE="m5.xlarge"    # 16 GiB RAM — workers require ≥8 GiB usable
ISO_DISK_SIZE=16                    # GB — just enough for the agent ISO
INSTALL_DISK_SIZE=120               # GB — RHCOS install target

KEY_NAME="ocp-agent-key"

# ── Helper functions ───────────────────────────────────────────────────────────

log() { echo "$(date +%H:%M:%S) ── $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

check_prereqs() {
  for cmd in openshift-install oc qemu-img aws jq; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found in PATH"
  done
  [[ -f "$PULL_SECRET_FILE" ]] || die "Pull secret not found: $PULL_SECRET_FILE"
  [[ -f "$SSH_KEY_FILE" ]] || die "SSH key not found: $SSH_KEY_FILE"
}

save_state() {
  cat > "${INSTALL_DIR}/resource-ids.env" <<EOF
CLUSTER_NAME=${CLUSTER_NAME:-}
BASE_DOMAIN=${BASE_DOMAIN:-}
VPC_ID=${VPC_ID:-}
SUBNET_ID=${SUBNET_ID:-}
IGW_ID=${IGW_ID:-}
SG_ID=${SG_ID:-}
MASTER_ENI_IDS=(${MASTER_ENI_IDS[*]:-})
WORKER_ENI_IDS=(${WORKER_ENI_IDS[*]:-})
MASTER_MACS=(${MASTER_MACS[*]:-})
WORKER_MACS=(${WORKER_MACS[*]:-})
BUCKET_NAME=${BUCKET_NAME:-}
SNAP_ID=${SNAP_ID:-}
AMI_ID=${AMI_ID:-}
API_NLB_ARN=${API_NLB_ARN:-}
API_NLB_DNS=${API_NLB_DNS:-}
API_NLB_ZONE=${API_NLB_ZONE:-}
INGRESS_NLB_ARN=${INGRESS_NLB_ARN:-}
INGRESS_NLB_DNS=${INGRESS_NLB_DNS:-}
INGRESS_NLB_ZONE=${INGRESS_NLB_ZONE:-}
API_TG_ARN=${API_TG_ARN:-}
MCS_TG_ARN=${MCS_TG_ARN:-}
HTTP_TG_ARN=${HTTP_TG_ARN:-}
HTTPS_TG_ARN=${HTTPS_TG_ARN:-}
MASTER_INSTANCE_IDS=(${MASTER_INSTANCE_IDS[*]:-})
WORKER_INSTANCE_IDS=(${WORKER_INSTANCE_IDS[*]:-})
ZONE_ID=${ZONE_ID:-}
KEY_NAME=${KEY_NAME:-}
EOF
}

# ── Preflight ──────────────────────────────────────────────────────────────────

check_prereqs
mkdir -p "${INSTALL_DIR}"
log "Install directory: ${INSTALL_DIR}"

# ── Step 1: VPC and Networking ─────────────────────────────────────────────────

log "Creating VPC..."
VPC_ID=$(aws ec2 create-vpc --cidr-block ${VPC_CIDR} \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id ${VPC_ID} --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id ${VPC_ID} --enable-dns-hostnames '{"Value":true}'
aws ec2 create-tags --resources ${VPC_ID} --tags Key=Name,Value=${CLUSTER_NAME}-vpc
log "VPC: ${VPC_ID}"

log "Creating subnet..."
SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id ${VPC_ID} --cidr-block ${SUBNET_CIDR} --availability-zone ${AZ} \
  --query 'Subnet.SubnetId' --output text)
aws ec2 modify-subnet-attribute --subnet-id ${SUBNET_ID} --map-public-ip-on-launch
log "Subnet: ${SUBNET_ID}"

log "Creating internet gateway..."
IGW_ID=$(aws ec2 create-internet-gateway \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id ${IGW_ID} --vpc-id ${VPC_ID}
RTB_ID=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'RouteTables[0].RouteTableId' --output text)
aws ec2 create-route --route-table-id ${RTB_ID} \
  --destination-cidr-block 0.0.0.0/0 --gateway-id ${IGW_ID} >/dev/null
log "IGW: ${IGW_ID}"

log "Creating security group..."
SG_ID=$(aws ec2 create-security-group \
  --group-name ${CLUSTER_NAME}-sg \
  --description "OpenShift ${CLUSTER_NAME} security group" \
  --vpc-id ${VPC_ID} --query 'GroupId' --output text)

# Inbound rules
for PORT in 22 80 443 6443 22623; do
  aws ec2 authorize-security-group-ingress \
    --group-id ${SG_ID} --protocol tcp --port ${PORT} --cidr 0.0.0.0/0 >/dev/null
done

# NodePort range
aws ec2 authorize-security-group-ingress \
  --group-id ${SG_ID} --protocol tcp --port 30000-32767 --cidr 0.0.0.0/0 >/dev/null

# Intra-cluster: all traffic from self
aws ec2 authorize-security-group-ingress \
  --group-id ${SG_ID} --protocol -1 --source-group ${SG_ID} >/dev/null

# ICMP
aws ec2 authorize-security-group-ingress \
  --group-id ${SG_ID} --protocol icmp --port -1 --cidr 0.0.0.0/0 >/dev/null

# VXLAN/Geneve (OVN)
aws ec2 authorize-security-group-ingress \
  --group-id ${SG_ID} --protocol udp --port 4789 --cidr ${SUBNET_CIDR} >/dev/null
aws ec2 authorize-security-group-ingress \
  --group-id ${SG_ID} --protocol udp --port 6081 --cidr ${SUBNET_CIDR} >/dev/null

log "SG: ${SG_ID}"

# ── Step 2: Pre-create ENIs ────────────────────────────────────────────────────

log "Creating ENIs..."
MASTER_ENI_IDS=()
MASTER_MACS=()
for i in 0 1 2; do
  eni_id=$(aws ec2 create-network-interface \
    --subnet-id ${SUBNET_ID} --groups ${SG_ID} \
    --private-ip-address ${MASTER_IPS[$i]} \
    --description "OCP ${MASTER_HOSTNAMES[$i]}" \
    --query 'NetworkInterface.NetworkInterfaceId' --output text)
  mac=$(aws ec2 describe-network-interfaces \
    --network-interface-ids ${eni_id} \
    --query 'NetworkInterfaces[0].MacAddress' --output text)
  MASTER_ENI_IDS+=("${eni_id}")
  MASTER_MACS+=("${mac}")
  log "  ${MASTER_HOSTNAMES[$i]}: ${eni_id} (${mac})"
done

WORKER_ENI_IDS=()
WORKER_MACS=()
for i in 0 1 2; do
  eni_id=$(aws ec2 create-network-interface \
    --subnet-id ${SUBNET_ID} --groups ${SG_ID} \
    --private-ip-address ${WORKER_IPS[$i]} \
    --description "OCP ${WORKER_HOSTNAMES[$i]}" \
    --query 'NetworkInterface.NetworkInterfaceId' --output text)
  mac=$(aws ec2 describe-network-interfaces \
    --network-interface-ids ${eni_id} \
    --query 'NetworkInterfaces[0].MacAddress' --output text)
  WORKER_ENI_IDS+=("${eni_id}")
  WORKER_MACS+=("${mac}")
  log "  ${WORKER_HOSTNAMES[$i]}: ${eni_id} (${mac})"
done

# ── Step 3: EC2 Key Pair ──────────────────────────────────────────────────────

log "Importing SSH key pair..."
aws ec2 import-key-pair \
  --key-name ${KEY_NAME} \
  --public-key-material fileb://${SSH_KEY_FILE} 2>/dev/null \
  || log "  Key pair ${KEY_NAME} already exists"

# ── Step 4: Network Load Balancers ────────────────────────────────────────────

log "Creating API NLB..."
API_NLB_ARN=$(aws elbv2 create-load-balancer \
  --name ${CLUSTER_NAME}-api-nlb --type network \
  --subnets ${SUBNET_ID} --scheme internet-facing \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
API_NLB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns ${API_NLB_ARN} \
  --query 'LoadBalancers[0].DNSName' --output text)
API_NLB_ZONE=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns ${API_NLB_ARN} \
  --query 'LoadBalancers[0].CanonicalHostedZoneId' --output text)
log "API NLB: ${API_NLB_DNS}"

log "Creating Ingress NLB..."
INGRESS_NLB_ARN=$(aws elbv2 create-load-balancer \
  --name ${CLUSTER_NAME}-ingress-nlb --type network \
  --subnets ${SUBNET_ID} --scheme internet-facing \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
INGRESS_NLB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns ${INGRESS_NLB_ARN} \
  --query 'LoadBalancers[0].DNSName' --output text)
INGRESS_NLB_ZONE=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns ${INGRESS_NLB_ARN} \
  --query 'LoadBalancers[0].CanonicalHostedZoneId' --output text)
log "Ingress NLB: ${INGRESS_NLB_DNS}"

# Target groups
log "Creating target groups..."
API_TG_ARN=$(aws elbv2 create-target-group \
  --name ${CLUSTER_NAME}-api-6443 --protocol TCP --port 6443 \
  --vpc-id ${VPC_ID} --target-type ip \
  --health-check-protocol TCP --health-check-port 6443 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

MCS_TG_ARN=$(aws elbv2 create-target-group \
  --name ${CLUSTER_NAME}-mcs-22623 --protocol TCP --port 22623 \
  --vpc-id ${VPC_ID} --target-type ip \
  --health-check-protocol TCP --health-check-port 22623 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

HTTP_TG_ARN=$(aws elbv2 create-target-group \
  --name ${CLUSTER_NAME}-ingress-80 --protocol TCP --port 80 \
  --vpc-id ${VPC_ID} --target-type ip \
  --health-check-protocol TCP --health-check-port 80 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

HTTPS_TG_ARN=$(aws elbv2 create-target-group \
  --name ${CLUSTER_NAME}-ingress-443 --protocol TCP --port 443 \
  --vpc-id ${VPC_ID} --target-type ip \
  --health-check-protocol TCP --health-check-port 443 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Register master IPs in API and MCS target groups
for ip in "${MASTER_IPS[@]}"; do
  aws elbv2 register-targets --target-group-arn ${API_TG_ARN} \
    --targets Id=${ip} >/dev/null
  aws elbv2 register-targets --target-group-arn ${MCS_TG_ARN} \
    --targets Id=${ip} >/dev/null
done

# Register all node IPs in ingress target groups
for ip in "${MASTER_IPS[@]}" "${WORKER_IPS[@]}"; do
  aws elbv2 register-targets --target-group-arn ${HTTP_TG_ARN} \
    --targets Id=${ip} >/dev/null
  aws elbv2 register-targets --target-group-arn ${HTTPS_TG_ARN} \
    --targets Id=${ip} >/dev/null
done

# Listeners
aws elbv2 create-listener --load-balancer-arn ${API_NLB_ARN} \
  --protocol TCP --port 6443 \
  --default-actions Type=forward,TargetGroupArn=${API_TG_ARN} >/dev/null

aws elbv2 create-listener --load-balancer-arn ${API_NLB_ARN} \
  --protocol TCP --port 22623 \
  --default-actions Type=forward,TargetGroupArn=${MCS_TG_ARN} >/dev/null

aws elbv2 create-listener --load-balancer-arn ${INGRESS_NLB_ARN} \
  --protocol TCP --port 80 \
  --default-actions Type=forward,TargetGroupArn=${HTTP_TG_ARN} >/dev/null

aws elbv2 create-listener --load-balancer-arn ${INGRESS_NLB_ARN} \
  --protocol TCP --port 443 \
  --default-actions Type=forward,TargetGroupArn=${HTTPS_TG_ARN} >/dev/null

log "Target groups and listeners created"

# ── Step 5: DNS Records ───────────────────────────────────────────────────────

log "Creating DNS records..."
ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "${BASE_DOMAIN}" \
  --query 'HostedZones[0].Id' --output text | sed 's|/hostedzone/||')

[[ -z "${ZONE_ID}" || "${ZONE_ID}" == "None" ]] && die "No Route 53 hosted zone found for ${BASE_DOMAIN}"

aws route53 change-resource-record-sets --hosted-zone-id ${ZONE_ID} \
  --change-batch "{
    \"Changes\": [
      {\"Action\":\"UPSERT\",\"ResourceRecordSet\":{
        \"Name\":\"api.${CLUSTER_NAME}.${BASE_DOMAIN}\",\"Type\":\"A\",
        \"AliasTarget\":{\"HostedZoneId\":\"${API_NLB_ZONE}\",
          \"DNSName\":\"${API_NLB_DNS}\",\"EvaluateTargetHealth\":true}}},
      {\"Action\":\"UPSERT\",\"ResourceRecordSet\":{
        \"Name\":\"api-int.${CLUSTER_NAME}.${BASE_DOMAIN}\",\"Type\":\"A\",
        \"AliasTarget\":{\"HostedZoneId\":\"${API_NLB_ZONE}\",
          \"DNSName\":\"${API_NLB_DNS}\",\"EvaluateTargetHealth\":true}}},
      {\"Action\":\"UPSERT\",\"ResourceRecordSet\":{
        \"Name\":\"*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}\",\"Type\":\"A\",
        \"AliasTarget\":{\"HostedZoneId\":\"${INGRESS_NLB_ZONE}\",
          \"DNSName\":\"${INGRESS_NLB_DNS}\",\"EvaluateTargetHealth\":true}}}
    ]
  }" >/dev/null

log "DNS: api.${CLUSTER_NAME}.${BASE_DOMAIN} → API NLB"
log "DNS: *.apps.${CLUSTER_NAME}.${BASE_DOMAIN} → Ingress NLB"

# ── Step 6: Generate Agent ISO ─────────────────────────────────────────────────

log "Generating install-config.yaml..."
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
  - architecture: amd64
    hyperthreading: Enabled
    name: worker
    replicas: 3
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  replicas: 3
platform:
  none: {}
pullSecret: '${PULL_SECRET}'
sshKey: '${SSH_KEY}'
EOF

log "Generating agent-config.yaml..."
cat > "${INSTALL_DIR}/agent-config.yaml" <<EOF
apiVersion: v1beta1
kind: AgentConfig
metadata:
  name: ${CLUSTER_NAME}
rendezvousIP: ${MASTER_IPS[0]}
hosts:
EOF

for i in 0 1 2; do
  cat >> "${INSTALL_DIR}/agent-config.yaml" <<EOF
  - hostname: ${MASTER_HOSTNAMES[$i]}
    role: master
    rootDeviceHints:
      minSizeGigabytes: 100
    interfaces:
      - name: ens5
        macAddress: "${MASTER_MACS[$i]}"
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

for i in 0 1 2; do
  cat >> "${INSTALL_DIR}/agent-config.yaml" <<EOF
  - hostname: ${WORKER_HOSTNAMES[$i]}
    role: worker
    rootDeviceHints:
      minSizeGigabytes: 100
    interfaces:
      - name: ens5
        macAddress: "${WORKER_MACS[$i]}"
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

log "Generating agent ISO..."
cd "${INSTALL_DIR}"
openshift-install agent create image --dir=. --log-level=info
log "ISO generated: ${INSTALL_DIR}/agent.x86_64.iso"

# ── Step 7: Convert ISO to AMI ─────────────────────────────────────────────────

log "Converting ISO to raw disk..."
qemu-img convert -f raw -O raw agent.x86_64.iso agent.x86_64.raw

log "Creating S3 bucket and uploading..."
BUCKET_NAME="openshift-agent-iso-${CLUSTER_NAME}-$(date +%s)"
aws s3 mb s3://${BUCKET_NAME} >/dev/null
aws s3 cp agent.x86_64.raw s3://${BUCKET_NAME}/agent.x86_64.raw --quiet

log "Ensuring vmimport IAM role exists..."
ROLE_CREATED=false
aws iam create-role --role-name vmimport \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "vmie.amazonaws.com"},
      "Action": "sts:AssumeRole",
      "Condition": {"StringEquals": {"sts:Externalid": "vmimport"}}
    }]
  }' 2>/dev/null && ROLE_CREATED=true || true

aws iam put-role-policy --role-name vmimport \
  --policy-name vmimport-s3-policy \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": [\"s3:GetBucketLocation\",\"s3:GetObject\",\"s3:ListBucket\"],
      \"Resource\": [\"arn:aws:s3:::${BUCKET_NAME}\",\"arn:aws:s3:::${BUCKET_NAME}/*\"]
    },{
      \"Effect\": \"Allow\",
      \"Action\": [\"ec2:ModifySnapshotAttribute\",\"ec2:CopySnapshot\",
                   \"ec2:RegisterImage\",\"ec2:Describe*\"],
      \"Resource\": \"*\"
    }]
  }"

# IAM role propagation can take 10-15 seconds on first creation
if [[ "${ROLE_CREATED}" == "true" ]]; then
  log "Waiting for vmimport IAM role to propagate..."
  sleep 15
fi

log "Importing EBS snapshot (this takes 5-10 minutes)..."
IMPORT_TASK=$(aws ec2 import-snapshot \
  --description "${CLUSTER_NAME} agent ISO" \
  --disk-container "{
    \"Format\": \"RAW\",
    \"UserBucket\": {\"S3Bucket\": \"${BUCKET_NAME}\", \"S3Key\": \"agent.x86_64.raw\"}
  }" --query 'ImportTaskId' --output text)

while true; do
  STATUS_JSON=$(aws ec2 describe-import-snapshot-tasks \
    --import-task-ids ${IMPORT_TASK} \
    --query 'ImportSnapshotTasks[0].SnapshotTaskDetail' --output json)
  STAT=$(echo "$STATUS_JSON" | jq -r '.Status')
  PROG=$(echo "$STATUS_JSON" | jq -r '.Progress // "?"')
  log "  Snapshot import: ${STAT} (${PROG}%)"
  if [[ "$STAT" == "completed" ]]; then
    SNAP_ID=$(echo "$STATUS_JSON" | jq -r '.SnapshotId')
    break
  elif [[ "$STAT" == "error" ]]; then
    die "Snapshot import failed"
  fi
  sleep 15
done
log "Snapshot: ${SNAP_ID}"

log "Registering AMI with asymmetric disk sizes (${ISO_DISK_SIZE}GB boot + ${INSTALL_DISK_SIZE}GB target)..."
AMI_ID=$(aws ec2 register-image \
  --name "${CLUSTER_NAME}-agent-$(date +%Y%m%d%H%M)" \
  --description "OpenShift ${CLUSTER_NAME} agent ISO" \
  --architecture x86_64 \
  --root-device-name /dev/sda1 \
  --boot-mode uefi-preferred \
  --ena-support \
  --virtualization-type hvm \
  --block-device-mappings "[
    {\"DeviceName\":\"/dev/sda1\",\"Ebs\":{
      \"SnapshotId\":\"${SNAP_ID}\",\"VolumeSize\":${ISO_DISK_SIZE},
      \"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}},
    {\"DeviceName\":\"/dev/sdb\",\"Ebs\":{
      \"VolumeSize\":${INSTALL_DISK_SIZE},\"VolumeType\":\"gp3\",
      \"DeleteOnTermination\":true}}
  ]" --query 'ImageId' --output text)
log "AMI: ${AMI_ID}"

# ── Step 8: Launch Instances ───────────────────────────────────────────────────

log "Launching master instances (${MASTER_INSTANCE_TYPE})..."
MASTER_INSTANCE_IDS=()
for i in 0 1 2; do
  iid=$(aws ec2 run-instances \
    --image-id ${AMI_ID} \
    --instance-type ${MASTER_INSTANCE_TYPE} \
    --key-name ${KEY_NAME} \
    --network-interfaces "DeviceIndex=0,NetworkInterfaceId=${MASTER_ENI_IDS[$i]}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER_NAME}-${MASTER_HOSTNAMES[$i]}}]" \
    --query 'Instances[0].InstanceId' --output text)
  MASTER_INSTANCE_IDS+=("${iid}")
  log "  ${MASTER_HOSTNAMES[$i]}: ${iid}"
done

log "Launching worker instances (${WORKER_INSTANCE_TYPE})..."
WORKER_INSTANCE_IDS=()
for i in 0 1 2; do
  iid=$(aws ec2 run-instances \
    --image-id ${AMI_ID} \
    --instance-type ${WORKER_INSTANCE_TYPE} \
    --key-name ${KEY_NAME} \
    --network-interfaces "DeviceIndex=0,NetworkInterfaceId=${WORKER_ENI_IDS[$i]}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER_NAME}-${WORKER_HOSTNAMES[$i]}}]" \
    --query 'Instances[0].InstanceId' --output text)
  WORKER_INSTANCE_IDS+=("${iid}")
  log "  ${WORKER_HOSTNAMES[$i]}: ${iid}"
done

ALL_IDS=("${MASTER_INSTANCE_IDS[@]}" "${WORKER_INSTANCE_IDS[@]}")
log "Waiting for all instances to reach running state..."
aws ec2 wait instance-running --instance-ids "${ALL_IDS[@]}"
log "All 6 instances running"

save_state

# ── Step 9: Monitor Installation ───────────────────────────────────────────────

log "Monitoring installation (this takes 25-45 minutes)..."
log "You can also monitor from another terminal:"
log "  cd ${INSTALL_DIR}"
log "  openshift-install agent wait-for install-complete --dir=."

openshift-install agent wait-for install-complete --dir=. --log-level=info

# ── Step 10: Verify ───────────────────────────────────────────────────────────

export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

echo ""
log "═══════════════════════════════════════════════════════════"
log "  Cluster installation complete!"
log "═══════════════════════════════════════════════════════════"
echo ""
echo "Nodes:"
oc get nodes
echo ""
echo "Cluster Version:"
oc get clusterversion
echo ""
echo "Console:  https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
echo "API:      https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443"
echo "Password: $(cat ${INSTALL_DIR}/auth/kubeadmin-password)"
echo "Config:   export KUBECONFIG=${INSTALL_DIR}/auth/kubeconfig"
echo ""
echo "Resource IDs saved to: ${INSTALL_DIR}/resource-ids.env"
