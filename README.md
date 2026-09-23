# OpenShift on AWS EC2 — Agent-Based Installer

Deploy OpenShift clusters on AWS EC2 using the Agent-Based Installer. This approach produces a self-contained bootable ISO that handles discovery, validation, and installation without requiring a bootstrap node or cloud provider integration.

Because EC2 cannot boot from ISO files directly, the workflow converts the ISO into an AMI. Instances boot the agent ISO from one EBS volume, run hardware discovery, write RHCOS to a second EBS volume, and reboot into the installed cluster.

## Deployment Options

| Guide | Topology | Instance Types |
|-------|----------|----------------|
| [Single Node OpenShift (SNO)](docs/sno-deployment.md) | 1 node (control plane + worker) | m6i.2xlarge |
| [Multi-Node Cluster (3+3)](docs/multi-node-deployment.md) | 3 control plane + 3 worker | m5.2xlarge (masters) + m5.xlarge (workers) |

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                         AWS VPC (10.0.0.0/16)                           │
│                                                                          │
│   ┌──────────────────────────────────────────────────────────────────┐   │
│   │                    Subnet (10.0.1.0/24)                          │   │
│   │                                                                  │   │
│   │   ┌──────────┐  ┌──────────┐  ┌──────────┐                     │   │
│   │   │ master-0 │  │ master-1 │  │ master-2 │  Control Plane       │   │
│   │   │ .101     │  │ .102     │  │ .103     │                      │   │
│   │   └────┬─────┘  └────┬─────┘  └────┬─────┘                     │   │
│   │        │              │              │                           │   │
│   │   ┌──────────┐  ┌──────────┐  ┌──────────┐                     │   │
│   │   │ worker-0 │  │ worker-1 │  │ worker-2 │  Compute             │   │
│   │   │ .111     │  │ .112     │  │ .113     │                      │   │
│   │   └────┬─────┘  └────┬─────┘  └────┬─────┘                     │   │
│   └────────┼──────────────┼──────────────┼───────────────────────────┘   │
│            │              │              │                                │
│   ┌────────┴──────────────┴──────────────┴────────┐                      │
│   │              NLB (API :6443, :22623)           │──── api.ocp.example  │
│   │              NLB (Ingress :80, :443)           │──── *.apps.ocp.ex..  │
│   └───────────────────────────────────────────────┘                      │
│                                                                          │
│   Internet Gateway ──── Route Table (0.0.0.0/0 → IGW)                   │
└──────────────────────────────────────────────────────────────────────────┘
```

## How It Works

1. **Generate an agent ISO** — `openshift-install agent create image` produces a bootable ISO with embedded cluster configuration, host definitions, and MAC-to-role mappings
2. **Convert ISO to AMI** — `qemu-img` converts to raw disk, uploaded to S3, imported as an EBS snapshot, registered as an AMI with two block devices (boot ISO + install target)
3. **Launch EC2 instances** — Each instance uses a pre-created ENI for a deterministic MAC address that the agent uses to match hosts to their configuration
4. **Automatic installation** — The agent discovers hardware, validates requirements, writes RHCOS to the install target disk, sets UEFI boot order, and reboots into the installed OS
5. **Cluster bootstraps** — etcd forms quorum, the control plane starts, workers join, cluster operators converge

## Key Design Decisions

### Pre-provisioned ENIs for deterministic MAC addresses

The agent-based installer matches hosts by MAC address. EC2 assigns MACs at launch time, so you cannot know them in advance. Creating ENIs before generating the ISO gives you stable MACs to embed in `agent-config.yaml`.

### Two EBS volumes with asymmetric sizes

The ISO boots from one EBS volume. `coreos-installer` cannot write to a disk that is in use (`EBUSY`). A second, empty EBS volume serves as the installation target. The volumes must be different sizes (16 GB for the ISO, 120 GB for the install target) because NVMe device naming (`/dev/nvme0n1` vs `/dev/nvme1n1`) is non-deterministic on EC2. Using `rootDeviceHints.minSizeGigabytes` in the agent config lets the installer reliably pick the larger disk regardless of device ordering.

### UEFI boot mode

The AMI must be registered with `--boot-mode uefi-preferred`. Without this, CoreOS may fail to boot entirely — no console output, no SSH, no errors.

### NLB for multi-node clusters

SNO uses an Elastic IP pointed directly at the single node. Multi-node clusters need a Network Load Balancer to distribute API (6443) and ingress (80/443) traffic across nodes, with Route 53 alias records pointing to the NLB.

## Quick Start

```bash
# Clone this repo
git clone https://github.com/jlapthorn/ocp-agent-aws.git
cd ocp-agent-aws

# Copy and edit the example configs
cp examples/multi-node/install-config.yaml my-cluster/
cp examples/multi-node/agent-config.yaml my-cluster/

# Edit with your pull secret, SSH key, MAC addresses, and domain
vi my-cluster/install-config.yaml
vi my-cluster/agent-config.yaml

# Use the deployment script
./scripts/deploy-multi-node.sh
```

## Prerequisites

| Requirement | Details |
|-------------|---------|
| `openshift-install` | Version matching your target OCP release (tested with 4.22.x) |
| `oc` | OpenShift CLI for post-install verification |
| `qemu-img` | For converting the ISO to a raw disk image |
| `jq` | For parsing JSON responses during snapshot import |
| AWS CLI v2 | Configured with EC2, S3, ELBv2, Route 53, IAM permissions |
| Pull secret | From [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret) |
| Route 53 hosted zone | For DNS records (your base domain) |

## Repository Structure

```
.
├── README.md
├── docs/
│   ├── sno-deployment.md          # Single Node OpenShift guide
│   └── multi-node-deployment.md   # 3+3 multi-node cluster guide
├── examples/
│   ├── sno/
│   │   ├── install-config.yaml
│   │   └── agent-config.yaml
│   └── multi-node/
│       ├── install-config.yaml
│       └── agent-config.yaml
└── scripts/
    ├── deploy-multi-node.sh       # Full deployment automation
    ├── deploy-sno.sh              # SNO deployment automation
    └── cleanup.sh                 # Resource teardown
```

## Lessons Learned

These are hard-won findings from deploying on EC2 — not documented in the OpenShift installation guides.

| Issue | Root Cause | Solution |
|-------|-----------|----------|
| `EBUSY: Device or resource busy` | coreos-installer tries to write to the boot disk | Add a second EBS volume as the install target |
| NVMe device ordering is non-deterministic | `/dev/nvme0n1` and `/dev/nvme1n1` can swap between instances | Use asymmetric disk sizes + `minSizeGigabytes` instead of `deviceName` |
| Instance boots but no SSH, no console | AMI registered without `--boot-mode uefi-preferred` | Always set `--boot-mode uefi-preferred` when registering the AMI |
| Agent cannot match host (MAC 00:00:00:00:00:00) | ENI MAC not known at ISO generation time | Pre-create ENIs before generating the ISO |
| Master node RAM validation fails on m5.xlarge | m5.xlarge reports 15.75 GiB, masters require 16.00 GiB | Use m5.2xlarge (32 GiB) for master nodes |
| NTP sync validation fails | chrony takes 30–60 seconds to sync on first boot | Self-resolving — wait for chrony to synchronize |
