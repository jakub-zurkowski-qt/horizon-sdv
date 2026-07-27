#!/usr/bin/env bash
#
# Description:
# Wrapper around ./container-deploy.sh that PRESERVES the Cloud DNS managed zone
# across a destroy/apply cycle, so the parent-domain NS delegation your DNS admin
# set up stays valid and does NOT have to be redone on the next apply.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform/env"
TFVARS="${TF_DIR}/terraform.tfvars"
CONTAINER_DEPLOY="${SCRIPT_DIR}/container-deploy.sh"

# Must match container-deploy.sh (state ops run in the SAME image => same terraform
# version as the deploy, so the remote state stays readable by both).
IMAGE_NAME="horizon-sdv-deployer:latest"
GCLOUD_CONFIG_VOLUME="horizon-deployer-gcloud-config"

# Terraform address of the managed zone. Structural (not env-specific); override with
# --tf-address if the module layout changes. The module has count, hence the [0].
TF_ADDR_DEFAULT='module.base.module.sdv_dns_zone[0].google_dns_managed_zone.sdv-cloud-dns-zone'

MODE=""
RETRY=0
YES=0
SKIP_WS_CLEANUP=0
SKIP_ARGO_FIX=0
PROJECT=""; BUCKET=""; ENV_NAME=""; ROOT_DOMAIN=""; REGION=""; ZONE=""; TF_ADDR="${TF_ADDR_DEFAULT}"
WS_CLUSTER=""                          # target WS cluster; empty = all clusters in the region
WS_HOST_SA="sdv-cloud-ws-host-vm-sa"   # host-VM SA the Create-Configuration pipeline leaves behind
GKE_CLUSTER=""                         # GKE cluster for the Argo finalizer fix; empty = discover in region

usage() {
  cat <<EOF
Usage: $(basename "$0") <-d | -a> [--retry] [overrides]

Preserves the Cloud DNS managed zone across a teardown/redeploy so the delegation
your DNS admin created (parent-domain NS records -> this zone's name servers) keeps
working WITHOUT asking them again. The zone's name servers only ever change if the
zone is recreated, so the trick is to keep the same zone object alive:

  -d   "stash":   first delete the Cloud Workstations resources (workstations, configs,
                  cluster) + the leftover host-VM service account -- these are created by
                  Jenkins pipelines (not Terraform), and the WS cluster's forwarding rule
                  pins the subnet and blocks the destroy. Then remove the zone from
                  Terraform state so destroy will NOT delete it, strip the Argo CD
                  Application finalizers (they otherwise stall destroy ~20 min with a
                  cascade-prune timeout), run ./container-deploy.sh -d, and confirm the
                  zone survived with unchanged name servers.
  -a   "unstash": import the surviving zone back into Terraform state so apply reuses
                  it (instead of creating a new zone with new name servers), run
                  ./container-deploy.sh -a, then confirm name servers are unchanged.

  --retry   Re-run after ./container-deploy.sh failed mid-cycle, WITHOUT repeating the
            stash/unstash. Use it when the zone is already stashed (for -d) or already
            unstashed (for -a) and you only need to re-run the deploy step.

FIRST-TIME SETUP / NOT reusing DNS:
  Do NOT use this wrapper the first time you stand up the environment (no zone exists
  yet), or whenever you deliberately want a fresh zone. Just run the normal command:
      ./container-deploy.sh -a      # first-time apply (creates the zone; then delegate)
      ./container-deploy.sh -d      # plain teardown (deletes the zone)

Variables are read from ${TFVARS#"${REPO_ROOT}/"} unless overridden:
  --project <id>       (sdv_gcp_project_id)
  --bucket <name>      (sdv_gcp_backend_bucket)   -- terraform state backend bucket
  --env-name <name>    (sdv_env_name)             -- sub-domain label
  --root-domain <dom>  (sdv_root_domain)          -- parent domain
  --zone <name>        managed-zone name (default: looked up by DNS name via gcloud)
  --tf-address <addr>  Terraform address of the zone (default: ${TF_ADDR_DEFAULT})
  --region <region>    (sdv_gcp_region)  -- region of the Cloud Workstations resources
  --ws-cluster <name>  clean only this WS cluster (default: all clusters in the region)
  --ws-host-sa <name>  host-VM SA short name (default: sdv-cloud-ws-host-vm-sa)
  --gke-cluster <name> GKE cluster for the Argo finalizer fix (default: discover in region)
  --skip-ws-cleanup    do NOT touch Cloud Workstations resources (-d only)
  --skip-argo-fix      do NOT strip Argo CD Application finalizers (-d only)
  --yes                skip the confirmation prompt before deleting WS resources

Requirements: host gcloud (authenticated to the project) + docker; the deployer image
(built by container-deploy.sh on first run) provides the version-matched terraform.
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*"; }

# Read a value from terraform.tfvars (strips surrounding quotes/whitespace).
tfvar() {
  [[ -f "$TFVARS" ]] || return 0
  grep -E "^[[:space:]]*$1[[:space:]]*=" "$TFVARS" | head -1 \
    | sed -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//; s/^\"//; s/\"[[:space:]]*\$//; s/[[:space:]]*\$//"
}

# ---- args --------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|-a) MODE="$1" ;;
    --retry) RETRY=1 ;;
    --project) PROJECT="$2"; shift ;;
    --bucket) BUCKET="$2"; shift ;;
    --env-name) ENV_NAME="$2"; shift ;;
    --root-domain) ROOT_DOMAIN="$2"; shift ;;
    --zone) ZONE="$2"; shift ;;
    --tf-address) TF_ADDR="$2"; shift ;;
    --region) REGION="$2"; shift ;;
    --ws-cluster) WS_CLUSTER="$2"; shift ;;
    --ws-host-sa) WS_HOST_SA="$2"; shift ;;
    --gke-cluster) GKE_CLUSTER="$2"; shift ;;
    --skip-ws-cleanup) SKIP_WS_CLEANUP=1 ;;
    --skip-argo-fix) SKIP_ARGO_FIX=1 ;;
    --yes) YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

[[ "$MODE" == "-d" || "$MODE" == "-a" ]] || { usage; exit 2; }

command -v gcloud >/dev/null 2>&1 || die "gcloud not found on PATH (needed for DNS checks)."
command -v docker >/dev/null 2>&1 || die "docker not found on PATH."
[[ -f "$TFVARS" ]] || die "Not found: $TFVARS"
[[ -x "$CONTAINER_DEPLOY" ]] || die "Not found/executable: $CONTAINER_DEPLOY"
if [[ -z "$(docker images -q "$IMAGE_NAME" 2>/dev/null)" ]]; then
  die "Deployer image '$IMAGE_NAME' not built yet. Run ./container-deploy.sh once first (it builds the image and sets up gcloud auth)."
fi

# ---- resolve variables -------------------------------------------------------
PROJECT="${PROJECT:-$(tfvar sdv_gcp_project_id)}"
BUCKET="${BUCKET:-$(tfvar sdv_gcp_backend_bucket)}"
ENV_NAME="${ENV_NAME:-$(tfvar sdv_env_name)}"
ROOT_DOMAIN="${ROOT_DOMAIN:-$(tfvar sdv_root_domain)}"
REGION="${REGION:-$(tfvar sdv_gcp_region)}"
[[ -n "$PROJECT" ]] || die "sdv_gcp_project_id not set (pass --project)."
[[ -n "$BUCKET"  ]] || die "sdv_gcp_backend_bucket not set (pass --bucket)."
[[ -n "$ENV_NAME" && -n "$ROOT_DOMAIN" ]] || die "sdv_env_name / sdv_root_domain not set (pass --env-name/--root-domain)."

DNS_NAME="${ENV_NAME}.${ROOT_DOMAIN}."

# ---- gcloud helpers (host) ---------------------------------------------------
find_zone() {
  gcloud dns managed-zones list --project="$PROJECT" \
    --filter="dnsName=${DNS_NAME}" --format="value(name)" 2>/dev/null | head -1
}
get_ns() {  # $1 = zone name
  gcloud dns managed-zones describe "$1" --project="$PROJECT" \
    --format="value(nameServers)" 2>/dev/null
}

# ---- terraform in the deployer container (version-matched to the deploy) ------
run_tf() {  # $1 = terraform sub-command line, e.g. "state list"
  docker run --rm \
    --platform linux/amd64 -u 0 \
    -e TF_IN_AUTOMATION=1 -e TF_DATA_DIR=/tmp/.tf-dns-reuse \
    -v "${GCLOUD_CONFIG_VOLUME}:/root/.config/gcloud" \
    -v "${REPO_ROOT}:/repo" \
    -w /repo/terraform/env \
    "$IMAGE_NAME" \
    bash -lc "terraform init -input=false -reconfigure -backend-config='bucket=${BUCKET}' >/dev/null && terraform $1"
}
# NOTE: -F (fixed string) is essential -- the address contains '[0]' (counted module),
# which as a regex is a character class and would never match the literal state output.
zone_in_state() { run_tf "state list" 2>/dev/null | grep -Fxq "$TF_ADDR"; }

# ---- Cloud Workstations pre-teardown cleanup (idempotent; -d only) -----------
# WS cluster/configs/workstations are created by Jenkins pipelines, NOT Terraform, so
# container-deploy.sh -d never removes them; the WS cluster's forwarding rule pins the
# subnet and blocks the destroy, and the leftover host-VM service account later 409s the
# next Create Configuration. This deletes them in reverse order and is idempotent, so it
# is safe to re-run under --retry.
cleanup_workstations() {
  [[ "$SKIP_WS_CLEANUP" -eq 1 ]] && { info "Skipping Cloud Workstations cleanup (--skip-ws-cleanup)."; return 0; }
  [[ -n "$REGION" ]] || die "sdv_gcp_region not set (pass --region) - needed for Cloud Workstations cleanup."

  local clusters sa_email sa_exists="" cl cfg ws
  if [[ -n "$WS_CLUSTER" ]]; then
    clusters="$WS_CLUSTER"
  else
    clusters="$(gcloud workstations clusters list --region="$REGION" --project="$PROJECT" --format='value(name)' 2>/dev/null || true)"
  fi
  sa_email="${WS_HOST_SA}@${PROJECT}.iam.gserviceaccount.com"
  gcloud iam service-accounts describe "$sa_email" --project="$PROJECT" >/dev/null 2>&1 && sa_exists="$sa_email"

  if [[ -z "$clusters" && -z "$sa_exists" ]]; then
    info "No Cloud Workstations clusters or host-VM service account found - nothing to clean."
    return 0
  fi

  echo
  echo "Cloud Workstations resources to DELETE (not managed by Terraform; block the teardown):"
  for cl in $clusters; do
    echo "  cluster: $cl"
    for cfg in $(gcloud workstations configs list --cluster="$cl" --region="$REGION" --project="$PROJECT" --format='value(name)' 2>/dev/null || true); do
      echo "    config: $cfg"
      for ws in $(gcloud workstations list --cluster="$cl" --config="$cfg" --region="$REGION" --project="$PROJECT" --format='value(name)' 2>/dev/null || true); do
        echo "      workstation: $ws"
      done
    done
  done
  [[ -n "$sa_exists" ]] && echo "  service account: $sa_exists"
  echo

  if [[ "$YES" -ne 1 ]]; then
    local ans=""
    read -r -p "Delete these Cloud Workstations resources? [y/N] " ans || true
    [[ "$ans" == "y" || "$ans" == "Y" ]] || die "Aborted before Cloud Workstations cleanup (re-run with --yes to skip this prompt)."
  fi

  for cl in $clusters; do
    for cfg in $(gcloud workstations configs list --cluster="$cl" --region="$REGION" --project="$PROJECT" --format='value(name)' 2>/dev/null || true); do
      for ws in $(gcloud workstations list --cluster="$cl" --config="$cfg" --region="$REGION" --project="$PROJECT" --format='value(name)' 2>/dev/null || true); do
        info "Deleting workstation $ws (config $cfg)"
        gcloud workstations delete "$ws" --cluster="$cl" --config="$cfg" --region="$REGION" --project="$PROJECT" --quiet || true
      done
      info "Deleting config $cfg (cluster $cl)"
      gcloud workstations configs delete "$cfg" --cluster="$cl" --region="$REGION" --project="$PROJECT" --quiet || true
    done
    info "Deleting cluster $cl (takes a few minutes; drops its forwarding rule)"
    gcloud workstations clusters delete "$cl" --region="$REGION" --project="$PROJECT" --quiet || true
  done

  if [[ -n "$sa_exists" ]]; then
    info "Deleting orphaned host-VM service account $sa_exists"
    gcloud iam service-accounts delete "$sa_exists" --project="$PROJECT" --quiet || true
  fi

  local fr
  fr="$(gcloud compute forwarding-rules list --project="$PROJECT" --filter="region:$REGION AND name~workstations-cluster" --format='value(name)' 2>/dev/null || true)"
  if [[ -n "$fr" ]]; then
    info "WARNING: workstation forwarding rule(s) still present, subnet may stay pinned: $fr"
  else
    info "No workstation forwarding rules remain - subnet is free."
  fi
}

# ---- Argo CD Application finalizer strip (best-effort; -d only) ---------------
# The argocd Application carries a resources-finalizer that makes its deletion cascade-
# prune every child and time out ("context deadline exceeded"), stalling terraform destroy
# for ~20 min. The whole cluster is being destroyed anyway, so strip the finalizers up
# front and the Application objects delete instantly. Best-effort: if the cluster is gone
# or kubectl/creds are unavailable, skip (then strip manually if destroy hangs).
clear_argo_finalizers() {
  [[ "$SKIP_ARGO_FIX" -eq 1 ]] && { info "Skipping Argo finalizer fix (--skip-argo-fix)."; return 0; }
  command -v kubectl >/dev/null 2>&1 || { info "kubectl not found; skipping Argo finalizer fix (strip manually if destroy hangs on the Argo Application)."; return 0; }
  [[ -n "$REGION" ]] || { info "Region unknown; skipping Argo finalizer fix."; return 0; }

  local cluster="$GKE_CLUSTER"
  [[ -n "$cluster" ]] || cluster="$(gcloud container clusters list --region="$REGION" --project="$PROJECT" --format='value(name)' 2>/dev/null | head -1)"
  if [[ -z "$cluster" ]]; then
    info "No GKE cluster found in ${REGION} (already gone); skipping Argo finalizer fix."
    return 0
  fi

  info "Connecting to GKE cluster '$cluster' to clear Argo CD Application finalizers..."
  if ! gcloud container clusters get-credentials "$cluster" --region="$REGION" --project="$PROJECT" >/dev/null 2>&1; then
    info "Could not get credentials for '$cluster'; skipping Argo finalizer fix (strip manually if destroy hangs)."
    return 0
  fi

  local apps
  apps="$(kubectl -n argocd get applications.argoproj.io -o name 2>/dev/null || true)"
  if [[ -z "$apps" ]]; then
    info "No Argo CD Applications found; nothing to clear."
    return 0
  fi
  info "Stripping finalizers so the Applications delete without cascade-prune:"
  printf '  %s\n' $apps
  printf '%s\n' "$apps" | xargs -r -I{} kubectl -n argocd patch {} --type merge \
    -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 \
    || info "WARNING: some finalizer patches failed; if destroy hangs on the Argo Application, strip finalizers manually."
}

# ---- resolve zone ------------------------------------------------------------
[[ -n "$ZONE" ]] || ZONE="$(find_zone)"

echo "Project        : $PROJECT"
echo "Backend bucket : $BUCKET"
echo "Region         : ${REGION:-<unset>}"
echo "DNS name       : $DNS_NAME"
echo "Managed zone   : ${ZONE:-<none found>}"
echo "TF address     : $TF_ADDR"
echo "Mode           : $MODE${RETRY:+ (retry)}"
echo

# =============================== DESTROY (-d) =================================
if [[ "$MODE" == "-d" ]]; then
  PRESERVE=1
  NS_BEFORE=""
  if [[ -z "$ZONE" ]]; then
    echo "WARNING: no managed zone found for ${DNS_NAME}."
    echo "         DNS will NOT be preserved -- the zone is already gone (e.g. a previous"
    echo "         teardown deleted it) or this is a fresh env. Continuing the teardown anyway;"
    echo "         the NEXT apply will create a new zone with NEW name servers, so your DNS admin"
    echo "         will have to re-delegate. (This is still useful: it cleans the Cloud"
    echo "         Workstations resources that block the destroy.)"
    PRESERVE=0
  else
    NS_BEFORE="$(get_ns "$ZONE")"
    [[ -n "$NS_BEFORE" ]] || die "Could not read name servers for zone $ZONE."
    info "Current name servers: $NS_BEFORE"
  fi

  # Delete the (non-Terraform) Cloud Workstations resources first so the destroy is not
  # blocked by the WS cluster's subnet-pinning forwarding rule. Idempotent => safe under --retry.
  cleanup_workstations

  if [[ "$PRESERVE" -eq 1 ]]; then
    info "Reading Terraform state to locate the managed zone..."
    if ! STATE_LIST="$(run_tf 'state list')"; then
      die "Could not read Terraform state (init/auth failed). Aborting so the destroy does not run unprotected."
    fi
    if printf '%s\n' "$STATE_LIST" | grep -Fxq "$TF_ADDR"; then
      info "Stashing: removing $TF_ADDR from Terraform state so destroy will not delete the zone."
      run_tf "state rm '$TF_ADDR'" || die "terraform state rm failed. Aborting."
    elif printf '%s\n' "$STATE_LIST" | grep -Fq 'google_dns_managed_zone'; then
      die "A google_dns_managed_zone is tracked in state, but NOT at the expected address:
$(printf '%s\n' "$STATE_LIST" | grep -F 'google_dns_managed_zone')
Re-run with --tf-address '<that address>'. Aborting so the destroy does not delete the zone."
    else
      info "No managed zone in Terraform state (already stashed); continuing."
    fi

    # Fail-closed: NEVER run the destroy while a managed zone is still tracked in state.
    if ! STATE_AFTER="$(run_tf 'state list')"; then
      die "Could not re-read Terraform state before destroy. Aborting."
    fi
    if printf '%s\n' "$STATE_AFTER" | grep -Fq 'google_dns_managed_zone'; then
      die "SAFETY ABORT: a google_dns_managed_zone is still tracked in Terraform state; the destroy would DELETE it. Not running destroy."
    fi
    info "Confirmed: no managed zone in Terraform state -- safe to destroy the rest."
  fi

  # Strip Argo CD Application finalizers so the destroy does not stall for ~20 min.
  clear_argo_finalizers

  info "Running: ${CONTAINER_DEPLOY} -d"
  "$CONTAINER_DEPLOY" -d

  if [[ "$PRESERVE" -eq 1 ]]; then
    info "Verifying the zone survived with unchanged name servers..."
    ZONE_AFTER="$(find_zone)"
    [[ -n "$ZONE_AFTER" ]] || die "Zone $ZONE was DELETED by the teardown -- DNS was not preserved."
    NS_AFTER="$(get_ns "$ZONE_AFTER")"
    if [[ "$NS_AFTER" == "$NS_BEFORE" ]]; then
      echo
      echo "OK: zone '$ZONE_AFTER' preserved; name servers unchanged:"
      echo "    $NS_AFTER"
      echo "Delegation stays valid. Next apply: $(basename "$0") -a"
    else
      die "Name servers CHANGED (before: $NS_BEFORE / after: $NS_AFTER). Delegation may need updating."
    fi
  else
    echo
    echo "Teardown complete. DNS was NOT preserved (no zone existed to stash); on the next"
    echo "apply a new zone is created -- delegate its name servers again."
  fi
  exit 0
fi

# ================================ APPLY (-a) ==================================
if [[ "$MODE" == "-a" ]]; then
  if [[ -z "$ZONE" ]]; then
    die "No preserved managed zone found for ${DNS_NAME}. If this is first-time setup, run: ./container-deploy.sh -a (creates a new zone; you must then delegate its name servers)."
  fi
  NS_BEFORE="$(get_ns "$ZONE")"
  [[ -n "$NS_BEFORE" ]] || die "Could not read name servers for zone $ZONE."
  info "Preserved zone name servers: $NS_BEFORE"

  if [[ "$RETRY" -eq 1 ]]; then
    if zone_in_state; then
      info "--retry: zone already unstashed (present in Terraform state); skipping import."
    else
      info "--retry, but zone is NOT in Terraform state (not unstashed). Importing it now."
      run_tf "import '$TF_ADDR' '${PROJECT}/${ZONE}'"
    fi
  else
    if zone_in_state; then
      info "Zone already present in Terraform state (already unstashed); continuing."
    else
      info "Unstashing: importing existing zone into Terraform state so apply reuses it."
      run_tf "import '$TF_ADDR' '${PROJECT}/${ZONE}'"
    fi
  fi

  info "Running: ${CONTAINER_DEPLOY} -a"
  "$CONTAINER_DEPLOY" -a

  info "Verifying name servers are unchanged..."
  NS_AFTER="$(get_ns "$(find_zone)")"
  if [[ "$NS_AFTER" == "$NS_BEFORE" ]]; then
    echo
    echo "OK: name servers unchanged -- existing delegation still valid, no admin needed:"
    echo "    $NS_AFTER"
  else
    echo
    echo "WARNING: name servers CHANGED (before: $NS_BEFORE / after: $NS_AFTER)."
    echo "The zone may have been recreated; you will need your DNS admin to re-delegate."
  fi
  exit 0
fi
