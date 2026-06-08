#!/usr/bin/env bash
set -Eeuo pipefail

# One-shot helper for issuing a Let's Encrypt certificate via Cloudflare DNS
# and installing it to a fixed location for xboard-node cert_mode=file.

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $*"; }

usage() {
  cat <<'EOF'
Usage:
  sudo bash issue-cloudflare-cert.sh DOMAIN [EMAIL] [options]
  sudo bash issue-cloudflare-cert.sh -d DOMAIN [-e EMAIL] [options]

Optional:
  DOMAIN                      Domain to issue, e.g. hklite1.example.com
  EMAIL                       ACME account email, optional
  -d, --domain DOMAIN         Domain, same as positional DOMAIN
  -e, --email EMAIL           Email, same as positional EMAIL
  -t, --token TOKEN           Cloudflare API Token; omitted means secure hidden prompt
  -o, --output-dir DIR        Target cert directory (default: /etc/xboard-node/ssl)
  -n, --name NAME             Output file prefix (default: derived from domain)
  -r, --restart CMD           Command to run after cert install
      --force                 Force re-issue even if a cert already exists
  -h, --help                  Show this help

Examples:
  sudo bash issue-cloudflare-cert.sh hklite1.apifrrgrtdd.lol you@example.com \
    -r "systemctl restart xboard-node"

  sudo bash issue-cloudflare-cert.sh -d hklite1.apifrrgrtdd.lol \
    -e you@example.com \
    -r "systemctl restart xboard-node"

Result files:
  /etc/xboard-node/ssl/<name>.crt
  /etc/xboard-node/ssl/<name>.key
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "missing command: $cmd"
    exit 1
  fi
}

prompt_from_tty() {
  local prompt_text="$1"
  local secret="${2:-0}"
  local value=""

  if [ ! -r /dev/tty ]; then
    log_error "missing required argument and no interactive TTY is available"
    exit 1
  fi

  if [ "$secret" -eq 1 ]; then
    read -r -s -p "$prompt_text" value </dev/tty
    echo >/dev/tty
  else
    read -r -p "$prompt_text" value </dev/tty
  fi

  printf '%s' "$value"
}

sanitize_name() {
  local raw="$1"
  raw="${raw,,}"
  raw="${raw//[^a-z0-9._-]/-}"
  raw="${raw//./-}"
  raw="${raw//--/-}"
  printf '%s' "$raw"
}

DOMAIN=""
CF_TOKEN=""
ACME_EMAIL=""
OUTPUT_DIR="/etc/xboard-node/ssl"
OUTPUT_NAME=""
RESTART_CMD=""
FORCE_ISSUE=0
POSITIONAL=()

while (($# > 0)); do
  case "$1" in
    -d|--domain)
      DOMAIN="${2:-}"
      shift 2
      ;;
    -t|--token)
      CF_TOKEN="${2:-}"
      shift 2
      ;;
    -e|--email)
      ACME_EMAIL="${2:-}"
      shift 2
      ;;
    -o|--output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    -n|--name)
      OUTPUT_NAME="${2:-}"
      shift 2
      ;;
    -r|--restart)
      RESTART_CMD="${2:-}"
      shift 2
      ;;
    --force)
      FORCE_ISSUE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [ ${#POSITIONAL[@]} -gt 0 ] && [ -z "$DOMAIN" ]; then
  DOMAIN="${POSITIONAL[0]}"
fi

if [ ${#POSITIONAL[@]} -gt 1 ] && [ -z "$ACME_EMAIL" ]; then
  ACME_EMAIL="${POSITIONAL[1]}"
fi

if [ ${#POSITIONAL[@]} -gt 2 ]; then
  log_error "too many positional arguments"
  usage
  exit 1
fi

if [ -z "$DOMAIN" ]; then
  log_error "domain is required"
  usage
  exit 1
fi

if [ -z "$CF_TOKEN" ]; then
  CF_TOKEN="$(prompt_from_tty 'Enter Cloudflare API Token: ' 1)"
fi

if [ "$EUID" -ne 0 ]; then
  log_error "please run as root so the cert can be installed under $OUTPUT_DIR"
  exit 1
fi

require_cmd bash
require_cmd curl

if [ -z "$OUTPUT_NAME" ]; then
  OUTPUT_NAME="$(sanitize_name "$DOMAIN")"
fi

CERT_FILE="${OUTPUT_DIR}/${OUTPUT_NAME}.crt"
KEY_FILE="${OUTPUT_DIR}/${OUTPUT_NAME}.key"
ACME_HOME="${HOME}/.acme.sh"
ACME_SH="${ACME_HOME}/acme.sh"

log_step "Preparing directories"
mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"

if [ ! -x "$ACME_SH" ]; then
  log_step "Installing acme.sh"
  curl -fsSL https://get.acme.sh | sh
fi

if [ ! -x "$ACME_SH" ]; then
  log_error "acme.sh installation failed"
  exit 1
fi

log_step "Registering ACME account if needed"
if [ -n "$ACME_EMAIL" ]; then
  "$ACME_SH" --register-account -m "$ACME_EMAIL" >/dev/null 2>&1 || true
else
  "$ACME_SH" --register-account --accountemail "noreply@${DOMAIN}" >/dev/null 2>&1 || true
fi

log_step "Selecting Let's Encrypt as CA"
"$ACME_SH" --set-default-ca --server letsencrypt

log_step "Issuing certificate for $DOMAIN via Cloudflare DNS"
export CF_Token="$CF_TOKEN"
ISSUE_ARGS=(--issue --dns dns_cf -d "$DOMAIN")
if [ "$FORCE_ISSUE" -eq 1 ]; then
  ISSUE_ARGS+=(--force)
fi
"$ACME_SH" "${ISSUE_ARGS[@]}"

log_step "Installing certificate files"
"$ACME_SH" --install-cert -d "$DOMAIN" \
  --key-file "$KEY_FILE" \
  --fullchain-file "$CERT_FILE"

chmod 600 "$CERT_FILE" "$KEY_FILE"

if [ -n "$RESTART_CMD" ]; then
  log_step "Running restart command"
  bash -lc "$RESTART_CMD"
fi

cat <<EOF

[DONE] Certificate installed successfully.

Files:
  cert_file: $CERT_FILE
  key_file:  $KEY_FILE

Add this to your xboard-node instance config:

cert:
  cert_mode: file
  cert_file: $CERT_FILE
  key_file: $KEY_FILE

If you are using machine mode, put the block above inside the matching item under:
  instances:

Suggested restart:
  xbctl service restart
or:
  systemctl restart xboard-node
EOF
