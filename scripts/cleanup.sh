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

# Discover any additional instances in the VPC (e.g. day-2 worker nodes)
if [[ -n "${VPC_ID:-}" ]]; then
  EXTRA_INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)
  for iid in ${EXTRA_INSTANCES}; do
    if [[ ! " ${ALL_INSTANCES[*]:-} " =~ " ${iid} " ]]; then
      log "Discovered additional instance in VPC: ${iid}"
      ALL_INSTANCES+=("${iid}")
    fi
  done
fi

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

# Discover any additional ENIs in the subnet (e.g. day-2 worker nodes)
if [[ -n "${SUBNET_ID:-}" ]]; then
  EXTRA_ENIS=$(aws ec2 describe-network-interfaces \
    --filters "Name=subnet-id,Values=${SUBNET_ID}" "Name=status,Values=available" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null || true)
  for eid in ${EXTRA_ENIS}; do
    if [[ ! " ${ALL_ENIS[*]:-} " =~ " ${eid} " ]]; then
      log "Discovered additional ENI in subnet: ${eid}"
      ALL_ENIS+=("${eid}")
    fi
  done
fi

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

if [[ -n "${ZONE_ID:-}" && -n "${CLUSTER_NAME:-}" && -n "${BASE_DOMAIN:-}" ]]; then
  if [[ -n "${API_NLB_DNS:-}" && -n "${API_NLB_ZONE:-}" && -n "${INGRESS_NLB_DNS:-}" && -n "${INGRESS_NLB_ZONE:-}" ]]; then
    # Multi-node: alias records pointing to NLBs
    log "Deleting DNS alias records for ${CLUSTER_NAME}.${BASE_DOMAIN}..."
    aws route53 change-resource-record-sets --hosted-zone-id "${ZONE_ID}" \
      --change-batch "{
        \"Changes\": [
          {\"Action\":\"DELETE\",\"ResourceRecordSet\":{
            \"Name\":\"api.${CLUSTER_NAME}.${BASE_DOMAIN}\",\"Type\":\"A\",
            \"AliasTarget\":{\"HostedZoneId\":\"${API_NLB_ZONE}\",
              \"DNSName\":\"${API_NLB_DNS}\",\"EvaluateTargetHealth\":true}}},
          {\"Action\":\"DELETE\",\"ResourceRecordSet\":{
            \"Name\":\"api-int.${CLUSTER_NAME}.${BASE_DOMAIN}\",\"Type\":\"A\",
            \"AliasTarget\":{\"HostedZoneId\":\"${API_NLB_ZONE}\",
              \"DNSName\":\"${API_NLB_DNS}\",\"EvaluateTargetHealth\":true}}},
          {\"Action\":\"DELETE\",\"ResourceRecordSet\":{
            \"Name\":\"*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}\",\"Type\":\"A\",
            \"AliasTarget\":{\"HostedZoneId\":\"${INGRESS_NLB_ZONE}\",
              \"DNSName\":\"${INGRESS_NLB_DNS}\",\"EvaluateTargetHealth\":true}}}
        ]
      }" 2>/dev/null || log "Warning: DNS record deletion failed (records may have been modified)"
  elif [[ -n "${EIP_ADDR:-}" ]]; then
    # SNO: A records pointing to Elastic IP
    log "Deleting DNS records for ${CLUSTER_NAME}.${BASE_DOMAIN}..."
    aws route53 change-resource-record-sets --hosted-zone-id "${ZONE_ID}" \
      --change-batch "{
        \"Changes\": [
          {\"Action\":\"DELETE\",\"ResourceRecordSet\":{
            \"Name\":\"api.${CLUSTER_NAME}.${BASE_DOMAIN}\",\"Type\":\"A\",\"TTL\":300,
            \"ResourceRecords\":[{\"Value\":\"${EIP_ADDR}\"}]}},
          {\"Action\":\"DELETE\",\"ResourceRecordSet\":{
            \"Name\":\"api-int.${CLUSTER_NAME}.${BASE_DOMAIN}\",\"Type\":\"A\",\"TTL\":300,
            \"ResourceRecords\":[{\"Value\":\"${EIP_ADDR}\"}]}},
          {\"Action\":\"DELETE\",\"ResourceRecordSet\":{
            \"Name\":\"*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}\",\"Type\":\"A\",\"TTL\":300,
            \"ResourceRecords\":[{\"Value\":\"${EIP_ADDR}\"}]}}
        ]
      }" 2>/dev/null || log "Warning: DNS record deletion failed (records may have been modified)"
  else
    log "Note: DNS records could not be deleted (missing EIP_ADDR or NLB DNS info)"
    log "  Zone: ${ZONE_ID}"
  fi
elif [[ -n "${ZONE_ID:-}" ]]; then
  log "Note: DNS records could not be deleted (missing CLUSTER_NAME or BASE_DOMAIN)"
  log "  Zone: ${ZONE_ID}"
fi

log "Cleanup complete"
