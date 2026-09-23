# Multi-Node OpenShift on AWS EC2 — Agent-Based Installer (3+3)

This guide walks through deploying a 3 control plane + 3 worker OpenShift cluster on AWS EC2 using the Agent-Based Installer. The agent installer produces a bootable ISO containing everything needed — no bootstrap node, no cloud provider integration.

## Architecture

```
                          ┌───────────────────────┐
                          │      Route 53         │
                          │                       │
                          │  api.ocp.example.com  │──→ API NLB
                          │  api-int.ocp.example  │──→ API NLB
                          │  *.apps.ocp.example   │──→ Ingress NLB
                          └───────────────────────┘
                                    │
              ┌─────────────────────┴──────────────────────┐
              │                                            │
   ┌──────────┴──────────┐                    ┌────────────┴────────────┐
   │    API NLB          │                    │    Ingress NLB          │
   │  :6443 → masters    │                    │  :80/:443 → all nodes  │
   │  :22623 → masters   │                    │                        │
   └──────────┬──────────┘                    └────────────┬────────────┘
              │                                            │
   ┌──────────┴────────────────────────────────────────────┴──────────┐
   │                     VPC Subnet (10.0.1.0/24)                     │
   │                                                                  │
   │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
   │  │  master-0   │  │  master-1   │  │  master-2   │              │
   │  │  .101       │  │  .102       │  │  .103       │              │
   │  │  m5.2xlarge │  │  m5.2xlarge │  │  m5.2xlarge │              │
   │  │  ┌───┬───┐  │  │  ┌───┬───┐  │  │  ┌───┬───┐  │              │
   │  │  │16G│120G│  │  │  │16G│120G│  │  │  │16G│120G│  │              │
   │  │  │ISO│RHCOS│ │  │  │ISO│RHCOS│ │  │  │ISO│RHCOS│ │              │
   │  │  └───┴───┘  │  │  └───┴───┘  │  │  └───┴───┘  │              │
   │  └─────────────┘  └─────────────┘  └─────────────┘              │
   │                                                                  │
   │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
   │  │  worker-0   │  │  worker-1   │  │  worker-2   │              │
   │  │  .111       │  │  .112       │  │  .113       │              │
   │  │  m5.xlarge  │  │  m5.xlarge  │  │  m5.xlarge  │              │
   │  │  ┌───┬───┐  │  │  ┌───┬───┐  │  │  ┌───┬───┐  │              │
   │  │  │16G│120G│  │  │  │16G│120G│  │  │  │16G│120G│  │              │
   │  │  │ISO│RHCOS│ │  │  │ISO│RHCOS│ │  │  │ISO│RHCOS│ │              │
   │  │  └───┴───┘  │  │  └───┴───┘  │  │  └───┴───┘  │              │
   │  └─────────────┘  └─────────────┘  └─────────────┘              │
   └──────────────────────────────────────────────────────────────────┘
```

Each instance has two EBS volumes:
- **16 GB** — the agent ISO (boot disk, used only during installation)
- **120 GB** — the RHCOS install target (becomes the boot disk after installation)

## Prerequisites

| Requirement | Details |
|-------------|---------|
| `openshift-install` | Version matching your target OCP release (tested with 4.22.x) |
| `oc` | OpenShift CLI |
| `qemu-img` | For ISO → raw disk conversion |
| AWS CLI v2 | With EC2, S3, ELBv2, Route 53, IAM permissions |
| `jq` | For parsing JSON responses |
| Pull secret | From [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret) |
| Route 53 hosted zone | For your base domain |

## Automated Deployment

The fastest path is the deployment script:

```bash
export CLUSTER_NAME=ocp
export BASE_DOMAIN=example.com
export INSTALL_DIR=~/ocp-agent-aws
export PULL_SECRET_FILE=~/pull-secret.json
export SSH_KEY_FILE=~/.ssh/id_ed25519.pub
export AWS_REGION=us-east-2

./scripts/deploy-multi-node.sh
```

The rest of this guide explains each step for understanding and customization.

## Step 1 — Create AWS Networking

### 1.1 — VPC, Subnet, Internet Gateway

```bash
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id ${VPC_ID} --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id ${VPC_ID} --enable-dns-hostnames '{"Value":true}'
aws ec2 create-tags --resources ${VPC_ID} --tags Key=Name,Value=ocp-vpc

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
```

### 1.2 — Security Group

```bash
SG_ID=$(aws ec2 create-security-group \
  --group-name ocp-sg --description "OpenShift cluster SG" \
  --vpc-id ${VPC_ID} --query 'GroupId' --output text)

# External access
for PORT in 22 80 443 6443 22623; do
  aws ec2 authorize-security-group-ingress \
    --group-id ${SG_ID} --protocol tcp --port ${PORT} --cidr 0.0.0.0/0
done

# NodePort range
aws ec2 authorize-security-group-ingress \
  --group-id ${SG_ID} --protocol tcp --port 30000-32767 --cidr 0.0.0.0/0

# Intra-cluster: all traffic between nodes in the same SG
aws ec2 authorize-security-group-ingress \
  --group-id ${SG_ID} --protocol -1 --source-group ${SG_ID}

# OVN overlay (VXLAN + Geneve)
aws ec2 authorize-security-group-ingress \
  --group-id ${SG_ID} --protocol udp --port 4789 --cidr 10.0.1.0/24
aws ec2 authorize-security-group-ingress \
  --group-id ${SG_ID} --protocol udp --port 6081 --cidr 10.0.1.0/24
```

| Port | Purpose |
|------|---------|
| 22 | SSH access |
| 80, 443 | Ingress (HTTP/HTTPS) |
| 6443 | Kubernetes API |
| 22623 | Machine Config Server |
| 30000–32767 | NodePort services |
| 4789 | VXLAN (OVN overlay) |
| 6081 | Geneve (OVN overlay) |
| Self-referencing | All intra-cluster traffic |

## Step 2 — Create Pre-Provisioned ENIs

The agent-based installer matches hosts by MAC address. Pre-creating ENIs gives you deterministic MACs to embed in the agent configuration before generating the ISO.

```bash
# Master ENIs
for i in 0 1 2; do
  IP="10.0.1.10$((i+1))"
  ENI_ID=$(aws ec2 create-network-interface \
    --subnet-id ${SUBNET_ID} --groups ${SG_ID} \
    --private-ip-address ${IP} \
    --description "OCP master-${i}" \
    --query 'NetworkInterface.NetworkInterfaceId' --output text)
  MAC=$(aws ec2 describe-network-interfaces \
    --network-interface-ids ${ENI_ID} \
    --query 'NetworkInterfaces[0].MacAddress' --output text)
  echo "master-${i}: ENI=${ENI_ID} MAC=${MAC} IP=${IP}"
done

# Worker ENIs
for i in 0 1 2; do
  IP="10.0.1.11$((i+1))"
  ENI_ID=$(aws ec2 create-network-interface \
    --subnet-id ${SUBNET_ID} --groups ${SG_ID} \
    --private-ip-address ${IP} \
    --description "OCP worker-${i}" \
    --query 'NetworkInterface.NetworkInterfaceId' --output text)
  MAC=$(aws ec2 describe-network-interfaces \
    --network-interface-ids ${ENI_ID} \
    --query 'NetworkInterfaces[0].MacAddress' --output text)
  echo "worker-${i}: ENI=${ENI_ID} MAC=${MAC} IP=${IP}"
done
```

Save all ENI IDs and MACs — you need the MACs for `agent-config.yaml` and the ENI IDs when launching instances.

## Step 3 — Network Load Balancers

Multi-node clusters need load balancers for the API and ingress traffic.

### 3.1 — API NLB (ports 6443 and 22623)

```bash
API_NLB_ARN=$(aws elbv2 create-load-balancer \
  --name ocp-api-nlb --type network \
  --subnets ${SUBNET_ID} --scheme internet-facing \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

API_TG_ARN=$(aws elbv2 create-target-group \
  --name ocp-api-6443 --protocol TCP --port 6443 \
  --vpc-id ${VPC_ID} --target-type ip \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

MCS_TG_ARN=$(aws elbv2 create-target-group \
  --name ocp-mcs-22623 --protocol TCP --port 22623 \
  --vpc-id ${VPC_ID} --target-type ip \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Register master IPs
for IP in 10.0.1.101 10.0.1.102 10.0.1.103; do
  aws elbv2 register-targets --target-group-arn ${API_TG_ARN} --targets Id=${IP}
  aws elbv2 register-targets --target-group-arn ${MCS_TG_ARN} --targets Id=${IP}
done

aws elbv2 create-listener --load-balancer-arn ${API_NLB_ARN} \
  --protocol TCP --port 6443 \
  --default-actions Type=forward,TargetGroupArn=${API_TG_ARN}

aws elbv2 create-listener --load-balancer-arn ${API_NLB_ARN} \
  --protocol TCP --port 22623 \
  --default-actions Type=forward,TargetGroupArn=${MCS_TG_ARN}
```

### 3.2 — Ingress NLB (ports 80 and 443)

```bash
INGRESS_NLB_ARN=$(aws elbv2 create-load-balancer \
  --name ocp-ingress-nlb --type network \
  --subnets ${SUBNET_ID} --scheme internet-facing \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

HTTP_TG_ARN=$(aws elbv2 create-target-group \
  --name ocp-ingress-80 --protocol TCP --port 80 \
  --vpc-id ${VPC_ID} --target-type ip \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

HTTPS_TG_ARN=$(aws elbv2 create-target-group \
  --name ocp-ingress-443 --protocol TCP --port 443 \
  --vpc-id ${VPC_ID} --target-type ip \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Register ALL node IPs (masters + workers handle ingress)
for IP in 10.0.1.101 10.0.1.102 10.0.1.103 10.0.1.111 10.0.1.112 10.0.1.113; do
  aws elbv2 register-targets --target-group-arn ${HTTP_TG_ARN} --targets Id=${IP}
  aws elbv2 register-targets --target-group-arn ${HTTPS_TG_ARN} --targets Id=${IP}
done

aws elbv2 create-listener --load-balancer-arn ${INGRESS_NLB_ARN} \
  --protocol TCP --port 80 \
  --default-actions Type=forward,TargetGroupArn=${HTTP_TG_ARN}

aws elbv2 create-listener --load-balancer-arn ${INGRESS_NLB_ARN} \
  --protocol TCP --port 443 \
  --default-actions Type=forward,TargetGroupArn=${HTTPS_TG_ARN}
```

## Step 4 — DNS Records

Create Route 53 alias records pointing to the NLBs:

```bash
ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "example.com" \
  --query 'HostedZones[0].Id' --output text | sed 's|/hostedzone/||')

API_NLB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns ${API_NLB_ARN} \
  --query 'LoadBalancers[0].DNSName' --output text)
NLB_ZONE=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns ${API_NLB_ARN} \
  --query 'LoadBalancers[0].CanonicalHostedZoneId' --output text)
INGRESS_NLB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns ${INGRESS_NLB_ARN} \
  --query 'LoadBalancers[0].DNSName' --output text)

aws route53 change-resource-record-sets --hosted-zone-id ${ZONE_ID} \
  --change-batch "{
    \"Changes\": [
      {\"Action\":\"UPSERT\",\"ResourceRecordSet\":{
        \"Name\":\"api.ocp.example.com\",\"Type\":\"A\",
        \"AliasTarget\":{\"HostedZoneId\":\"${NLB_ZONE}\",
          \"DNSName\":\"${API_NLB_DNS}\",\"EvaluateTargetHealth\":true}}},
      {\"Action\":\"UPSERT\",\"ResourceRecordSet\":{
        \"Name\":\"api-int.ocp.example.com\",\"Type\":\"A\",
        \"AliasTarget\":{\"HostedZoneId\":\"${NLB_ZONE}\",
          \"DNSName\":\"${API_NLB_DNS}\",\"EvaluateTargetHealth\":true}}},
      {\"Action\":\"UPSERT\",\"ResourceRecordSet\":{
        \"Name\":\"*.apps.ocp.example.com\",\"Type\":\"A\",
        \"AliasTarget\":{\"HostedZoneId\":\"${NLB_ZONE}\",
          \"DNSName\":\"${INGRESS_NLB_DNS}\",\"EvaluateTargetHealth\":true}}}
    ]
  }"
```

| Record | Target | Purpose |
|--------|--------|---------|
| `api.ocp.example.com` | API NLB | Kubernetes API (6443) |
| `api-int.ocp.example.com` | API NLB | Internal API + MCS (22623) |
| `*.apps.ocp.example.com` | Ingress NLB | Application routes (80/443) |

## Step 5 — Generate the Agent ISO

### 5.1 — install-config.yaml

```yaml
apiVersion: v1
metadata:
  name: ocp
baseDomain: example.com
networking:
  networkType: OVNKubernetes
  machineNetwork:
    - cidr: 10.0.1.0/24
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
pullSecret: '<your-pull-secret>'
sshKey: '<your-ssh-public-key>'
```

### 5.2 — agent-config.yaml

```yaml
apiVersion: v1beta1
kind: AgentConfig
metadata:
  name: ocp
rendezvousIP: 10.0.1.101    # master-0 runs the assisted-service
hosts:
  - hostname: master-0
    role: master
    rootDeviceHints:
      minSizeGigabytes: 100  # Picks the 120 GB disk, skips the 16 GB ISO
    interfaces:
      - name: ens5
        macAddress: "02:xx:xx:xx:xx:01"  # From master-0 ENI
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
            - 10.0.0.2
  # ... repeat for master-1, master-2, worker-0, worker-1, worker-2
  # See examples/multi-node/agent-config.yaml for the full template
```

Key settings:

| Field | Why |
|-------|-----|
| `rendezvousIP` | The IP of the node that runs the assisted-service during installation. Must be a master. |
| `rootDeviceHints.minSizeGigabytes: 100` | NVMe device names are non-deterministic on EC2. Using disk size avoids the ISO boot disk (16 GB) and always selects the install target (120 GB). |
| `macAddress` | Must match the pre-created ENI's MAC exactly. The agent uses this to match the host to its configuration. |
| `dns-resolver: 10.0.0.2` | AWS VPC DNS resolver (VPC CIDR base + 2). |

### 5.3 — Generate the ISO

```bash
cd ${INSTALL_DIR}
openshift-install agent create image --dir=. --log-level=info
```

This creates `agent.x86_64.iso` and an `auth/` directory with `kubeconfig` and `kubeadmin-password`.

> The installer deletes `install-config.yaml` and `agent-config.yaml` during generation. Save copies if you need to regenerate.

## Step 6 — Convert ISO to AMI

### 6.1 — Convert and upload

```bash
qemu-img convert -f raw -O raw agent.x86_64.iso agent.x86_64.raw

BUCKET_NAME="openshift-agent-iso-ocp-$(date +%s)"
aws s3 mb s3://${BUCKET_NAME}
aws s3 cp agent.x86_64.raw s3://${BUCKET_NAME}/agent.x86_64.raw
```

### 6.2 — Import as EBS snapshot

```bash
IMPORT_TASK=$(aws ec2 import-snapshot \
  --description "OCP agent ISO" \
  --disk-container "{
    \"Format\": \"RAW\",
    \"UserBucket\": {
      \"S3Bucket\": \"${BUCKET_NAME}\",
      \"S3Key\": \"agent.x86_64.raw\"
    }
  }" --query 'ImportTaskId' --output text)

# Poll until complete (5-10 minutes)
while true; do
  STATUS=$(aws ec2 describe-import-snapshot-tasks \
    --import-task-ids ${IMPORT_TASK} \
    --query 'ImportSnapshotTasks[0].SnapshotTaskDetail' --output json)
  STAT=$(echo "$STATUS" | jq -r '.Status')
  echo "$(date +%H:%M:%S) — ${STAT} ($(echo "$STATUS" | jq -r '.Progress // "?"')%)"
  if [ "$STAT" = "completed" ]; then
    SNAP_ID=$(echo "$STATUS" | jq -r '.SnapshotId')
    break
  fi
  sleep 15
done
```

### 6.3 — Register the AMI with asymmetric disk sizes

This is the critical step. The two EBS volumes **must be different sizes**:

```bash
AMI_ID=$(aws ec2 register-image \
  --name "ocp-agent-$(date +%Y%m%d%H%M)" \
  --architecture x86_64 \
  --root-device-name /dev/sda1 \
  --boot-mode uefi-preferred \
  --ena-support \
  --virtualization-type hvm \
  --block-device-mappings "[
    {
      \"DeviceName\": \"/dev/sda1\",
      \"Ebs\": {
        \"SnapshotId\": \"${SNAP_ID}\",
        \"VolumeSize\": 16,
        \"VolumeType\": \"gp3\",
        \"DeleteOnTermination\": true
      }
    },
    {
      \"DeviceName\": \"/dev/sdb\",
      \"Ebs\": {
        \"VolumeSize\": 120,
        \"VolumeType\": \"gp3\",
        \"DeleteOnTermination\": true
      }
    }
  ]" --query 'ImageId' --output text)
```

Why asymmetric sizes matter:

| Volume | Size | Purpose |
|--------|------|---------|
| `/dev/sda1` | 16 GB | Agent ISO (boot disk during installation) |
| `/dev/sdb` | 120 GB | RHCOS install target |

NVMe device names (`/dev/nvme0n1` vs `/dev/nvme1n1`) are assigned non-deterministically by the kernel. With both disks at the same size, `rootDeviceHints.minSizeGigabytes` cannot distinguish them. With asymmetric sizes, `minSizeGigabytes: 100` always selects the 120 GB disk.

## Step 7 — Launch Instances

```bash
# Masters — m5.2xlarge (32 GiB RAM)
for i in 0 1 2; do
  aws ec2 run-instances \
    --image-id ${AMI_ID} \
    --instance-type m5.2xlarge \
    --key-name ocp-agent-key \
    --network-interfaces "DeviceIndex=0,NetworkInterfaceId=${MASTER_ENI_IDS[$i]}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=ocp-master-${i}}]"
done

# Workers — m5.xlarge (16 GiB RAM)
for i in 0 1 2; do
  aws ec2 run-instances \
    --image-id ${AMI_ID} \
    --instance-type m5.xlarge \
    --key-name ocp-agent-key \
    --network-interfaces "DeviceIndex=0,NetworkInterfaceId=${WORKER_ENI_IDS[$i]}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=ocp-worker-${i}}]"
done
```

### Instance type selection

| Role | Type | vCPU | RAM | Why |
|------|------|------|-----|-----|
| Master | m5.2xlarge | 8 | 32 GiB | Masters require ≥16 GiB usable RAM. m5.xlarge (16 GiB advertised) reports only 15.75 GiB to the OS due to firmware reservations, which fails the agent's validation. |
| Worker | m5.xlarge | 4 | 16 GiB | Workers require ≥8 GiB. m5.xlarge provides enough headroom. |

## Step 8 — Monitor Installation

### 8.1 — Using openshift-install

```bash
cd ${INSTALL_DIR}
openshift-install agent wait-for install-complete --dir=. --log-level=info
```

### 8.2 — SSH to the rendezvous host

```bash
MASTER0_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=ocp-master-0" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

# Watch installation stages
ssh -i ~/.ssh/your-key core@${MASTER0_IP} \
  "sudo journalctl -u assisted-service.service -f" 2>&1 \
  | grep --line-buffered 'reached installation stage'
```

### 8.3 — Installation timeline

A typical multi-node installation follows this timeline:

| Time | Stage |
|------|-------|
| 0:00 | Instances boot, agents start |
| 0:01 | Hosts discovered, validation begins |
| 0:02 | NTP syncs, connectivity checks pass |
| 0:02 | Cluster status → "ready", installation begins |
| 0:03 | Disk writing starts on all nodes |
| 0:06 | Masters finish writing, set UEFI boot order, reboot |
| 0:08 | Bootstrap starts (etcd, API server) |
| 0:10 | Masters reboot into RHCOS, join control plane |
| 0:12 | Workers reboot into RHCOS |
| 0:15 | Workers join cluster |
| 0:20 | Bootstrap complete, master-0 reboots into RHCOS |
| 0:30 | Cluster operators converging |
| 0:35-0:45 | All operators Available, cluster ready |

## Step 9 — Verify the Cluster

```bash
export KUBECONFIG=${INSTALL_DIR}/auth/kubeconfig

oc get nodes
oc get clusterversion
oc get co
oc whoami --show-console
cat ${INSTALL_DIR}/auth/kubeadmin-password
```

Expected output:

```
NAME       STATUS   ROLES                  AGE   VERSION
master-0   Ready    control-plane,master   15m   v1.35.6
master-1   Ready    control-plane,master   20m   v1.35.6
master-2   Ready    control-plane,master   20m   v1.35.6
worker-0   Ready    worker                 12m   v1.35.6
worker-1   Ready    worker                 10m   v1.35.6
worker-2   Ready    worker                 12m   v1.35.6

NAME      VERSION   AVAILABLE   PROGRESSING   SINCE   STATUS
version   4.22.11   True        False         5m      Cluster version is 4.22.11
```

## Troubleshooting

### EBUSY when writing to disk

```
Error: checking for exclusive access to /dev/nvme1n1
Caused by: couldn't reread partition table: device is in use
```

The agent is trying to write to the ISO boot disk. This happens when both EBS volumes are the same size and `minSizeGigabytes` matches the wrong disk. Fix: re-register the AMI with asymmetric sizes (16 GB + 120 GB).

### "Require at least 16.00 GiB RAM for role master, found only 15.75 GiB"

m5.xlarge advertises 16 GiB but the OS reports ~15.75 GiB due to firmware memory reservations. Use m5.2xlarge (32 GiB) for master nodes.

### Hosts stuck in "insufficient" status

Check the assisted-service logs on master-0:

```bash
ssh core@${MASTER0_IP} \
  "sudo journalctl -u assisted-service.service | grep 'status_info' | tail -10"
```

Common causes:
- **NTP**: chrony takes 30–60 seconds to sync. Self-resolving.
- **Connectivity**: Verify the security group allows all intra-cluster traffic (self-referencing rule).
- **DNS**: Verify Route 53 records resolve correctly.

### Nodes wrote RHCOS but never rebooted

If all nodes show 100% disk write progress but never reboot:
1. Check if the installation actually failed: `grep 'Failed' assisted-service.log`
2. The EBUSY error can report 100% progress before failing on the write step
3. The fix is always the asymmetric disk size approach

## Cleanup

```bash
source ${INSTALL_DIR}/resource-ids.env
./scripts/cleanup.sh
```

Or manually:

```bash
# Terminate all instances
aws ec2 terminate-instances --instance-ids ${MASTER_INSTANCE_IDS[@]} ${WORKER_INSTANCE_IDS[@]}

# Delete NLBs, target groups, ENIs, AMI, snapshot, S3 bucket, SG, IGW, subnet, VPC
# See scripts/cleanup.sh for the full teardown sequence
```

## Stopping and Starting

The cluster survives instance stop/start cycles:

```bash
# Stop all
aws ec2 stop-instances --instance-ids ${MASTER_INSTANCE_IDS[@]} ${WORKER_INSTANCE_IDS[@]}

# Start all
aws ec2 start-instances --instance-ids ${MASTER_INSTANCE_IDS[@]} ${WORKER_INSTANCE_IDS[@]}
```

After restart, cluster operators typically converge within 5–10 minutes.
