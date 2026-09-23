# Single Node OpenShift (SNO) on AWS EC2 — Agent-Based Installer

This guide walks through deploying a Single Node OpenShift cluster on AWS EC2 using the Agent-Based Installer. SNO runs the full OpenShift control plane and worker capabilities on a single node.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                  AWS VPC (10.0.0.0/16)                   │
│                                                          │
│   ┌──────────────────────────────────────────────────┐   │
│   │              Subnet (10.0.1.0/24)                │   │
│   │                                                  │   │
│   │   ┌──────────────────────────────────────────┐   │   │
│   │   │   EC2 Instance (m6i.2xlarge)             │   │   │
│   │   │                                          │   │   │
│   │   │   ENI ──── 10.0.1.100 (private)          │   │   │
│   │   │              │                           │   │   │
│   │   │              └── EIP (public)            │   │   │
│   │   │                                          │   │   │
│   │   │   nvme0n1 ── 16 GB (boot ISO / AMI)      │   │   │
│   │   │   nvme1n1 ── 120 GB (RHCOS install)      │   │   │
│   │   └──────────────────────────────────────────┘   │   │
│   └──────────────────────────────────────────────────┘   │
│                                                          │
│   Internet Gateway ──── Route Table (0.0.0.0/0 → IGW)   │
└──────────────────────────────────────────────────────────┘

Route 53:  api.sno.example.com      → EIP
           api-int.sno.example.com  → EIP
           *.apps.sno.example.com   → EIP
```

SNO uses an Elastic IP pointed directly at the node — no load balancer needed.

## Automated Deployment

```bash
export CLUSTER_NAME=sno
export BASE_DOMAIN=example.com
export INSTALL_DIR=~/sno-agent-aws
export PULL_SECRET_FILE=~/pull-secret.json
export SSH_KEY_FILE=~/.ssh/id_ed25519.pub
export AWS_REGION=us-east-2

./scripts/deploy-sno.sh
```

## Step-by-Step Guide

### Step 1 — AWS Networking

Create VPC, subnet, internet gateway, and security group:

```bash
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id ${VPC_ID} --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id ${VPC_ID} --enable-dns-hostnames '{"Value":true}'

SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id ${VPC_ID} --cidr-block 10.0.1.0/24 --availability-zone us-east-2a \
  --query 'Subnet.SubnetId' --output text)
aws ec2 modify-subnet-attribute --subnet-id ${SUBNET_ID} --map-public-ip-on-launch

IGW_ID=$(aws ec2 create-internet-gateway \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id ${IGW_ID} --vpc-id ${VPC_ID}
RTB_ID=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'RouteTables[0].RouteTableId' --output text)
aws ec2 create-route --route-table-id ${RTB_ID} \
  --destination-cidr-block 0.0.0.0/0 --gateway-id ${IGW_ID}

SG_ID=$(aws ec2 create-security-group \
  --group-name sno-sg --description "SNO security group" \
  --vpc-id ${VPC_ID} --query 'GroupId' --output text)

for PORT in 22 80 443 6443 22623; do
  aws ec2 authorize-security-group-ingress \
    --group-id ${SG_ID} --protocol tcp --port ${PORT} --cidr 0.0.0.0/0
done
aws ec2 authorize-security-group-ingress \
  --group-id ${SG_ID} --protocol tcp --port 30000-32767 --cidr 0.0.0.0/0
```

### Step 2 — ENI and Elastic IP

```bash
ENI_ID=$(aws ec2 create-network-interface \
  --subnet-id ${SUBNET_ID} --groups ${SG_ID} \
  --private-ip-address 10.0.1.100 \
  --description "SNO OpenShift ENI" \
  --query 'NetworkInterface.NetworkInterfaceId' --output text)
ENI_MAC=$(aws ec2 describe-network-interfaces \
  --network-interface-ids ${ENI_ID} \
  --query 'NetworkInterfaces[0].MacAddress' --output text)

EIP_ALLOC=$(aws ec2 allocate-address --domain vpc \
  --query 'AllocationId' --output text)
EIP_ADDR=$(aws ec2 describe-addresses \
  --allocation-ids ${EIP_ALLOC} \
  --query 'Addresses[0].PublicIp' --output text)
```

### Step 3 — DNS Records

```bash
ZONE_ID="your-hosted-zone-id"

aws route53 change-resource-record-sets --hosted-zone-id ${ZONE_ID} \
  --change-batch "{
    \"Changes\": [
      {\"Action\":\"UPSERT\",\"ResourceRecordSet\":{
        \"Name\":\"api.sno.example.com\",\"Type\":\"A\",\"TTL\":300,
        \"ResourceRecords\":[{\"Value\":\"${EIP_ADDR}\"}]}},
      {\"Action\":\"UPSERT\",\"ResourceRecordSet\":{
        \"Name\":\"api-int.sno.example.com\",\"Type\":\"A\",\"TTL\":300,
        \"ResourceRecords\":[{\"Value\":\"${EIP_ADDR}\"}]}},
      {\"Action\":\"UPSERT\",\"ResourceRecordSet\":{
        \"Name\":\"*.apps.sno.example.com\",\"Type\":\"A\",\"TTL\":300,
        \"ResourceRecords\":[{\"Value\":\"${EIP_ADDR}\"}]}}
    ]
  }"
```

### Step 4 — Generate Agent ISO

Create `install-config.yaml` and `agent-config.yaml` (see [examples/sno/](../examples/sno/)), then:

```bash
cd ${INSTALL_DIR}
openshift-install agent create image --dir=. --log-level=info
```

### Step 5 — Convert ISO to AMI

```bash
qemu-img convert -f raw -O raw agent.x86_64.iso agent.x86_64.raw

BUCKET_NAME="openshift-agent-iso-sno-$(date +%s)"
aws s3 mb s3://${BUCKET_NAME}
aws s3 cp agent.x86_64.raw s3://${BUCKET_NAME}/agent.x86_64.raw

# Import snapshot (see deploy-sno.sh for the vmimport role setup)
IMPORT_TASK=$(aws ec2 import-snapshot \
  --description "SNO Agent ISO" \
  --disk-container "{\"Format\":\"RAW\",\"UserBucket\":{
    \"S3Bucket\":\"${BUCKET_NAME}\",\"S3Key\":\"agent.x86_64.raw\"}}" \
  --query 'ImportTaskId' --output text)

# Poll until complete, then register AMI with asymmetric disks
AMI_ID=$(aws ec2 register-image \
  --name "sno-agent-$(date +%Y%m%d%H%M)" \
  --architecture x86_64 --root-device-name /dev/sda1 \
  --boot-mode uefi-preferred --ena-support --virtualization-type hvm \
  --block-device-mappings "[
    {\"DeviceName\":\"/dev/sda1\",\"Ebs\":{
      \"SnapshotId\":\"${SNAP_ID}\",\"VolumeSize\":16,
      \"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}},
    {\"DeviceName\":\"/dev/sdb\",\"Ebs\":{
      \"VolumeSize\":120,\"VolumeType\":\"gp3\",
      \"DeleteOnTermination\":true}}
  ]" --query 'ImageId' --output text)
```

### Step 6 — Launch and Monitor

```bash
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id ${AMI_ID} --instance-type m6i.2xlarge \
  --key-name ocp-agent-key \
  --network-interfaces "DeviceIndex=0,NetworkInterfaceId=${ENI_ID}" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=sno-node}]' \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --instance-ids ${INSTANCE_ID}
aws ec2 associate-address --allocation-id ${EIP_ALLOC} --network-interface-id ${ENI_ID}

openshift-install agent wait-for install-complete --dir=. --log-level=info
```

### Step 7 — Verify

```bash
export KUBECONFIG=${INSTALL_DIR}/auth/kubeconfig
oc get nodes
oc get clusterversion
oc get co
```

Installation typically takes 25–40 minutes from instance launch to all operators Available.

## Instance Sizing

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| vCPUs | 8 | 8+ |
| Memory | 32 GiB | 32 GiB+ |
| Storage | 120 GB | 120 GB+ |

`m6i.2xlarge` (8 vCPU, 32 GiB) is the recommended choice. Smaller instances risk failing hardware validation.

## Troubleshooting

See the [troubleshooting section](multi-node-deployment.md#troubleshooting) in the multi-node guide — the same issues and fixes apply to SNO deployments.
