# Disconnected SNO on AWS EC2 — Agent-Based Installer with Mirror Registry

This guide walks through deploying a Single Node OpenShift cluster on AWS EC2 using the Agent-Based Installer in a disconnected (mirror registry) configuration. A private Docker v2 registry is deployed on a separate EC2 instance, OCP release images are mirrored to it with oc-mirror v2, and the SNO node pulls all images from the mirror instead of the public internet.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                  AWS VPC (10.0.0.0/16)                   │
│                                                          │
│   ┌──────────────────────────────────────────────────┐   │
│   │              Subnet (10.0.1.0/24)                │   │
│   │                                                  │   │
│   │   ┌──────────────────────────────────────────┐   │   │
│   │   │   Registry (t3.medium)                   │   │   │
│   │   │   10.0.1.50:5000 ─── EIP (public)        │   │   │
│   │   │   Amazon Linux 2023 + Docker + registry:2│   │   │
│   │   │   Self-signed TLS + htpasswd auth        │   │   │
│   │   │   200 GB gp3 (image storage)             │   │   │
│   │   └──────────────────────────────────────────┘   │   │
│   │                                                  │   │
│   │   ┌──────────────────────────────────────────┐   │   │
│   │   │   SNO Node (m6i.2xlarge)                 │   │   │
│   │   │   10.0.1.100 ─── EIP (public)            │   │   │
│   │   │   Pulls images from 10.0.1.50:5000       │   │   │
│   │   │   nvme0n1 ── 16 GB (boot ISO / AMI)      │   │   │
│   │   │   nvme1n1 ── 120 GB (RHCOS install)      │   │   │
│   │   └──────────────────────────────────────────┘   │   │
│   └──────────────────────────────────────────────────┘   │
│                                                          │
│   Internet Gateway ──── Route Table (0.0.0.0/0 → IGW)   │
└──────────────────────────────────────────────────────────┘

Workstation ── oc-mirror v2 ──→ Registry EIP:5000 (internet)
OCP Node    ── image pull   ──→ 10.0.1.50:5000 (private VPC)

Route 53:  api.sno.example.com      → Node EIP
           api-int.sno.example.com  → Node EIP
           *.apps.sno.example.com   → Node EIP
```

The workstation mirrors images to the registry over the internet (via the registry's public EIP). During installation, the SNO node pulls images from the registry over the private VPC network (10.0.1.50:5000). No Route 53 record is needed for the registry — the SNO node accesses it by IP.

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
- An AWS account with EC2, S3, Route 53, and IAM permissions
- A Red Hat pull secret from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret)
- A Route 53 hosted zone for your base domain
- An SSH key pair (`~/.ssh/id_ed25519` and `~/.ssh/id_ed25519.pub`)

## Automated Deployment

```bash
export CLUSTER_NAME=sno
export BASE_DOMAIN=example.com
export INSTALL_DIR=~/sno-disconnected-aws
export PULL_SECRET_FILE=~/pull-secret.json
export SSH_KEY_FILE=~/.ssh/id_ed25519.pub
export AWS_REGION=us-east-2

./scripts/deploy-sno-disconnected.sh
```

The script handles everything: VPC creation, registry deployment, image mirroring, ISO generation with mirror configuration, AMI conversion, instance launch, and installation monitoring. Total time is approximately 60–90 minutes (15–30 min mirroring + 5 min AMI conversion + 25–40 min install).

## Step-by-Step Guide

### Step 1 — AWS Networking

Create VPC, subnet, internet gateway, and security group. Same as the [connected SNO guide](sno-deployment.md#step-1--aws-networking), with port 5000 added for registry access:

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
  --group-name sno-sg --description "Disconnected SNO security group" \
  --vpc-id ${VPC_ID} --query 'GroupId' --output text)

# Port 5000 added for mirror registry access
for PORT in 22 80 443 5000 6443 22623; do
  aws ec2 authorize-security-group-ingress \
    --group-id ${SG_ID} --protocol tcp --port ${PORT} --cidr 0.0.0.0/0
done
aws ec2 authorize-security-group-ingress \
  --group-id ${SG_ID} --protocol tcp --port 30000-32767 --cidr 0.0.0.0/0
```

| Port | Purpose |
|------|---------|
| 22 | SSH access |
| 80, 443 | Ingress (HTTP/HTTPS) |
| 5000 | Mirror registry (Docker v2 API) |
| 6443 | Kubernetes API |
| 22623 | Machine Config Server |
| 30000–32767 | NodePort services |

### Step 2 — Deploy Mirror Registry

The mirror registry runs on an Amazon Linux 2023 instance with Docker (not podman — Amazon Linux 2023 does not include podman in its default repositories).

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

# Self-signed TLS cert with IP SAN
openssl req -newkey rsa:4096 -nodes -sha256 \
  -keyout /opt/registry/certs/domain.key \
  -x509 -days 365 \
  -subj "/CN=10.0.1.50" \
  -addext "subjectAltName=IP:10.0.1.50,IP:127.0.0.1" \
  -out /opt/registry/certs/domain.crt

# htpasswd authentication
htpasswd -bBc /opt/registry/auth/htpasswd registry registry

# Start registry:2 container with TLS and auth
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

Launch the instance with a 200 GB gp3 volume (OCP release images require ~15 GB compressed, with headroom for blobs and future mirrors):

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
# Wait for registry to be ready (typically 2-3 minutes)
until curl -sk "https://${REGISTRY_EIP_ADDR}:5000/v2/" \
  -u registry:registry 2>/dev/null | grep -q '{}'; do
  sleep 10
done

# Retrieve CA certificate for install-config.yaml
scp -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 \
  ec2-user@${REGISTRY_EIP_ADDR}:/opt/registry/certs/domain.crt \
  ${INSTALL_DIR}/registry-ca.crt
```

The CA certificate is embedded in `install-config.yaml` as `additionalTrustBundle` so the SNO node trusts the registry's self-signed TLS certificate.

### Step 3 — Mirror OCP Images with oc-mirror v2

#### 3.1 — ImageSetConfiguration

Create an ImageSetConfiguration for oc-mirror v2 (see [examples/disconnected-sno/imageset-config.yaml](../examples/disconnected-sno/imageset-config.yaml)):

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

Key points about oc-mirror v2:
- The apiVersion is `mirror.openshift.io/v2alpha1` (not v1alpha2)
- The `--v2` flag is **mandatory** on every oc-mirror invocation
- The `init` and `describe` subcommands do not exist in v2 — write the config manually
- v2 generates IDMS/ITMS files (not the deprecated ICSP)

#### 3.2 — Prepare authentication

Merge your Red Hat pull secret with the mirror registry credentials. Use the `DOCKER_CONFIG` environment variable to avoid modifying your real `~/.docker/config.json`:

```bash
REGISTRY_AUTH_B64=$(echo -n "registry:registry" | base64 -w0)
DOCKER_CONFIG_DIR=$(mktemp -d)
jq --arg reg "${REGISTRY_EIP_ADDR}:5000" \
   --arg auth "${REGISTRY_AUTH_B64}" \
   '.auths[$reg] = {"auth": $auth}' ~/pull-secret.json \
   > "${DOCKER_CONFIG_DIR}/config.json"
```

#### 3.3 — Run oc-mirror

```bash
DOCKER_CONFIG="${DOCKER_CONFIG_DIR}" oc-mirror \
  -c imageset-config.yaml \
  --workspace file://${INSTALL_DIR}/mirror \
  docker://${REGISTRY_EIP_ADDR}:5000 \
  --dest-tls-verify=false \
  --v2
```

This mirrors ~192 images and takes 15–30 minutes depending on bandwidth. The `--dest-tls-verify=false` flag avoids needing to add the self-signed CA to the workstation's trust store.

If the mirror fails partway through (e.g. network timeout), re-run the same command — oc-mirror v2 is idempotent and will verify existing images before copying only what's missing.

#### 3.4 — Verify the mirror

After completion, oc-mirror generates IDMS (ImageDigestMirrorSet) files in `mirror/working-dir/cluster-resources/`:

```bash
# Check IDMS output
cat ${INSTALL_DIR}/mirror/working-dir/cluster-resources/idms-oc-mirror.yaml

# Verify images in the registry
curl -sk https://${REGISTRY_EIP_ADDR}:5000/v2/_catalog \
  -u registry:registry
```

Expected catalog output:
```json
{"repositories":["openshift/release","openshift/release-images"]}
```

### Step 4 — ENI, EIP, and DNS for SNO Node

Same as the [connected SNO guide](sno-deployment.md#step-2--eni-and-elastic-ip) Steps 2 and 3:

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

# DNS records — same as connected SNO
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

### Step 5 — Generate Agent ISO with Mirror Configuration

The disconnected install-config.yaml has two additional fields compared to the connected version (see [examples/disconnected-sno/install-config.yaml](../examples/disconnected-sno/install-config.yaml)):

- **`imageContentSources`** — maps public registry sources to the private mirror
- **`additionalTrustBundle`** — the self-signed CA certificate from the registry instance

#### 5.1 — Prepare the pull secret

The pull secret must include credentials for both Red Hat registries and the private mirror. Use the registry's **private IP** (10.0.1.50), not the public EIP, since the SNO node accesses the registry over the VPC network:

```bash
REGISTRY_AUTH_B64=$(echo -n "registry:registry" | base64 -w0)
INSTALL_PULL_SECRET=$(jq --arg reg "10.0.1.50:5000" \
  --arg auth "${REGISTRY_AUTH_B64}" \
  '.auths[$reg] = {"auth": $auth}' ~/pull-secret.json | jq -c .)
```

#### 5.2 — Build imageContentSources from IDMS output

The `imageContentSources` entries come from the IDMS files generated by oc-mirror, with the registry address rewritten from the public EIP to the private IP:

```yaml
imageContentSources:
  - mirrors:
    - 10.0.1.50:5000/openshift/release-images
    source: quay.io/openshift-release-dev/ocp-release
  - mirrors:
    - 10.0.1.50:5000/openshift/release
    source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
```

These two entries map the public Red Hat release repositories to your private mirror. The deploy script parses the IDMS YAML and generates these automatically.

#### 5.3 — install-config.yaml

```yaml
apiVersion: v1
metadata:
  name: sno
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
  - name: worker
    replicas: 0
controlPlane:
  name: master
  replicas: 1
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

#### 5.4 — agent-config.yaml

The agent-config.yaml is identical to the [connected SNO version](../examples/sno/agent-config.yaml) — it only describes host networking, not image sources:

```yaml
apiVersion: v1beta1
kind: AgentConfig
metadata:
  name: sno
rendezvousIP: 10.0.1.100
hosts:
  - hostname: sno
    role: master
    rootDeviceHints:
      minSizeGigabytes: 100
    interfaces:
      - name: ens5
        macAddress: "02:xx:xx:xx:xx:xx"   # From the pre-created ENI
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
```

#### 5.5 — Generate the ISO

```bash
cd ${INSTALL_DIR}
openshift-install agent create image --dir=. --log-level=info
```

### Step 6 — Convert ISO to AMI

Same as the [connected SNO guide](sno-deployment.md#step-5--convert-iso-to-ami). Convert the ISO to raw format, upload to S3, import as an EBS snapshot, and register an AMI with dual volumes (16 GB boot + 120 GB install target).

```bash
qemu-img convert -f raw -O raw agent.x86_64.iso agent.x86_64.raw

BUCKET_NAME="openshift-agent-iso-sno-$(date +%s)"
aws s3 mb s3://${BUCKET_NAME}
aws s3 cp agent.x86_64.raw s3://${BUCKET_NAME}/agent.x86_64.raw

# Import snapshot (see deploy-sno-disconnected.sh for vmimport role setup)
IMPORT_TASK=$(aws ec2 import-snapshot \
  --description "SNO disconnected agent ISO" \
  --disk-container "{\"Format\":\"RAW\",\"UserBucket\":{
    \"S3Bucket\":\"${BUCKET_NAME}\",\"S3Key\":\"agent.x86_64.raw\"}}" \
  --query 'ImportTaskId' --output text)

# Poll until complete (5-10 minutes), then register AMI
AMI_ID=$(aws ec2 register-image \
  --name "sno-disconnected-agent-$(date +%Y%m%d%H%M)" \
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

### Step 7 — Launch and Monitor

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

Installation takes 25–40 minutes. The node pulls all images from the private registry at 10.0.1.50:5000.

### Step 8 — Verify

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
NAME   STATUS   ROLES                         AGE   VERSION
sno    Ready    control-plane,master,worker   5m    v1.35.6

NAME      VERSION   AVAILABLE   PROGRESSING   SINCE   STATUS
version   4.22.11   True        False         5m      Cluster version is 4.22.11

NAME                  AGE
image-digest-mirror   30m
```

## How the Mirror Configuration Works

The disconnected installation uses three mechanisms to redirect image pulls from public registries to the private mirror:

| Mechanism | Where | Purpose |
|-----------|-------|---------|
| `imageContentSources` | install-config.yaml | Tells the installer to rewrite image references from `quay.io/openshift-release-dev/*` to `10.0.1.50:5000/openshift/*` |
| `additionalTrustBundle` | install-config.yaml | Injects the self-signed CA certificate into the node's trust store so CRI-O trusts the registry's TLS certificate |
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
| 0:35 | Agent ISO generated with mirror configuration |
| 0:40 | ISO uploaded to S3, snapshot import started |
| 0:45 | AMI registered, SNO instance launched |
| 0:50 | Agent boots, starts pulling from mirror registry |
| 0:55 | RHCOS written to disk, node reboots |
| 1:00 | Bootkube starts, etcd and API server come up |
| 1:10 | Cluster operators converging |
| 1:15–1:25 | All operators Available, cluster ready |

Total: approximately 60–90 minutes end-to-end.

## Resource Summary

| Resource | Count | Purpose |
|----------|-------|---------|
| VPC | 1 | Network isolation |
| Subnet | 1 | 10.0.1.0/24 |
| Internet Gateway | 1 | Outbound access |
| Security Group | 1 | Ports: 22, 80, 443, 5000, 6443, 22623, 30000-32767 |
| ENIs | 2 | Registry (10.0.1.50) + SNO node (10.0.1.100) |
| Elastic IPs | 2 | Registry (mirroring access) + SNO node (API/apps) |
| EC2 Instances | 2 | t3.medium (registry) + m6i.2xlarge (SNO) |
| S3 Bucket | 1 | Temporary ISO upload for AMI conversion |
| Route 53 Records | 3 | api, api-int, *.apps |

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Docker instead of podman | Amazon Linux 2023 does not include podman in its default repositories. Docker is available via `dnf install docker`. |
| User-data for registry provisioning | Atomic provisioning — no SSH timing issues, no multi-step coordination. Debug by polling `/v2/` health endpoint. |
| Private IP in imageContentSources | The SNO node accesses the registry over the VPC private network. No Route 53 record needed for the registry. |
| Self-signed TLS (not plaintext) | CRI-O requires TLS for container registries. The `additionalTrustBundle` field handles CA trust injection. |
| `--dest-tls-verify=false` for oc-mirror | Avoids needing to add the self-signed CA to the workstation's trust store. The workstation uses TLS but skips verification. |
| `DOCKER_CONFIG` env var for auth | Avoids touching the user's real `~/.docker/config.json` or `${XDG_RUNTIME_DIR}/containers/auth.json`. |
| 200 GB registry volume | OCP release images are ~15 GB compressed. Headroom for additional mirrors, operators, or application images. |
| htpasswd auth (registry:registry) | Simulates authenticated registry access as found in real disconnected environments. |

## Cleanup

Use the shared cleanup script:

```bash
./scripts/cleanup.sh ${INSTALL_DIR}/resource-ids.env
```

The cleanup script automatically discovers all instances in the VPC and all ENIs in the subnet, so it handles the registry instance and ENI without needing them listed explicitly. The `resource-ids.env` file includes `REGISTRY_EIP_ALLOC` for registry EIP cleanup.

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
# Verify the merged config has both entries
cat ${DOCKER_CONFIG_DIR}/config.json | jq '.auths | keys'
# Should include: quay.io, registry.redhat.io, and your mirror address
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

### Node reboots during installation but doesn't come back

The agent-based installer on EC2 can occasionally trigger a shutdown instead of a reboot after writing RHCOS to disk. Check the instance state:

```bash
aws ec2 describe-instances --instance-ids ${INSTANCE_ID} \
  --query 'Reservations[0].Instances[0].State.Name' --output text
```

If the instance is `stopped`, start it manually:

```bash
aws ec2 start-instances --instance-ids ${INSTANCE_ID}
```

The installation will resume from where it left off.

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
