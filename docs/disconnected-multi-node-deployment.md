# Disconnected Multi-Node OpenShift on AWS EC2 — Agent-Based Installer with Mirror Registry (3+3)

This guide walks through deploying a 3 control plane + 3 worker OpenShift cluster on AWS EC2 using the Agent-Based Installer in a disconnected (mirror registry) configuration. A private Docker v2 registry is deployed on a separate EC2 instance, OCP release images are mirrored to it with oc-mirror v2, and all cluster nodes pull images from the mirror instead of the public internet.

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
   │  ┌─────────────────────────────────────────────────────────┐     │
   │  │  Registry (t3.medium)                                   │     │
   │  │  10.0.1.50:5000 ─── EIP (public)                        │     │
   │  │  Amazon Linux 2023 + Docker + registry:2                │     │
   │  │  Self-signed TLS + htpasswd auth │ 200 GB gp3           │     │
   │  └─────────────────────────────────────────────────────────┘     │
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
   │       All nodes pull from 10.0.1.50:5000 (private)              │
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

Workstation ── oc-mirror v2 ──→ Registry EIP:5000 (internet)
All Nodes   ── image pull   ──→ 10.0.1.50:5000 (private VPC)
```

The workstation mirrors images to the registry over the internet (via the registry's public EIP). During installation, all cluster nodes pull images from the registry over the private VPC network (10.0.1.50:5000). No Route 53 record is needed for the registry — nodes access it by IP.

## Prerequisites

| Tool | Purpose |
|------|---------|
| `openshift-install` | Agent-based installer CLI (must match target OCP version) |
| `oc` | OpenShift client |
| `oc-mirror` v2 | Mirror container images to private registries |
| `qemu-img` | Convert ISO to raw disk for EBS import |
| `aws` | AWS CLI v2 |
| `jq` | JSON processing for pull secret merging |
| `curl` | Registry health checks |

You also need:
- An AWS account with EC2, S3, ELBv2, Route 53, and IAM permissions
- A Red Hat pull secret from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret)
- A Route 53 hosted zone for your base domain
- An SSH key pair (`~/.ssh/id_ed25519` and `~/.ssh/id_ed25519.pub`)

## Automated Deployment

```bash
export CLUSTER_NAME=ocp
export BASE_DOMAIN=example.com
export INSTALL_DIR=~/ocp-disconnected-aws
export PULL_SECRET_FILE=~/pull-secret.json
export SSH_KEY_FILE=~/.ssh/id_ed25519.pub
export AWS_REGION=us-east-2

./scripts/deploy-multi-node-disconnected.sh
```

The script handles everything: VPC creation, registry deployment, image mirroring, ENIs, NLBs, DNS, ISO generation with mirror configuration, AMI conversion, instance launch, and installation monitoring. Total time is approximately 75–120 minutes (15–30 min mirroring + 5 min AMI conversion + 35–45 min install).

## Step-by-Step Guide

### Step 1 — AWS Networking

Create VPC, subnet, internet gateway, and security group. Same as the [connected multi-node guide](multi-node-deployment.md#step-1--create-aws-networking), with port 5000 added for registry access:

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
  --group-name ocp-sg --description "Disconnected multi-node OpenShift SG" \
  --vpc-id ${VPC_ID} --query 'GroupId' --output text)

# Port 5000 added for mirror registry access
for PORT in 22 80 443 5000 6443 22623; do
  aws ec2 authorize-security-group-ingress \
    --group-id ${SG_ID} --protocol tcp --port ${PORT} --cidr 0.0.0.0/0
done
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
| 5000 | Mirror registry (Docker v2 API) |
| 6443 | Kubernetes API |
| 22623 | Machine Config Server |
| 30000–32767 | NodePort services |
| 4789 | VXLAN (OVN overlay) |
| 6081 | Geneve (OVN overlay) |
| Self-referencing | All intra-cluster traffic |

### Step 2 — Deploy Mirror Registry

The mirror registry setup is identical to the [disconnected SNO guide](disconnected-sno-deployment.md#step-2--deploy-mirror-registry). The registry runs on an Amazon Linux 2023 instance with Docker (not podman — Amazon Linux 2023 does not include podman in its default repositories).

#### 2.1 — Create registry ENI and EIP

```bash
REGISTRY_ENI_ID=$(aws ec2 create-network-interface \
  --subnet-id ${SUBNET_ID} --groups ${SG_ID} \
  --private-ip-address 10.0.1.50 \
  --description "Mirror registry ENI" \
  --query 'NetworkInterface.NetworkInterfaceId' --output text)

REGISTRY_EIP_ALLOC=$(aws ec2 allocate-address --domain vpc \
  --query 'AllocationId' --output text)
REGISTRY_EIP_ADDR=$(aws ec2 describe-addresses \
  --allocation-ids ${REGISTRY_EIP_ALLOC} \
  --query 'Addresses[0].PublicIp' --output text)
```

#### 2.2 — Launch the registry instance

The user-data script installs Docker, generates a self-signed TLS certificate with an IP SAN for the private IP, creates htpasswd authentication, and starts the `registry:2` container:

```bash
#!/bin/bash
set -ex
dnf install -y docker openssl httpd-tools
systemctl enable --now docker
mkdir -p /opt/registry/{certs,data,auth}

openssl req -newkey rsa:4096 -nodes -sha256 \
  -keyout /opt/registry/certs/domain.key \
  -x509 -days 365 \
  -subj "/CN=10.0.1.50" \
  -addext "subjectAltName=IP:10.0.1.50,IP:127.0.0.1" \
  -out /opt/registry/certs/domain.crt

htpasswd -bBc /opt/registry/auth/htpasswd registry registry

docker run -d --name mirror-registry -p 5000:5000 --restart=always \
  -v /opt/registry/data:/var/lib/registry \
  -v /opt/registry/certs:/certs \
  -v /opt/registry/auth:/auth \
  -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/domain.crt \
  -e REGISTRY_HTTP_TLS_KEY=/certs/domain.key \
  -e REGISTRY_AUTH=htpasswd \
  -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
  docker.io/library/registry:2
```

Launch with a 200 GB gp3 volume:

```bash
AL2023_AMI=$(aws ec2 describe-images --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' --output text)

REGISTRY_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id ${AL2023_AMI} --instance-type t3.medium \
  --key-name ocp-agent-key \
  --network-interfaces "DeviceIndex=0,NetworkInterfaceId=${REGISTRY_ENI_ID}" \
  --user-data file://registry-userdata.sh \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{
    "VolumeSize":200,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --instance-ids ${REGISTRY_INSTANCE_ID}
aws ec2 associate-address --allocation-id ${REGISTRY_EIP_ALLOC} \
  --network-interface-id ${REGISTRY_ENI_ID}
```

#### 2.3 — Wait for the registry and retrieve the CA certificate

```bash
until curl -sk "https://${REGISTRY_EIP_ADDR}:5000/v2/" \
  -u registry:registry 2>/dev/null | grep -q '{}'; do
  sleep 10
done

scp -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 \
  ec2-user@${REGISTRY_EIP_ADDR}:/opt/registry/certs/domain.crt \
  ${INSTALL_DIR}/registry-ca.crt
```

### Step 3 — Mirror OCP Images with oc-mirror v2

Same process as the [disconnected SNO guide](disconnected-sno-deployment.md#step-3--mirror-ocp-images-with-oc-mirror-v2). Create the ImageSetConfiguration (see [examples/disconnected-multi-node/imageset-config.yaml](../examples/disconnected-multi-node/imageset-config.yaml)):

```yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    architectures:
      - amd64
    channels:
      - name: stable-4.22
        minVersion: 4.22.11
        maxVersion: 4.22.11
```

Prepare authentication and run oc-mirror:

```bash
REGISTRY_AUTH_B64=$(echo -n "registry:registry" | base64 -w0)
DOCKER_CONFIG_DIR=$(mktemp -d)
jq --arg reg "${REGISTRY_EIP_ADDR}:5000" \
   --arg auth "${REGISTRY_AUTH_B64}" \
   '.auths[$reg] = {"auth": $auth}' ~/pull-secret.json \
   > "${DOCKER_CONFIG_DIR}/config.json"

DOCKER_CONFIG="${DOCKER_CONFIG_DIR}" oc-mirror \
  -c imageset-config.yaml \
  --workspace file://${INSTALL_DIR}/mirror \
  docker://${REGISTRY_EIP_ADDR}:5000 \
  --dest-tls-verify=false \
  --v2
```

This mirrors ~192 images and takes 15–30 minutes. If it fails partway through, re-run the same command — oc-mirror v2 is idempotent.

Verify the mirror:

```bash
cat ${INSTALL_DIR}/mirror/working-dir/cluster-resources/idms-oc-mirror.yaml
curl -sk https://${REGISTRY_EIP_ADDR}:5000/v2/_catalog -u registry:registry
```

### Step 4 — Create Pre-Provisioned ENIs

Same as the [connected multi-node guide](multi-node-deployment.md#step-2--create-pre-provisioned-enis):

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

### Step 5 — Network Load Balancers and DNS

Same as the [connected multi-node guide](multi-node-deployment.md#step-3--network-load-balancers) Steps 3 and 4. Create API NLB (ports 6443 and 22623 targeting masters) and Ingress NLB (ports 80 and 443 targeting all nodes), then create Route 53 alias records pointing to the NLBs.

See the connected guide for the full NLB and DNS commands — they are identical for disconnected deployments.

### Step 6 — Generate Agent ISO with Mirror Configuration

The disconnected install-config.yaml has three additional fields compared to the connected version (see [examples/disconnected-multi-node/install-config.yaml](../examples/disconnected-multi-node/install-config.yaml)):

- **`imageContentSources`** — maps public registry sources to the private mirror
- **`additionalTrustBundle`** — the self-signed CA certificate from the registry instance
- **Merged pull secret** — includes credentials for both Red Hat registries and the private mirror

#### 6.1 — Prepare the pull secret

Use the registry's **private IP** (10.0.1.50), not the public EIP, since all cluster nodes access the registry over the VPC network:

```bash
REGISTRY_AUTH_B64=$(echo -n "registry:registry" | base64 -w0)
INSTALL_PULL_SECRET=$(jq --arg reg "10.0.1.50:5000" \
  --arg auth "${REGISTRY_AUTH_B64}" \
  '.auths[$reg] = {"auth": $auth}' ~/pull-secret.json | jq -c .)
```

#### 6.2 — install-config.yaml

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
imageContentSources:
  - mirrors:
    - 10.0.1.50:5000/openshift/release-images
    source: quay.io/openshift-release-dev/ocp-release
  - mirrors:
    - 10.0.1.50:5000/openshift/release
    source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
additionalTrustBundle: |
  -----BEGIN CERTIFICATE-----
  <your registry CA certificate>
  -----END CERTIFICATE-----
pullSecret: '<merged pull secret with mirror registry credentials>'
sshKey: 'ssh-ed25519 AAAA...'
```

The `imageContentSources` entries come from the IDMS files generated by oc-mirror, with the registry address rewritten from the public EIP to the private IP.

#### 6.3 — agent-config.yaml

The agent-config.yaml is identical to the [connected multi-node version](../examples/multi-node/agent-config.yaml) — it only describes host networking and roles, not image sources:

```yaml
apiVersion: v1beta1
kind: AgentConfig
metadata:
  name: ocp
rendezvousIP: 10.0.1.101
hosts:
  - hostname: master-0
    role: master
    rootDeviceHints:
      minSizeGigabytes: 100
    interfaces:
      - name: ens5
        macAddress: "02:xx:xx:xx:xx:01"   # From master-0 ENI
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
  # See examples/disconnected-multi-node/agent-config.yaml for the full template
```

#### 6.4 — Generate the ISO

```bash
cd ${INSTALL_DIR}
openshift-install agent create image --dir=. --log-level=info
```

### Step 7 — Convert ISO to AMI

Same as the [connected multi-node guide](multi-node-deployment.md#step-6--convert-iso-to-ami). Convert the ISO to raw format, upload to S3, import as an EBS snapshot, and register an AMI with dual volumes (16 GB boot + 120 GB install target). The same AMI is used for all 6 instances.

### Step 8 — Launch Instances

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

Monitor the installation:

```bash
openshift-install agent wait-for install-complete --dir=. --log-level=info
```

### Step 9 — Verify

```bash
export KUBECONFIG=${INSTALL_DIR}/auth/kubeconfig
oc get nodes
oc get clusterversion
oc get co

# Verify mirror configuration is active
oc get imagedigestmirrorset

# Check registry catalog
curl -sk https://${REGISTRY_EIP_ADDR}:5000/v2/_catalog \
  -u registry:registry
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

NAME                  AGE
image-digest-mirror   45m
```

## How the Mirror Configuration Works

| Mechanism | Where | Purpose |
|-----------|-------|---------|
| `imageContentSources` | install-config.yaml | Tells the installer to rewrite image references from `quay.io/openshift-release-dev/*` to `10.0.1.50:5000/openshift/*` |
| `additionalTrustBundle` | install-config.yaml | Injects the self-signed CA certificate into all nodes' trust stores so CRI-O trusts the registry's TLS certificate |
| Pull secret | install-config.yaml | Includes `registry:registry` credentials for `10.0.1.50:5000` alongside the Red Hat pull secret |

After installation, the `imageContentSources` entries are applied as an `ImageDigestMirrorSet` custom resource in the cluster. This ensures all future image pulls — including operator updates and workload deployments — continue to use the mirror.

## Installation Timeline

| Time | Stage |
|------|-------|
| 0:00 | VPC and networking created |
| 0:02 | Registry instance launched |
| 0:05 | Registry ready (packages installed, container started) |
| 0:05 | oc-mirror starts |
| 0:20–0:35 | oc-mirror completes (~192 images) |
| 0:35 | ENIs created, NLBs provisioned, DNS configured |
| 0:38 | Agent ISO generated with mirror configuration |
| 0:43 | ISO uploaded to S3, snapshot import started |
| 0:48 | AMI registered, all 6 instances launched |
| 0:50 | Agents boot, start pulling from mirror registry |
| 0:55 | RHCOS written to disk on all nodes |
| 0:58 | Masters reboot, bootstrap starts (etcd, API server) |
| 1:02 | Workers reboot, join cluster |
| 1:10 | Bootstrap complete, master-0 reboots into RHCOS |
| 1:15 | Cluster operators converging |
| 1:20–1:30 | All operators Available, cluster ready |

Total: approximately 75–120 minutes end-to-end.

## Resource Summary

| Resource | Count | Purpose |
|----------|-------|---------|
| VPC | 1 | Network isolation |
| Subnet | 1 | 10.0.1.0/24 |
| Internet Gateway | 1 | Outbound access |
| Security Group | 1 | Ports: 22, 80, 443, 5000, 6443, 22623, 30000-32767 + intra-cluster + OVN |
| ENIs | 7 | Registry (10.0.1.50) + 3 masters (.101-.103) + 3 workers (.111-.113) |
| Elastic IPs | 1 | Registry (mirroring access) |
| EC2 Instances | 7 | t3.medium (registry) + 3x m5.2xlarge (masters) + 3x m5.xlarge (workers) |
| NLBs | 2 | API (6443, 22623) + Ingress (80, 443) |
| Target Groups | 4 | API, MCS, HTTP, HTTPS |
| S3 Bucket | 1 | Temporary ISO upload for AMI conversion |
| Route 53 Records | 3 | api, api-int, *.apps (alias to NLBs) |

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Docker instead of podman | Amazon Linux 2023 does not include podman in its default repositories. Docker is available via `dnf install docker`. |
| User-data for registry provisioning | Atomic provisioning — no SSH timing issues. Debug by polling `/v2/` health endpoint. |
| Private IP in imageContentSources | All nodes access the registry over the VPC private network. No Route 53 record needed for the registry. |
| Self-signed TLS (not plaintext) | CRI-O requires TLS for container registries. The `additionalTrustBundle` field handles CA trust injection. |
| `--dest-tls-verify=false` for oc-mirror | Avoids needing to add the self-signed CA to the workstation's trust store. |
| `DOCKER_CONFIG` env var for auth | Avoids touching the user's real `~/.docker/config.json` or containers auth. |
| 200 GB registry volume | OCP release images are ~15 GB compressed. Headroom for additional mirrors, operators, or application images. |
| Same AMI for all nodes | All 6 instances use the same AMI. The agent matches hosts by MAC address and applies the correct role. |
| NLBs instead of direct EIPs | Multi-node clusters need load balancers to distribute API and ingress traffic across nodes. |

## Cleanup

Use the shared cleanup script:

```bash
./scripts/cleanup.sh ${INSTALL_DIR}/resource-ids.env
```

The cleanup script automatically discovers all instances in the VPC and all ENIs in the subnet, so it handles the registry instance, all node instances, and all ENIs. The `resource-ids.env` file includes `REGISTRY_EIP_ALLOC` for registry EIP cleanup, and NLB/target group ARNs for load balancer cleanup.

## Troubleshooting

### Registry not reachable

```bash
# Check registry container is running
ssh -i ~/.ssh/id_ed25519 ec2-user@${REGISTRY_EIP_ADDR} \
  'docker ps'

# Test registry API
curl -sk https://${REGISTRY_EIP_ADDR}:5000/v2/_catalog \
  -u registry:registry

# Check security group allows port 5000
aws ec2 describe-security-groups --group-ids ${SG_ID} \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`5000`]'
```

### oc-mirror fails with authentication errors

Ensure the Docker config file includes credentials for both the source (Red Hat) and destination (mirror) registries:

```bash
cat ${DOCKER_CONFIG_DIR}/config.json | jq '.auths | keys'
```

### oc-mirror fails partway through

Network timeouts during large image transfers are common. Re-run the same oc-mirror command — it is idempotent and will verify existing images before copying only what's missing.

### Installation fails with image pull errors

1. Verify `imageContentSources` in install-config.yaml uses the registry's **private IP** (10.0.1.50), not the public EIP
2. Verify the `additionalTrustBundle` contains the correct CA certificate
3. Verify the pull secret includes credentials for `10.0.1.50:5000`
4. Check that all required images were mirrored:
   ```bash
   curl -sk https://${REGISTRY_EIP_ADDR}:5000/v2/_catalog -u registry:registry
   ```

### Master node RAM validation fails

m5.xlarge advertises 16 GiB but the OS reports ~15.75 GiB due to firmware reservations. Use m5.2xlarge (32 GiB) for master nodes.

### Hosts stuck in "insufficient" status

Check the assisted-service logs on master-0:

```bash
MASTER0_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=ocp-master-0" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
ssh core@${MASTER0_IP} \
  "sudo journalctl -u assisted-service.service | grep 'status_info' | tail -10"
```

Common causes:
- **NTP**: chrony takes 30–60 seconds to sync. Self-resolving.
- **Connectivity**: Verify the security group allows all intra-cluster traffic (self-referencing rule).
- **DNS**: Verify Route 53 alias records resolve correctly to the NLBs.

### oc-mirror v2 notes

- The `--v2` flag is mandatory on every oc-mirror invocation — without it, the command exits with an error
- The `init` and `describe` subcommands are not available in v2 — write the ImageSetConfiguration manually
- The apiVersion for v2 configs is `mirror.openshift.io/v2alpha1`
- oc-mirror v2 generates IDMS/ITMS files (not the deprecated ICSP)
- oc-mirror v2 is idempotent — interrupted runs can be safely re-executed

### Comparing connected vs disconnected install-config.yaml

| Field | Connected | Disconnected |
|-------|-----------|--------------|
| `imageContentSources` | Not present | Maps `quay.io/openshift-release-dev/*` to `10.0.1.50:5000/openshift/*` |
| `additionalTrustBundle` | Not present | Self-signed CA certificate from the mirror registry |
| `pullSecret` | Red Hat pull secret only | Merged: Red Hat pull secret + mirror registry credentials (using private IP) |
| Everything else | Identical | Identical |
