#!/usr/bin/env bash
# Deploy ValidatorDepositRedeem event listener to a CoNET validator node (default 38.102.85.33).
# Does NOT restart geth/beacon/validator — only installs x402sdk listener daemon + helper scripts.
# Does NOT copy ~/.master.json between hosts (see beamio-no-master-json-remote-copy.mdc).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
X402SDK_DIR="$REPO_ROOT/src/x402sdk"
SYSTEMD_UNIT="$X402SDK_DIR/service/systemd/conet-validator-redeem-listener.service"
ENV_EXAMPLE="$X402SDK_DIR/service/conet-validator-redeem-listener.env.example"
VALIDATOR_NODE_SCRIPTS="$REPO_ROOT/scripts/validator-node"

VALIDATOR_LISTENER_HOST="${VALIDATOR_LISTENER_HOST:-38.102.85.33}"
VALIDATOR_LISTENER_USER="${VALIDATOR_LISTENER_USER:-peter}"
VALIDATOR_LISTENER_ROOT="${VALIDATOR_LISTENER_ROOT:-/home/peter/x402sdk}"
VALIDATOR_NEWCONET_DIR="${VALIDATOR_NEWCONET_DIR:-/home/peter/ethereum-pos-mainnet}"
VALIDATOR_LISTENER_SERVICE="${VALIDATOR_LISTENER_SERVICE:-conet-validator-redeem-listener.service}"
VALIDATOR_NODE_IP="${VALIDATOR_NODE_IP:-38.102.85.33}"
DEPOSIT_KEY_FILE="${VALIDATOR_NEWCONET_DIR}/secrets/deposit_sender_private_key.txt"

SSH_TARGET="${VALIDATOR_LISTENER_USER}@${VALIDATOR_LISTENER_HOST}"

SKIP_BUILD=0
SKIP_RESTART=0
DRY_RUN=0

usage() {
	cat <<'EOF'
Usage: scripts/deployValidatorRedeemListener.sh [options]

Deploy ValidatorDepositRedeem listener daemon to a validator node.

Default:
  1) cd src/x402sdk && npm run build
  2) rsync dist/ -> validator host ~/x402sdk/dist/
  3) Install /etc/default/conet-validator-redeem-listener + systemd unit
  4) Copy 06_exit_validator.sh / 07_update_fee_recipient.sh into newCoNET dir
  5) Preflight: Node >= 20, remote ~/.master.json exists (NOT copied by this script)
  6) systemctl enable --now conet-validator-redeem-listener

Options:
  --skip-build      Skip local compile
  --skip-restart    Do not start/restart systemd service
  --dry-run         rsync dry-run only
  -h, --help

Environment:
  VALIDATOR_LISTENER_HOST    SSH host (default: 38.102.85.33)
  VALIDATOR_LISTENER_USER      SSH user (default: peter)
  VALIDATOR_LISTENER_ROOT      Remote x402sdk root (default: /home/peter/x402sdk)
  VALIDATOR_NEWCONET_DIR       CoNET stack dir on validator (default: /home/peter/ethereum-pos-mainnet)
  VALIDATOR_NODE_IP            CONET_VALIDATOR_NODE_IP (default: 38.102.85.33)

Secrets (must exist ON TARGET HOST before claim redeems — never copied by this script):
  ~/.master.json               Created/maintained locally on that server only (Settle pool / other ops)
  secrets/deposit_sender_private_key.txt   Redeem admin key (key_38.102.85.33 → 0xE974…6d1E);
                                           signs fundAndDepositValidators; stake paid from contract balance.
  Install key only: scripts/installValidatorNodeRedeemAdminKey.sh
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--skip-build) SKIP_BUILD=1; shift ;;
		--skip-restart) SKIP_RESTART=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
	esac
done

RSYNC_FLAGS=(-av)
if [[ "$DRY_RUN" -eq 1 ]]; then
	RSYNC_FLAGS+=(--dry-run)
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
	echo "==> Building x402sdk locally"
	( cd "$X402SDK_DIR" && npm run build )
fi

for required in dist/endpoint/validatorDepositRedeemListenerDaemon.js dist/endpoint/validatorDepositRedeem.js; do
	if [[ ! -f "$X402SDK_DIR/$required" ]]; then
		echo "Missing $X402SDK_DIR/$required — run npm run build in src/x402sdk first." >&2
		exit 1
	fi
done

echo "==> Prepare remote directory ${SSH_TARGET}:${VALIDATOR_LISTENER_ROOT}"
if [[ "$DRY_RUN" -eq 0 ]]; then
	ssh "$SSH_TARGET" "mkdir -p '${VALIDATOR_LISTENER_ROOT}'"
fi

echo "==> Rsync dist/ -> ${SSH_TARGET}:${VALIDATOR_LISTENER_ROOT}/dist/"
rsync "${RSYNC_FLAGS[@]}" "$X402SDK_DIR/dist/" "${SSH_TARGET}:${VALIDATOR_LISTENER_ROOT}/dist/"

echo "==> Rsync package.json + npm install"
rsync "${RSYNC_FLAGS[@]}" \
	"$X402SDK_DIR/package.json" \
	"$X402SDK_DIR/package-lock.json" \
	"${SSH_TARGET}:${VALIDATOR_LISTENER_ROOT}/"
if [[ "$DRY_RUN" -eq 0 ]]; then
	ssh "$SSH_TARGET" "cd '${VALIDATOR_LISTENER_ROOT}' && npm install --no-audit --no-fund"
fi

echo "==> Install validator helper scripts into ${VALIDATOR_NEWCONET_DIR}"
rsync "${RSYNC_FLAGS[@]}" \
	"$VALIDATOR_NODE_SCRIPTS/06_exit_validator.sh" \
	"$VALIDATOR_NODE_SCRIPTS/07_update_fee_recipient.sh" \
	"${SSH_TARGET}:${VALIDATOR_NEWCONET_DIR}/"
if [[ "$DRY_RUN" -eq 0 ]]; then
	ssh "$SSH_TARGET" "chmod +x '${VALIDATOR_NEWCONET_DIR}/06_exit_validator.sh' '${VALIDATOR_NEWCONET_DIR}/07_update_fee_recipient.sh'"
fi

echo "==> Install systemd unit + environment defaults"
if [[ "$DRY_RUN" -eq 0 ]]; then
	rsync -av "$SYSTEMD_UNIT" "${SSH_TARGET}:/tmp/conet-validator-redeem-listener.service"
	ssh "$SSH_TARGET" "sudo mv /tmp/conet-validator-redeem-listener.service /etc/systemd/system/${VALIDATOR_LISTENER_SERVICE} && sudo systemctl daemon-reload"
	ENV_TMP="$(mktemp)"
	sed \
		-e "s|CONET_VALIDATOR_NODE_IP=.*|CONET_VALIDATOR_NODE_IP=${VALIDATOR_NODE_IP}|" \
		-e "s|CONET_VALIDATOR_NEWCONET_DIR=.*|CONET_VALIDATOR_NEWCONET_DIR=${VALIDATOR_NEWCONET_DIR}|" \
		-e "s|CONET_VALIDATOR_DEPOSIT_PRIVATE_KEY_FILE=.*|CONET_VALIDATOR_DEPOSIT_PRIVATE_KEY_FILE=${DEPOSIT_KEY_FILE}|" \
		"$ENV_EXAMPLE" > "$ENV_TMP"
	rsync -av "$ENV_TMP" "${SSH_TARGET}:/tmp/conet-validator-redeem-listener.env"
	rm -f "$ENV_TMP"
	ssh "$SSH_TARGET" "sudo mv /tmp/conet-validator-redeem-listener.env /etc/default/conet-validator-redeem-listener && sudo chmod 640 /etc/default/conet-validator-redeem-listener"
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
	echo "==> Preflight (no secrets copied)"
	ssh "$SSH_TARGET" bash -s -- "$DEPOSIT_KEY_FILE" <<'REMOTE'
set -euo pipefail
DEPOSIT_KEY="$1"
NODE_MAJOR="$(node -p 'parseInt(process.versions.node,10)' 2>/dev/null || echo 0)"
if [[ "$NODE_MAJOR" -lt 20 ]]; then
	echo "ERROR: Node.js >= 20 required (current: $(node -v)). Install Node 20+ on this host." >&2
	exit 1
fi
if [[ ! -f "$HOME/.master.json" ]]; then
	echo "ERROR: ~/.master.json missing on this host." >&2
	echo "Create it locally on THIS server only — do NOT scp from another machine." >&2
	echo "See .cursor/rules/beamio-no-master-json-remote-copy.mdc" >&2
	exit 1
fi
if [[ ! -f "$DEPOSIT_KEY" ]]; then
	echo "WARNING: redeem admin key missing: $DEPOSIT_KEY" >&2
	echo "Listener will start but ValidatorRedeemClaimed deposit will fail until this file exists." >&2
	echo "Run locally: scripts/installValidatorNodeRedeemAdminKey.sh (installs key_38.102.85.33 only)." >&2
else
	echo "OK: redeem admin key file present"
fi
REMOTE
fi

if [[ "$SKIP_RESTART" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
	echo "==> Enable + restart ${VALIDATOR_LISTENER_SERVICE}"
	ssh "$SSH_TARGET" "sudo systemctl enable ${VALIDATOR_LISTENER_SERVICE} && sudo systemctl restart ${VALIDATOR_LISTENER_SERVICE}"
	sleep 4
	echo "==> Service status"
	ssh "$SSH_TARGET" "systemctl is-active ${VALIDATOR_LISTENER_SERVICE} && sudo journalctl -u ${VALIDATOR_LISTENER_SERVICE} -n 15 --no-pager -q"
fi

echo "==> Done. Listener on ${VALIDATOR_LISTENER_HOST} (nodeIp=${VALIDATOR_NODE_IP})."
echo "    Configure secrets on that host only — never copy ~/.master.json from elsewhere."
