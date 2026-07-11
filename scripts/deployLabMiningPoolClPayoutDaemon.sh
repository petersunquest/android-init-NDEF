#!/usr/bin/env bash
# Deploy Lab CL skim → ConetLabMiningPool daemon to a CoNET VA host (default 74.208.224.45).
# Does NOT restart geth/beacon/validator. Does NOT copy ~/.master.json — installs only
# redeem_contract_admin.txt if missing (from local MASTER_JSON via pickRedeemContractAdminKey.mjs).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
X402SDK_DIR="$REPO_ROOT/src/x402sdk"
SYSTEMD_UNIT="$X402SDK_DIR/service/systemd/conet-lab-mining-pool-cl-payout.service"
ENV_EXAMPLE="$X402SDK_DIR/service/conet-lab-mining-pool-cl-payout.env.example"
MANIFEST="$REPO_ROOT/deployments/conet-lab-mining-pool-pubkeys.json"

LAB_DAEMON_HOST="${LAB_DAEMON_HOST:-74.208.224.45}"
LAB_DAEMON_USER="${LAB_DAEMON_USER:-peter}"
LAB_DAEMON_ROOT="${LAB_DAEMON_ROOT:-/home/peter/x402sdk}"
LAB_DAEMON_SERVICE="${LAB_DAEMON_SERVICE:-conet-lab-mining-pool-cl-payout.service}"
ADMIN_KEY_FILE="${LAB_DAEMON_ADMIN_KEY_FILE:-/home/peter/secrets/redeem_contract_admin.txt}"

SSH_TARGET="${LAB_DAEMON_USER}@${LAB_DAEMON_HOST}"

SKIP_BUILD=0
SKIP_AGGREGATE=0
SKIP_RESTART=0
FORCE_ENV=0
DRY_RUN=0

usage() {
	cat <<'EOF'
Usage: scripts/deployLabMiningPoolClPayoutDaemon.sh [options]

Deploy standalone Lab CL payout daemon (withdrawNative → ConetLabMiningPool).

Default host: 74.208.224.45 (local beacon REST :4100 + EL RPC).

Options:
  --skip-build       Skip local npm run build
  --skip-aggregate   Skip node scripts/aggregateLabMiningPoolPubkeys.mjs
  --skip-restart     Do not systemctl enable/restart service
  --force-env        Replace /etc/default/conet-lab-mining-pool-cl-payout entirely
  --dry-run          rsync dry-run only
  -h, --help

Environment:
  LAB_DAEMON_HOST              SSH host (default: 74.208.224.45)
  LAB_DAEMON_USER              SSH user (default: peter)
  LAB_DAEMON_ROOT              Remote x402sdk root (default: /home/peter/x402sdk)
  LAB_DAEMON_ADMIN_KEY_FILE    Remote admin key path (default: /home/peter/secrets/redeem_contract_admin.txt)
  MASTER_JSON                  Local master.json for pickRedeemContractAdminKey.mjs (default: ~/.master.json)
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--skip-build) SKIP_BUILD=1; shift ;;
		--skip-aggregate) SKIP_AGGREGATE=1; shift ;;
		--skip-restart) SKIP_RESTART=1; shift ;;
		--force-env) FORCE_ENV=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
	esac
done

RSYNC_FLAGS=(-av)
if [[ "$DRY_RUN" -eq 1 ]]; then
	RSYNC_FLAGS+=(--dry-run)
fi

if [[ "$SKIP_AGGREGATE" -eq 0 ]]; then
	echo "==> Aggregate Lab pubkeys (current + legacy backups)"
	node "$REPO_ROOT/scripts/aggregateLabMiningPoolPubkeys.mjs"
fi

if [[ ! -f "$MANIFEST" ]]; then
	echo "Missing $MANIFEST — run node scripts/aggregateLabMiningPoolPubkeys.mjs" >&2
	exit 1
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
	echo "==> Building x402sdk locally"
	( cd "$X402SDK_DIR" && npm run build )
fi

for required in dist/endpoint/labMiningPoolClPayoutDaemon.js dist/endpoint/validatorLabMiningPoolClPayoutReporter.js; do
	if [[ ! -f "$X402SDK_DIR/$required" ]]; then
		echo "Missing $X402SDK_DIR/$required" >&2
		exit 1
	fi
done

echo "==> Prepare remote ${SSH_TARGET}:${LAB_DAEMON_ROOT}"
if [[ "$DRY_RUN" -eq 0 ]]; then
	ssh "$SSH_TARGET" "mkdir -p '${LAB_DAEMON_ROOT}/deployments' '$(dirname "$ADMIN_KEY_FILE")'"
fi

echo "==> Rsync dist/ → remote"
rsync "${RSYNC_FLAGS[@]}" "$X402SDK_DIR/dist/" "${SSH_TARGET}:${LAB_DAEMON_ROOT}/dist/"

echo "==> Rsync package.json + pubkey manifest"
rsync "${RSYNC_FLAGS[@]}" \
	"$X402SDK_DIR/package.json" \
	"$X402SDK_DIR/package-lock.json" \
	"$MANIFEST" \
	"${SSH_TARGET}:${LAB_DAEMON_ROOT}/"
if [[ "$DRY_RUN" -eq 0 ]]; then
	ssh "$SSH_TARGET" "mv '${LAB_DAEMON_ROOT}/conet-lab-mining-pool-pubkeys.json' '${LAB_DAEMON_ROOT}/deployments/conet-lab-mining-pool-pubkeys.json'"
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
	echo "==> npm install on remote"
	ssh "$SSH_TARGET" "cd '${LAB_DAEMON_ROOT}' && npm install --no-audit --no-fund"
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
	echo "==> Ensure Redeem contract admin key on remote (minimal secret only)"
	if ssh "$SSH_TARGET" "test -s '${ADMIN_KEY_FILE}'"; then
		echo "    ${ADMIN_KEY_FILE} already exists — skip install"
	else
		TMP_PK="$(mktemp)"
		trap 'rm -f "$TMP_PK"' EXIT
		node "$REPO_ROOT/scripts/pickRedeemContractAdminKey.mjs" >"$TMP_PK"
		rsync -av "$TMP_PK" "${SSH_TARGET}:/tmp/redeem_contract_admin.txt"
		ssh "$SSH_TARGET" "mv /tmp/redeem_contract_admin.txt '${ADMIN_KEY_FILE}' && chmod 600 '${ADMIN_KEY_FILE}'"
		echo "    installed ${ADMIN_KEY_FILE}"
	fi
fi

echo "==> Install systemd unit + environment"
if [[ "$DRY_RUN" -eq 0 ]]; then
	rsync -av "$SYSTEMD_UNIT" "${SSH_TARGET}:/tmp/${LAB_DAEMON_SERVICE}"
	ssh "$SSH_TARGET" "sudo mv /tmp/${LAB_DAEMON_SERVICE} /etc/systemd/system/${LAB_DAEMON_SERVICE} && sudo systemctl daemon-reload"

	ENV_TMP="$(mktemp)"
	sed \
		-e "s|CONET_LAB_MINING_POOL_PUBKEYS_FILE=.*|CONET_LAB_MINING_POOL_PUBKEYS_FILE=${LAB_DAEMON_ROOT}/deployments/conet-lab-mining-pool-pubkeys.json|" \
		-e "s|CONET_LAB_MINING_POOL_CL_PAYOUT_ADMIN_PRIVATE_KEY_FILE=.*|CONET_LAB_MINING_POOL_CL_PAYOUT_ADMIN_PRIVATE_KEY_FILE=${ADMIN_KEY_FILE}|" \
		"$ENV_EXAMPLE" >"$ENV_TMP"

	if [[ "$FORCE_ENV" -eq 1 ]]; then
		rsync -av "$ENV_TMP" "${SSH_TARGET}:/tmp/conet-lab-mining-pool-cl-payout.env"
		ssh "$SSH_TARGET" "sudo mv /tmp/conet-lab-mining-pool-cl-payout.env /etc/default/conet-lab-mining-pool-cl-payout && sudo chmod 640 /etc/default/conet-lab-mining-pool-cl-payout"
	else
		rsync -av "$ENV_TMP" "${SSH_TARGET}:/tmp/conet-lab-mining-pool-cl-payout.env.new"
		ssh "$SSH_TARGET" bash -s -- "$LAB_DAEMON_ROOT" "$ADMIN_KEY_FILE" <<'REMOTE'
set -euo pipefail
ROOT="$1"
ADMIN_KEY="$2"
ENV_PATH="/etc/default/conet-lab-mining-pool-cl-payout"
NEW_ENV="/tmp/conet-lab-mining-pool-cl-payout.env.new"
if [[ ! -f "$ENV_PATH" ]]; then
	sudo mv "$NEW_ENV" "$ENV_PATH"
else
	sudo cp "$ENV_PATH" "${ENV_PATH}.bak.$(date +%Y%m%d%H%M%S)"
	sudo cp "$ENV_PATH" /tmp/conet-lab-mining-pool-cl-payout.env.merge
	sudo chmod 644 /tmp/conet-lab-mining-pool-cl-payout.env.merge
	merge_kv() {
		local key="$1"
		local val="$2"
		if sudo grep -qE "^${key}=" /tmp/conet-lab-mining-pool-cl-payout.env.merge; then
			sudo sed -i "s|^${key}=.*|${key}=${val}|" /tmp/conet-lab-mining-pool-cl-payout.env.merge
		else
			echo "${key}=${val}" | sudo tee -a /tmp/conet-lab-mining-pool-cl-payout.env.merge >/dev/null
		fi
	}
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
		key="${line%%=*}"
		val="${line#*=}"
		merge_kv "$key" "$val"
	done < "$NEW_ENV"
	sudo mv /tmp/conet-lab-mining-pool-cl-payout.env.merge "$ENV_PATH"
	rm -f "$NEW_ENV"
fi
sudo chmod 640 "$ENV_PATH"
REMOTE
	fi
	rm -f "$ENV_TMP"
fi

if [[ "$SKIP_RESTART" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
	echo "==> Enable and restart ${LAB_DAEMON_SERVICE}"
	ssh "$SSH_TARGET" "sudo systemctl enable ${LAB_DAEMON_SERVICE} && sudo systemctl restart ${LAB_DAEMON_SERVICE}"
	sleep 3
	ssh "$SSH_TARGET" "systemctl is-active ${LAB_DAEMON_SERVICE} && journalctl -u ${LAB_DAEMON_SERVICE} -n 15 --no-pager"
fi

echo ""
echo "==> Done. Lab CL payout daemon on ${LAB_DAEMON_HOST}"
echo "    manifest: ${LAB_DAEMON_ROOT}/deployments/conet-lab-mining-pool-pubkeys.json"
echo "    logs:     ssh ${SSH_TARGET} journalctl -u ${LAB_DAEMON_SERVICE} -f"
