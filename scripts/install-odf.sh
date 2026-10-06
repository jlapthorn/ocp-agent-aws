#!/usr/bin/env bash
set -euo pipefail

#
# Install OpenShift Data Foundation on storage nodes created by
# add-odf-nodes.sh, using the Local Storage Operator to consume each node's
# spare raw disk.
#
# Installs, in order:
#   1. Local Storage Operator
#   2. LocalVolumeSet claiming the spare disk on each labelled storage node
#   3. ODF operator (which pulls in ocs, rook-ceph, mcg, cephcsi and friends)
#   4. StorageCluster in internal mode
#   5. The ODF console plugin, which a Subscription-based install leaves off
#
# Prerequisites:
#   - Storage nodes added by add-odf-nodes.sh, each with a raw data disk,
#     labelled cluster.ocs.openshift.io/openshift-storage
#
# Usage:
#   export INSTALL_DIR=~/ocp-agent-aws
#   ./install-odf.sh
#

# ── Configuration ──────────────────────────────────────────────────────────────

INSTALL_DIR="${INSTALL_DIR:?Set INSTALL_DIR (e.g. ~/ocp-agent-aws)}"
export KUBECONFIG="${KUBECONFIG:-${INSTALL_DIR}/auth/kubeconfig}"

ODF_CHANNEL="${ODF_CHANNEL:-}"                   # auto-detected from the cluster version
LSO_CHANNEL="${LSO_CHANNEL:-stable}"
STORAGE_LABEL="${STORAGE_LABEL:-cluster.ocs.openshift.io/openshift-storage}"
STORAGE_TAINT_KEY="${STORAGE_TAINT_KEY:-node.ocs.openshift.io/storage}"
LOCAL_SC="${LOCAL_SC:-localblock}"
DEVICE_MIN_SIZE="${DEVICE_MIN_SIZE:-100Gi}"
DEVICE_MAX_SIZE="${DEVICE_MAX_SIZE:-200Gi}"
DEVICE_SIZE="${DEVICE_SIZE:-120Gi}"
# ODF's default profile assumes 16 vCPU / 64 GiB nodes; `lean` fits 8/32.
RESOURCE_PROFILE="${RESOURCE_PROFILE:-lean}"

MANIFEST_DIR="${INSTALL_DIR}/odf/manifests"

# ── Helpers ────────────────────────────────────────────────────────────────────

log() { echo "$(date +%H:%M:%S) ── $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

command -v oc >/dev/null 2>&1 || die "oc not found in PATH"
[[ -f "${KUBECONFIG}" ]] || die "kubeconfig not found: ${KUBECONFIG}"
oc get clusterversion >/dev/null 2>&1 || die "Cannot reach the cluster with ${KUBECONFIG}"

mkdir -p "${MANIFEST_DIR}"

# Wait until `cmd` prints `expected`, polling every 15s.
wait_for() {
  local desc="$1" expected="$2" tries="$3"; shift 3
  for ((i=0; i<tries; i++)); do
    local got; got=$("$@" 2>/dev/null || true)
    log "  ${desc}: ${got:-<none>}"
    [[ "${got}" == "${expected}" ]] && return 0
    sleep 15
  done
  return 1
}

# ── Preflight ──────────────────────────────────────────────────────────────────

STORAGE_NODES=$(oc get nodes -l "${STORAGE_LABEL}" --no-headers 2>/dev/null | wc -l)
[[ "${STORAGE_NODES}" -ge 3 ]] \
  || die "Found ${STORAGE_NODES} node(s) labelled ${STORAGE_LABEL}; ODF needs at least 3. Run add-odf-nodes.sh first."
log "Found ${STORAGE_NODES} labelled storage node(s)"

if [[ -z "${ODF_CHANNEL}" ]]; then
  OCP_MINOR=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f1,2)
  ODF_CHANNEL="stable-${OCP_MINOR}"
fi
log "Using ODF channel ${ODF_CHANNEL}, LSO channel ${LSO_CHANNEL}"

oc get packagemanifest odf-operator -n openshift-marketplace >/dev/null 2>&1 \
  || die "odf-operator not found in the catalog — is the redhat-operators CatalogSource healthy?"

# ── Step 1: Local Storage Operator ─────────────────────────────────────────────

log "Installing the Local Storage Operator..."
cat > "${MANIFEST_DIR}/01-lso-operator.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-local-storage
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: local-operator-group
  namespace: openshift-local-storage
spec:
  targetNamespaces:
    - openshift-local-storage
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: local-storage-operator
  namespace: openshift-local-storage
spec:
  channel: ${LSO_CHANNEL}
  name: local-storage-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
oc apply -f "${MANIFEST_DIR}/01-lso-operator.yaml"

wait_for "LSO CSV" "Succeeded" 40 \
  bash -c 'oc get csv -n openshift-local-storage --no-headers 2>/dev/null | grep local-storage | awk "{print \$NF}"' \
  || die "Local Storage Operator did not install"

# ── Step 2: LocalVolumeSet ─────────────────────────────────────────────────────

# The toleration is mandatory when the storage nodes are tainted: LSO's
# diskmaker and discovery DaemonSets run on the nodes themselves, and without
# it they are never scheduled, so no devices are ever discovered.
log "Creating the LocalVolumeSet..."
cat > "${MANIFEST_DIR}/02-localvolumeset.yaml" <<EOF
apiVersion: local.storage.openshift.io/v1alpha1
kind: LocalVolumeSet
metadata:
  name: odf-local-block
  namespace: openshift-local-storage
spec:
  nodeSelector:
    nodeSelectorTerms:
      - matchExpressions:
          - key: ${STORAGE_LABEL}
            operator: Exists
  tolerations:
    - key: ${STORAGE_TAINT_KEY}
      value: "true"
      effect: NoSchedule
  storageClassName: ${LOCAL_SC}
  volumeMode: Block
  deviceInclusionSpec:
    deviceTypes:
      - disk
    minSize: ${DEVICE_MIN_SIZE}
    maxSize: ${DEVICE_MAX_SIZE}
EOF
oc apply -f "${MANIFEST_DIR}/02-localvolumeset.yaml"

log "Waiting for local PVs to be discovered..."
for i in $(seq 1 30); do
  PVS=$(oc get pv --no-headers 2>/dev/null | grep -c "${LOCAL_SC}" || true)
  log "  ${LOCAL_SC} PVs: ${PVS}/${STORAGE_NODES}"
  [[ "${PVS}" -ge "${STORAGE_NODES}" ]] && break
  sleep 15
done
PVS=$(oc get pv --no-headers 2>/dev/null | grep -c "${LOCAL_SC}" || true)
[[ "${PVS}" -ge 3 ]] \
  || die "Only ${PVS} local PV(s) discovered. Check the diskmaker pods in openshift-local-storage — a missing toleration for ${STORAGE_TAINT_KEY} is the usual cause."

# ── Step 3: ODF operator ───────────────────────────────────────────────────────

log "Installing the ODF operator..."
cat > "${MANIFEST_DIR}/03-odf-operator.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-storage-operatorgroup
  namespace: openshift-storage
spec:
  targetNamespaces:
    - openshift-storage
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: odf-operator
  namespace: openshift-storage
spec:
  channel: ${ODF_CHANNEL}
  name: odf-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
oc apply -f "${MANIFEST_DIR}/03-odf-operator.yaml"

# odf-operator creates an odf-dependencies Subscription that pulls in ~11
# CSVs. Those bundles sit in BundleUnpacking for a few minutes before
# anything appears, and the StorageCluster CRD only exists once they land.
log "Waiting for the ODF operators (odf-dependencies pulls in ~11 CSVs)..."
for i in $(seq 1 60); do
  TOTAL=$(oc get csv -n openshift-storage --no-headers 2>/dev/null | wc -l)
  OK=$(oc get csv -n openshift-storage --no-headers 2>/dev/null | awk '$NF=="Succeeded"' | wc -l)
  CRD=$(oc get crd storageclusters.ocs.openshift.io --no-headers 2>/dev/null | wc -l)
  log "  CSVs ${OK}/${TOTAL} Succeeded | StorageCluster CRD: ${CRD}"
  [[ "${CRD}" -eq 1 && "${TOTAL}" -gt 1 && "${OK}" -eq "${TOTAL}" ]] && break
  sleep 20
done
oc get crd storageclusters.ocs.openshift.io >/dev/null 2>&1 \
  || die "StorageCluster CRD never appeared — check the odf-dependencies Subscription"

# ── Step 4: StorageCluster ─────────────────────────────────────────────────────

log "Creating the StorageCluster (resourceProfile: ${RESOURCE_PROFILE})..."
cat > "${MANIFEST_DIR}/04-storagecluster.yaml" <<EOF
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: openshift-storage
spec:
  resourceProfile: ${RESOURCE_PROFILE}
  monDataDirHostPath: /var/lib/rook
  manageNodes: false
  storageDeviceSets:
    - name: ocs-deviceset-localblock
      count: 1
      replica: ${STORAGE_NODES}
      portable: false
      dataPVCTemplate:
        spec:
          accessModes:
            - ReadWriteOnce
          storageClassName: ${LOCAL_SC}
          volumeMode: Block
          resources:
            requests:
              storage: ${DEVICE_SIZE}
EOF
oc apply -f "${MANIFEST_DIR}/04-storagecluster.yaml"

# OSDs are brought up one at a time, so transient "1 osds down" and
# "pgs peering" warnings during rollout are expected.
log "Waiting for the StorageCluster to become Ready (10-15 minutes)..."
for i in $(seq 1 60); do
  PHASE=$(oc get storagecluster ocs-storagecluster -n openshift-storage -o jsonpath='{.status.phase}' 2>/dev/null || true)
  OSDS=$(oc get pods -n openshift-storage --no-headers 2>/dev/null | grep -E 'rook-ceph-osd-[0-9]-' | awk '$2=="2/2"' | wc -l)
  log "  phase=${PHASE:-?} osds_ready=${OSDS}/${STORAGE_NODES}"
  [[ "${PHASE}" == "Ready" ]] && break
  sleep 30
done
[[ "$(oc get storagecluster ocs-storagecluster -n openshift-storage -o jsonpath='{.status.phase}' 2>/dev/null)" == "Ready" ]] \
  || die "StorageCluster did not reach Ready — check 'oc get pods -n openshift-storage'"

# ── Step 5: Console plugin ─────────────────────────────────────────────────────

# Installing by Subscription does not enable the plugin; only the web console's
# OperatorHub flow does. Without this the Data Foundation UI never appears.
if oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' 2>/dev/null | grep -q 'odf-console'; then
  log "ODF console plugin already enabled"
else
  log "Enabling the ODF console plugin..."
  oc patch console.operator.openshift.io cluster --type=json \
    -p '[{"op":"add","path":"/spec/plugins/-","value":"odf-console"}]' >/dev/null
fi

# ── Verify ─────────────────────────────────────────────────────────────────────

log "Waiting for Ceph health..."
for i in $(seq 1 20); do
  HEALTH=$(oc get cephcluster -n openshift-storage -o jsonpath='{.items[0].status.ceph.health}' 2>/dev/null || true)
  log "  ceph: ${HEALTH:-?}"
  [[ "${HEALTH}" == "HEALTH_OK" ]] && break
  sleep 30
done

echo ""
log "═══════════════════════════════════════════════════════════"
log "  ODF installed"
log "═══════════════════════════════════════════════════════════"
echo ""
oc get storagecluster -n openshift-storage
echo ""
echo "Storage classes:"
oc get sc --no-headers | awk '{print "  "$1}'
echo ""
echo "Ceph health : $(oc get cephcluster -n openshift-storage -o jsonpath='{.items[0].status.ceph.health}' 2>/dev/null)"
echo "Manifests   : ${MANIFEST_DIR}"
echo ""
echo "A fresh install reports three AUTH_INSECURE_* warnings about Ceph key"
echo "types. They are cosmetic defaults, not a fault."
