#!/usr/bin/env bash
set -euo pipefail

#
# Clean up all AWS resources created by deploy-sno.sh or deploy-multi-node.sh.
#
# Usage:
#   source ~/ocp-agent-aws/resource-ids.env
#   ./cleanup.sh
#
# Or pass the env file as an argument:
#   ./cleanup.sh ~/ocp-agent-aws/resource-ids.env
#

if [[ "${1:-}" != "" && -f "$1" ]]; then
  echo "Loading resource IDs from $1"
  source "$1"
fi

log() { echo "$(date +%H:%M:%S) ── $*"; }

# ── Terminate Instances ────────────────────────────────────────────────────────

ALL_INSTANCES=()
[[ -n "${INSTANCE_ID:-}" ]] && ALL_INSTANCES+=("${INSTANCE_ID}")
[[ -n "${MASTER_INSTANCE_IDS:-}" ]] && ALL_INSTANCES+=("${MASTER_INSTANCE_IDS[@]}")
[[ -n "${WORKER_INSTANCE_IDS:-}" ]] && ALL_INSTANCES+=("${WORKER_INSTANCE_IDS[@]}")

if [[ ${#ALL_INSTANCES[@]} -gt 0 ]]; then
  log "Terminating instances: ${ALL_INSTANCES[*]}"
  aws ec2 terminate-instances --instance-ids "${ALL_INSTANCES[@]}" >/dev/null 2>&1 || true
  aws ec2 wait instance-terminated --instance-ids "${ALL_INSTANCES[@]}" 2>/dev/null || true
  log "Instances terminated"
fi

# ── Delete ENIs ────────────────────────────────────────────────────────────────

ALL_ENIS=()
[[ -n "${ENI_ID:-}" ]] && ALL_ENIS+=("${ENI_ID}")
[[ -n "${MASTER_ENI_IDS:-}" ]] && ALL_ENIS+=("${MASTER_ENI_IDS[@]}")
[[ -n "${WORKER_ENI_IDS:-}" ]] && ALL_ENIS+=("${WORKER_ENI_IDS[@]}")

for eni in "${ALL_ENIS[@]}"; do
  log "Deleting ENI: ${eni}"
  aws ec2 delete-network-interface --network-interface-id "${eni}" 2>/dev/null || true
done

# ── Release EIP ────────────────────────────────────────────────────────────────

if [[ -n "${EIP_ALLOC:-}" ]]; then
  log "Releasing EIP: ${EIP_ALLOC}"
  aws ec2 release-address --allocation-id "${EIP_ALLOC}" 2>/dev/null || true
fi

# ── Delete Load Balancers ──────────────────────────────────────────────────────

for nlb_arn in "${API_NLB_ARN:-}" "${INGRESS_NLB_ARN:-}"; do
  if [[ -n "${nlb_arn}" ]]; then
    log "Deleting NLB: ${nlb_arn}"
    aws elbv2 delete-load-balancer --load-balancer-arn "${nlb_arn}" 2>/dev/null || true
  fi
done

sleep 5

for tg_arn in "${API_TG_ARN:-}" "${MCS_TG_ARN:-}" "${HTTP_TG_ARN:-}" "${HTTPS_TG_ARN:-}"; do
  if [[ -n "${tg_arn}" ]]; then
    log "Deleting target group: ${tg_arn}"
    aws elbv2 delete-target-group --target-group-arn "${tg_arn}" 2>/dev/null || true
  fi
done

# ── Deregister AMI and Delete Snapshot ─────────────────────────────────────────

if [[ -n "${AMI_ID:-}" ]]; then
  log "Deregistering AMI: ${AMI_ID}"
  aws ec2 deregister-image --image-id "${AMI_ID}" 2>/dev/null || true
fi

if [[ -n "${SNAP_ID:-}" ]]; then
  log "Deleting snapshot: ${SNAP_ID}"
  aws ec2 delete-snapshot --snapshot-id "${SNAP_ID}" 2>/dev/null || true
fi

# ── Delete S3 Bucket ──────────────────────────────────────────────────────────

if [[ -n "${BUCKET_NAME:-}" ]]; then
  log "Deleting S3 bucket: ${BUCKET_NAME}"
  aws s3 rb "s3://${BUCKET_NAME}" --force 2>/dev/null || true
fi

# ── Delete Key Pair ────────────────────────────────────────────────────────────

if [[ -n "${KEY_NAME:-}" ]]; then
  log "Deleting key pair: ${KEY_NAME}"
  aws ec2 delete-key-pair --key-name "${KEY_NAME}" 2>/dev/null || true
fi

# ── Delete Security Group ─────────────────────────────────────────────────────

if [[ -n "${SG_ID:-}" ]]; then
  log "Deleting security group: ${SG_ID}"
  aws ec2 delete-security-group --group-id "${SG_ID}" 2>/dev/null || true
fi

# ── Delete IGW ─────────────────────────────────────────────────────────────────

if [[ -n "${IGW_ID:-}" && -n "${VPC_ID:-}" ]]; then
  log "Detaching and deleting IGW: ${IGW_ID}"
  aws ec2 detach-internet-gateway --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}" 2>/dev/null || true
  aws ec2 delete-internet-gateway --internet-gateway-id "${IGW_ID}" 2>/dev/null || true
fi

# ── Delete Subnet ──────────────────────────────────────────────────────────────

if [[ -n "${SUBNET_ID:-}" ]]; then
  log "Deleting subnet: ${SUBNET_ID}"
  aws ec2 delete-subnet --subnet-id "${SUBNET_ID}" 2>/dev/null || true
fi

# ── Delete VPC ─────────────────────────────────────────────────────────────────

if [[ -n "${VPC_ID:-}" ]]; then
  log "Deleting VPC: ${VPC_ID}"
  aws ec2 delete-vpc --vpc-id "${VPC_ID}" 2>/dev/null || true
fi

# ── Delete DNS Records ─────────────────────────────────────────────────────────

if [[ -n "${ZONE_ID:-}" ]]; then
  log "Note: DNS records should be cleaned up manually or will be overwritten on next deploy"
  log "  Zone: ${ZONE_ID}"
fi

log "Cleanup complete"
