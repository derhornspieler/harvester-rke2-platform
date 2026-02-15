#!/usr/bin/env bash
set -euo pipefail

# --- Colors & Logging ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Constants ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_DIR="$(cd "${SCRIPT_DIR}/../cluster" && pwd)"
KUBECONFIG_FILE="${SCRIPT_DIR}/kubeconfig-harvester.yaml"

# --- Helper Functions ---

check_prerequisites() {
  local missing=()
  for cmd in kubectl terraform; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing[*]}"
    exit 1
  fi
  log_ok "Prerequisites found: kubectl, terraform"
}

ensure_kubeconfig() {
  if [[ -f "$KUBECONFIG_FILE" ]]; then
    log_ok "Kubeconfig found: ${KUBECONFIG_FILE}"
    return
  fi

  # Try to symlink from cluster/ directory
  if [[ -f "${CLUSTER_DIR}/kubeconfig-harvester.yaml" ]]; then
    ln -sf "${CLUSTER_DIR}/kubeconfig-harvester.yaml" "$KUBECONFIG_FILE"
    log_ok "Symlinked kubeconfig from cluster/"
    return
  fi

  # Try to extract from ~/.kube/config
  log_info "Extracting kubeconfig from ~/.kube/config (context: harvester)..."
  if kubectl config view --minify --context=harvester --raw > "$KUBECONFIG_FILE" 2>/dev/null && [[ -s "$KUBECONFIG_FILE" ]]; then
    chmod 600 "$KUBECONFIG_FILE"
    log_ok "Kubeconfig extracted"
    return
  fi

  rm -f "$KUBECONFIG_FILE"
  log_error "No Harvester kubeconfig found."
  log_error "Place kubeconfig-harvester.yaml in this directory, or ensure cluster/ has one."
  exit 1
}

tf_init() {
  cd "$SCRIPT_DIR"
  if [[ ! -d .terraform ]] || ! terraform validate -no-color &>/dev/null 2>&1; then
    log_info "Initializing Terraform..."
    terraform init -input=false
    echo
  fi
}

# --- Commands ---

cmd_apply() {
  check_prerequisites
  ensure_kubeconfig
  tf_init

  local plan_file="tfplan_$(date +%Y%m%d_%H%M%S)"
  log_info "Running: terraform plan -out=${plan_file}"
  cd "$SCRIPT_DIR"
  terraform plan -out="$plan_file"
  echo

  log_info "Running: terraform apply ${plan_file}"
  terraform apply "$plan_file"
  rm -f "$plan_file"
  echo

  log_ok "Dev VM provisioned!"
  echo
  terraform output ssh_command
}

cmd_destroy() {
  check_prerequisites
  ensure_kubeconfig
  tf_init

  log_info "Running: terraform destroy $*"
  cd "$SCRIPT_DIR"
  terraform destroy "$@"
}

cmd_ssh() {
  cd "$SCRIPT_DIR"
  local ip
  ip=$(terraform output -raw vm_ip 2>/dev/null || true)
  if [[ -z "$ip" ]]; then
    log_error "VM IP not available. Is the VM running?"
    exit 1
  fi

  local user
  user=$(terraform output -raw ssh_command 2>/dev/null | awk -F@ '{print $1}' | awk '{print $NF}')
  [[ -z "$user" ]] && user="rocky"

  log_info "Connecting to ${user}@${ip} (tmux attach || new session)..."
  ssh "${user}@${ip}" -t 'tmux attach -t dev 2>/dev/null || tmux new -s dev'
}

cmd_terraform() {
  check_prerequisites
  ensure_kubeconfig
  tf_init

  log_info "Running: terraform $*"
  cd "$SCRIPT_DIR"
  terraform "$@"
}

# --- Main ---

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [args...]

Commands:
  apply           Plan + apply the dev VM
  destroy         Destroy the dev VM
  ssh             SSH into the VM (auto-attaches tmux)
  <any>           Run 'terraform <any>' (e.g., plan, output, state)

Examples:
  $(basename "$0") apply
  $(basename "$0") ssh
  $(basename "$0") destroy -auto-approve
  $(basename "$0") output ssh_command
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
  apply)
    cmd_apply
    ;;
  destroy)
    cmd_destroy "$@"
    ;;
  ssh)
    cmd_ssh
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    cmd_terraform "$COMMAND" "$@"
    ;;
esac
