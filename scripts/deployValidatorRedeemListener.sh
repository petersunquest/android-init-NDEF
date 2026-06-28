#!/usr/bin/env bash
# Deploy ValidatorDepositRedeem event listener to a CoNET validator node (default 38.102.85.33).
# Does NOT restart geth/beacon — listener restart waits for 08_import subprocesses; post-deploy runs 09_ensure_validator_running.
# Does NOT copy ~/.master.json between hosts (see beamio-no-master-json-remote-copy.mdc).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
X402SDK_DIR="$REPO_ROOT/src/x402sdk"
VALIDATOR_NODE_SCRIPTS="$REPO_ROOT/scripts/validator-node"
SYSTEMD_UNIT="$X402SDK_DIR/service/systemd/conet-validator-redeem-listener.service"
PRYSM_VALIDATOR_SERVICE="$X402SDK_DIR/service/systemd/conet-prysm-validator.service"
PRYSM_VALIDATOR_SUDOERS="$VALIDATOR_NODE_SCRIPTS/conet-prysm-validator.sudoers"
WATCHDOG_SERVICE="$X402SDK_DIR/service/systemd/conet-prysm-validator-watchdog.service"
WATCHDOG_TIMER="$X402SDK_DIR/service/systemd/conet-prysm-validator-watchdog.timer"
ENV_EXAMPLE="$X402SDK_DIR/service/conet-validator-redeem-listener.env.example"

VALIDATOR_LISTENER_HOST="${VALIDATOR_LISTENER_HOST:-38.102.85.33}"
VALIDATOR_LISTENER_USER="${VALIDATOR_LISTENER_USER:-peter}"
VALIDATOR_LISTENER_ROOT="${VALIDATOR_LISTENER_ROOT:-/home/peter/x402sdk}"
VALIDATOR_NEWCONET_DIR="${VALIDATOR_NEWCONET_DIR:-/home/peter/ethereum-pos-mainnet}"
VALIDATOR_LISTENER_SERVICE="${VALIDATOR_LISTENER_SERVICE:-conet-validator-redeem-listener.service}"
PRYSM_VALIDATOR_SYSTEMD_UNIT="${PRYSM_VALIDATOR_SYSTEMD_UNIT:-conet-prysm-validator.service}"
VALIDATOR_NODE_IP="${VALIDATOR_NODE_IP:-38.102.85.33}"
DEPOSIT_KEY_FILE="${VALIDATOR_NEWCONET_DIR}/secrets/deposit_sender_private_key.txt"

SSH_TARGET="${VALIDATOR_LISTENER_USER}@${VALIDATOR_LISTENER_HOST}"

SKIP_BUILD=0
SKIP_RESTART=0
FORCE_ENV=0
DRY_RUN=0

usage() {
	cat <<'EOF'
Usage: scripts/deployValidatorRedeemListener.sh [options]

Deploy ValidatorDepositRedeem listener daemon to a validator node.

Default:
  1) cd src/x402sdk && npm run build
  2) rsync dist/ -> validator host ~/x402sdk/dist/
  3) Install /etc/default/conet-validator-redeem-listener + systemd unit
  4) Copy 01_generate_listener wrapper + 06/07/08 validator helper scripts into newCoNET dir
  5) Preflight: Node >= 20, remote ~/.master.json exists (NOT copied by this script)
  6) systemctl enable --now conet-validator-redeem-listener

Options:
  --skip-build      Skip local compile
  --skip-restart    Do not start/restart systemd service
  --force-env       Replace /etc/default/conet-validator-redeem-listener entirely (default: merge, preserve secrets)
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
  secrets/validator_keystore_password.txt  Prysm keystore password (or set KEYSTORE_PASSWORD in env file).
  secrets/prysm_wallet_password.txt        Prysm wallet password (or set WALLET_PASSWORD in env file).
  Install key only: scripts/installValidatorNodeRedeemAdminKey.sh
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--skip-build) SKIP_BUILD=1; shift ;;
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

if [[ "$SKIP_BUILD" -eq 0 ]]; then
	echo "==> Building x402sdk locally"
	( cd "$X402SDK_DIR" && npm run build )
fi

for required in dist/endpoint/validatorDepositRedeemListenerDaemon.js dist/endpoint/validatorDepositRedeem.js dist/endpoint/validatorRewardHourlyReporter.js; do
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
	"$VALIDATOR_NODE_SCRIPTS/01_generate_append_validator_deposits_listener.sh" \
	"$VALIDATOR_NODE_SCRIPTS/06_exit_validator.sh" \
	"$VALIDATOR_NODE_SCRIPTS/07_update_fee_recipient.sh" \
	"$VALIDATOR_NODE_SCRIPTS/08_import_append_validator_keys.sh" \
	"$VALIDATOR_NODE_SCRIPTS/09_ensure_validator_running.sh" \
	"$VALIDATOR_NODE_SCRIPTS/10_run_prysm_validator.sh" \
	"${SSH_TARGET}:${VALIDATOR_NEWCONET_DIR}/"
if [[ "$DRY_RUN" -eq 0 ]]; then
	ssh "$SSH_TARGET" "chmod +x '${VALIDATOR_NEWCONET_DIR}/01_generate_append_validator_deposits_listener.sh' '${VALIDATOR_NEWCONET_DIR}/06_exit_validator.sh' '${VALIDATOR_NEWCONET_DIR}/07_update_fee_recipient.sh' '${VALIDATOR_NEWCONET_DIR}/08_import_append_validator_keys.sh' '${VALIDATOR_NEWCONET_DIR}/09_ensure_validator_running.sh' '${VALIDATOR_NEWCONET_DIR}/10_run_prysm_validator.sh'"
fi

KEYSTORE_PW_FILE="${VALIDATOR_NEWCONET_DIR}/secrets/validator_keystore_password.txt"
WALLET_PW_FILE="${VALIDATOR_NEWCONET_DIR}/secrets/prysm_wallet_password.txt"

echo "==> Install systemd unit + environment defaults"
if [[ "$DRY_RUN" -eq 0 ]]; then
	rsync -av "$SYSTEMD_UNIT" "${SSH_TARGET}:/tmp/conet-validator-redeem-listener.service"
	ssh "$SSH_TARGET" "sudo mv /tmp/conet-validator-redeem-listener.service /etc/systemd/system/${VALIDATOR_LISTENER_SERVICE} && sudo systemctl daemon-reload"
	ENV_TMP="$(mktemp)"
	sed \
		-e "s|CONET_VALIDATOR_NODE_IP=.*|CONET_VALIDATOR_NODE_IP=${VALIDATOR_NODE_IP}|" \
		-e "s|CONET_VALIDATOR_NEWCONET_DIR=.*|CONET_VALIDATOR_NEWCONET_DIR=${VALIDATOR_NEWCONET_DIR}|" \
		-e "s|CONET_VALIDATOR_REDEEM_ADMIN_PRIVATE_KEY_FILE=.*|CONET_VALIDATOR_REDEEM_ADMIN_PRIVATE_KEY_FILE=${DEPOSIT_KEY_FILE}|" \
		-e "s|CONET_VALIDATOR_DEPOSIT_PRIVATE_KEY_FILE=.*|CONET_VALIDATOR_DEPOSIT_PRIVATE_KEY_FILE=${DEPOSIT_KEY_FILE}|" \
		-e "s|CONET_VALIDATOR_KEYSTORE_PASSWORD_FILE=.*|CONET_VALIDATOR_KEYSTORE_PASSWORD_FILE=${KEYSTORE_PW_FILE}|" \
		-e "s|CONET_VALIDATOR_WALLET_PASSWORD_FILE=.*|CONET_VALIDATOR_WALLET_PASSWORD_FILE=${WALLET_PW_FILE}|" \
		-e "s|^# CONET_VALIDATOR_HOURLY_REWARD_REPORT=1|CONET_VALIDATOR_HOURLY_REWARD_REPORT=1|" \
		-e "s|^# CONET_VALIDATOR_BEACON_REST_URL=.*|CONET_VALIDATOR_BEACON_REST_URL=http://127.0.0.1:4100|" \
		-e "s|^# CONET_VALIDATOR_HOURLY_REWARD_STATE_FILE=.*|CONET_VALIDATOR_HOURLY_REWARD_STATE_FILE=/home/peter/.conet-validator-hourly-reward-state.json|" \
		"$ENV_EXAMPLE" > "$ENV_TMP"
	if [[ "$FORCE_ENV" -eq 1 ]]; then
		echo "==> Replace /etc/default/conet-validator-redeem-listener (--force-env)"
		rsync -av "$ENV_TMP" "${SSH_TARGET}:/tmp/conet-validator-redeem-listener.env"
		ssh "$SSH_TARGET" "sudo mv /tmp/conet-validator-redeem-listener.env /etc/default/conet-validator-redeem-listener && sudo chmod 640 /etc/default/conet-validator-redeem-listener"
	else
		echo "==> Merge /etc/default/conet-validator-redeem-listener (preserve KEYSTORE_PASSWORD / custom lines)"
		rsync -av "$ENV_TMP" "${SSH_TARGET}:/tmp/conet-validator-redeem-listener.env.new"
		ssh "$SSH_TARGET" bash -s -- "$KEYSTORE_PW_FILE" "$VALIDATOR_NODE_IP" "$VALIDATOR_NEWCONET_DIR" "$DEPOSIT_KEY_FILE" <<'REMOTE'
set -euo pipefail
KEYSTORE_PW_FILE="$1"
NODE_IP="$2"
NEWCONET_DIR="$3"
DEPOSIT_KEY="$4"
ENV_PATH="/etc/default/conet-validator-redeem-listener"
NEW_ENV="/tmp/conet-validator-redeem-listener.env.new"
if [[ ! -f "$ENV_PATH" ]]; then
	sudo mv "$NEW_ENV" "$ENV_PATH"
else
	sudo cp "$ENV_PATH" "${ENV_PATH}.bak.$(date +%Y%m%d%H%M%S)"
	sudo cp "$ENV_PATH" /tmp/conet-validator-redeem-listener.env.merge
	sudo chmod 644 /tmp/conet-validator-redeem-listener.env.merge
	merge_kv() {
		local key="$1"
		local val="$2"
		if sudo grep -qE "^${key}=" /tmp/conet-validator-redeem-listener.env.merge; then
			sudo sed -i "s|^${key}=.*|${key}=${val}|" /tmp/conet-validator-redeem-listener.env.merge
		else
			echo "${key}=${val}" | sudo tee -a /tmp/conet-validator-redeem-listener.env.merge >/dev/null
		fi
	}
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
		key="${line%%=*}"
		val="${line#*=}"
		case "$key" in
			KEYSTORE_PASSWORD) continue ;; # never overwrite inline secret from template
		esac
		merge_kv "$key" "$val"
	done < "$NEW_ENV"
	sudo mv /tmp/conet-validator-redeem-listener.env.merge "$ENV_PATH"
	rm -f "$NEW_ENV"
fi
sudo chmod 640 "$ENV_PATH"
REMOTE
	fi
	rm -f "$ENV_TMP"

	echo "==> Install Prysm validator systemd unit (${PRYSM_VALIDATOR_SYSTEMD_UNIT})"
	rsync -av "$PRYSM_VALIDATOR_SERVICE" "${SSH_TARGET}:/tmp/${PRYSM_VALIDATOR_SYSTEMD_UNIT}"
	rsync -av "$PRYSM_VALIDATOR_SUDOERS" "${SSH_TARGET}:/tmp/conet-prysm-validator.sudoers"
	ssh "$SSH_TARGET" bash -s -- "$VALIDATOR_NEWCONET_DIR" "$PRYSM_VALIDATOR_SYSTEMD_UNIT" <<'REMOTE'
set -euo pipefail
NEWCONET_DIR="$1"
UNIT="$2"
sudo mv "/tmp/${UNIT}" "/etc/systemd/system/${UNIT}"
sudo mv /tmp/conet-prysm-validator.sudoers /etc/sudoers.d/conet-prysm-validator-peter
sudo chmod 440 /etc/sudoers.d/conet-prysm-validator-peter
sudo visudo -cf /etc/sudoers.d/conet-prysm-validator-peter
mkdir -p "${NEWCONET_DIR}/network/node-0/logs"
# Stop legacy nohup orphan before handoff to systemd
pkill -f "validator.*${NEWCONET_DIR}/network/node-0/consensus/validatordata" 2>/dev/null || true
sleep 2
rm -f "${NEWCONET_DIR}/network/node-0/validator.pid"
sudo systemctl daemon-reload
sudo systemctl enable "${UNIT}"
sudo systemctl restart "${UNIT}"
REMOTE

	echo "==> Install Prysm validator watchdog timer (09_ensure_validator_running every 5m)"
	rsync -av "$WATCHDOG_SERVICE" "${SSH_TARGET}:/tmp/conet-prysm-validator-watchdog.service"
	rsync -av "$WATCHDOG_TIMER" "${SSH_TARGET}:/tmp/conet-prysm-validator-watchdog.timer"
	ssh "$SSH_TARGET" bash -s <<'REMOTE'
set -euo pipefail
sudo mv /tmp/conet-prysm-validator-watchdog.service /etc/systemd/system/conet-prysm-validator-watchdog.service
sudo mv /tmp/conet-prysm-validator-watchdog.timer /etc/systemd/system/conet-prysm-validator-watchdog.timer
sudo systemctl daemon-reload
sudo systemctl enable conet-prysm-validator-watchdog.timer
sudo systemctl restart conet-prysm-validator-watchdog.timer
REMOTE
	echo "==> Prysm validator status"
	ssh "$SSH_TARGET" "systemctl is-active ${PRYSM_VALIDATOR_SYSTEMD_UNIT} && systemctl show -p MainPID --value ${PRYSM_VALIDATOR_SYSTEMD_UNIT}"
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
	echo "==> Preflight (no secrets copied)"
	ssh "$SSH_TARGET" bash -s -- "$DEPOSIT_KEY_FILE" "$VALIDATOR_NEWCONET_DIR" <<'REMOTE'
set -euo pipefail
DEPOSIT_KEY="$1"
NEWCONET_DIR="$2"
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
KEYSTORE_PW_FILE="${NEWCONET_DIR}/secrets/validator_keystore_password.txt"
WALLET_PW_FILE="${NEWCONET_DIR}/secrets/prysm_wallet_password.txt"
if [[ -f /etc/default/conet-validator-redeem-listener ]] && grep -qE '^KEYSTORE_PASSWORD=' /etc/default/conet-validator-redeem-listener 2>/dev/null; then
	echo "OK: KEYSTORE_PASSWORD set in /etc/default/conet-validator-redeem-listener"
elif [[ -f /etc/default/conet-validator-redeem-listener ]] && grep -qE '^CONET_VALIDATOR_KEYSTORE_PASSWORD_FILE=' /etc/default/conet-validator-redeem-listener 2>/dev/null; then
	echo "OK: CONET_VALIDATOR_KEYSTORE_PASSWORD_FILE set in /etc/default/conet-validator-redeem-listener"
elif [[ -f "$KEYSTORE_PW_FILE" ]]; then
	echo "OK: validator keystore password file present ($KEYSTORE_PW_FILE)"
else
	echo "WARNING: KEYSTORE_PASSWORD / CONET_VALIDATOR_KEYSTORE_PASSWORD_FILE missing." >&2
	echo "ValidatorRedeemClaimed will fail at generate validators until configured." >&2
	echo "Create $KEYSTORE_PW_FILE (chmod 600) or add KEYSTORE_PASSWORD to /etc/default/conet-validator-redeem-listener." >&2
fi
if [[ -f /etc/default/conet-validator-redeem-listener ]] && grep -qE '^WALLET_PASSWORD=' /etc/default/conet-validator-redeem-listener 2>/dev/null; then
	echo "OK: WALLET_PASSWORD set in /etc/default/conet-validator-redeem-listener"
elif [[ -f /etc/default/conet-validator-redeem-listener ]] && grep -qE '^CONET_VALIDATOR_WALLET_PASSWORD_FILE=' /etc/default/conet-validator-redeem-listener 2>/dev/null; then
	echo "OK: CONET_VALIDATOR_WALLET_PASSWORD_FILE set in /etc/default/conet-validator-redeem-listener"
elif [[ -f "$WALLET_PW_FILE" ]]; then
	echo "OK: Prysm wallet password file present ($WALLET_PW_FILE)"
else
	echo "WARNING: WALLET_PASSWORD / CONET_VALIDATOR_WALLET_PASSWORD_FILE missing." >&2
	echo "ValidatorRedeemClaimed will fail at generate validators until configured." >&2
	echo "Create $WALLET_PW_FILE (chmod 600) or add WALLET_PASSWORD to /etc/default/conet-validator-redeem-listener." >&2
fi
REMOTE
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
	echo "==> Prysm import backfill skipped (run manually after wallet passwords verified):"
	echo "    ssh ${SSH_TARGET} 'cd ${VALIDATOR_NEWCONET_DIR} && ./08_import_append_validator_keys.sh'"
fi

if [[ "$SKIP_RESTART" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
	echo "==> Enable + restart ${VALIDATOR_LISTENER_SERVICE}"
	ssh "$SSH_TARGET" "sudo systemctl enable ${VALIDATOR_LISTENER_SERVICE} && sudo systemctl restart ${VALIDATOR_LISTENER_SERVICE}"
	sleep 4
	echo "==> Service status"
	ssh "$SSH_TARGET" "systemctl is-active ${VALIDATOR_LISTENER_SERVICE} && sudo journalctl -u ${VALIDATOR_LISTENER_SERVICE} -n 15 --no-pager -q"
	echo "==> Hourly reward reporter (expect validatorRewardHourlyReporter starting when CONET_VALIDATOR_REDEEM_LISTENER=1)"
	ssh "$SSH_TARGET" "sudo journalctl -u ${VALIDATOR_LISTENER_SERVICE} -n 80 --no-pager -q | grep -E 'validatorRewardHourlyReporter|validatorDepositRedeemListener' | tail -n 8 || true"
	echo "==> Ensure Prysm validator client is up (post listener restart)"
	ssh "$SSH_TARGET" "cd '${VALIDATOR_NEWCONET_DIR}' && ./09_ensure_validator_running.sh"
fi

echo "==> Done. Listener on ${VALIDATOR_LISTENER_HOST} (nodeIp=${VALIDATOR_NODE_IP})."
echo "    Configure secrets on that host only — never copy ~/.master.json from elsewhere."
