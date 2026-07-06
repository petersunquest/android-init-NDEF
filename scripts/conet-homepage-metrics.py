#!/usr/bin/env python3
"""CoNET scan homepage metrics — validators, supply audit, and daily charts."""
from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta, timezone

BLOCKSCOUT_API = os.environ.get("CONET_BLOCKSCOUT_API", "http://127.0.0.1:4080")
BEACON_API = os.environ.get("CONET_BEACON_API", "http://127.0.0.1:14100")
DB_CONTAINER = os.environ.get("CONET_DB_CONTAINER", "db")
HISTORY_DB = os.environ.get(
    "CONET_METRICS_HISTORY_DB",
    os.path.expanduser("~/.conet-metrics-history.db"),
)
SLOT_SECONDS = int(os.environ.get("CONET_SLOT_SECONDS", "12"))

# Total supply (balance audit):
#   el_circulating = sum(latest indexed EL balance per address)
#   rewards_on_cl  = CL validator balances above 32 CNET principal (not yet on EL)
#   estimated_total = el_circulating + rewards_on_cl
#   net_issuance = estimated_total - genesis_supply
# Breakdown:
#   consensus_issuance (CL) = withdrawn CL rewards + rewards_on_cl
#   el_execution_issuance   = net_issuance - consensus_issuance (block coinbase mint)
# Burnt base fees are already reflected in el_circulating. Deposits/principal are not issuance.
DEFAULT_GENESIS_SUPPLY_ETH = 1_000_000.0
DEFAULT_GENESIS_CL_BALANCE_ETH = 0.0
MAX_EFFECTIVE_DEPOSIT_WEI = 32 * 10**18
WITHDRAWAL_PRINCIPAL_WEI = 32 * 10**18
PRINCIPAL_GWEI = 32 * 10**9
BACKFILL_VERSION = "4"

_GENESIS_TIME: int | None = None
_BACKFILL_LOCK = threading.Lock()
_BACKFILL_DONE = False
_BACKFILL_STARTED = False


def _fetch_json(url: str, timeout: float = 15.0) -> dict:
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def _docker_bin() -> list[str]:
    cmd = os.environ.get("CONET_DOCKER_CMD", "docker").strip()
    return cmd.split()


def _docker_psql(sql: str) -> str:
    for docker in (_docker_bin(), ["sudo", "docker"]):
        try:
            out = subprocess.check_output(
                docker
                + [
                    "exec",
                    DB_CONTAINER,
                    "psql",
                    "-U",
                    "blockscout",
                    "-d",
                    "blockscout",
                    "-tAc",
                    sql,
                ],
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=120,
            )
            return out.strip()
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
            continue
    return "0"


def _sum_table_wei(table: str, column: str) -> int:
    sql = f"SELECT COALESCE(SUM({column}::numeric), 0) FROM {table}"
    try:
        return int(_docker_psql(sql) or 0)
    except ValueError:
        return 0


def _sum_deposits_wei(before: str | None = None) -> int:
    where = "WHERE status IN ('completed', 'pending')"
    if before:
        where += f" AND block_timestamp < '{before}'"
    sql = (
        "SELECT COALESCE(SUM(LEAST(amount::numeric, "
        f"{MAX_EFFECTIVE_DEPOSIT_WEI})), 0) FROM beacon_deposits {where}"
    )
    try:
        return int(_docker_psql(sql) or 0)
    except ValueError:
        return 0


def _sum_withdrawals_wei(before: str | None = None) -> int:
    if before:
        sql = (
            "SELECT COALESCE(SUM(w.amount::numeric), 0) FROM withdrawals w "
            "JOIN blocks b ON b.hash = w.block_hash "
            f"WHERE b.timestamp < '{before}'"
        )
    else:
        sql = "SELECT COALESCE(SUM(amount::numeric), 0) FROM withdrawals"
    try:
        return int(_docker_psql(sql) or 0)
    except ValueError:
        return 0


def _sum_burnt_fees_wei(before: str | None = None) -> int:
    where = "WHERE base_fee_per_gas IS NOT NULL AND gas_used IS NOT NULL"
    if before:
        where += f" AND timestamp < '{before}'"
    sql = (
        "SELECT COALESCE(SUM(base_fee_per_gas::numeric * gas_used::numeric), 0) "
        f"FROM blocks {where}"
    )
    try:
        return int(_docker_psql(sql) or 0)
    except ValueError:
        return 0


def _genesis_supply_eth() -> float:
    raw = os.environ.get("CONET_GENESIS_SUPPLY_ETH", "").strip()
    if raw:
        return float(raw)
    return DEFAULT_GENESIS_SUPPLY_ETH


def _genesis_cl_balance_eth() -> float:
    raw = os.environ.get("CONET_GENESIS_CL_BALANCE_ETH", "").strip()
    if raw:
        return float(raw)
    return DEFAULT_GENESIS_CL_BALANCE_ETH


def _genesis_time() -> int:
    global _GENESIS_TIME
    if _GENESIS_TIME is not None:
        return _GENESIS_TIME
    raw = os.environ.get("CONET_GENESIS_TIME", "").strip()
    if raw:
        _GENESIS_TIME = int(raw)
        return _GENESIS_TIME
    data = _fetch_json(f"{BEACON_API}/eth/v1/beacon/genesis")
    _GENESIS_TIME = int(data["data"]["genesis_time"])
    return _GENESIS_TIME


def _slot_for_day_end(day: date) -> int:
    end = datetime(day.year, day.month, day.day, tzinfo=timezone.utc) + timedelta(days=1)
    return max(0, int(end.timestamp() - _genesis_time()) // SLOT_SECONDS)


def _beacon_paginate(url_base: str, timeout: float = 30.0) -> list[dict]:
    rows: list[dict] = []
    token = None
    pages = 0
    max_pages = int(os.environ.get("CONET_BEACON_VALIDATOR_MAX_PAGES", "500"))
    while pages < max_pages:
        url = url_base
        sep = "&" if "?" in url else "?"
        if token:
            url += f"{sep}pageToken={urllib.parse.quote(token, safe='')}"
        data = _fetch_json(url, timeout=timeout)
        rows.extend(data.get("data", []))
        meta = data.get("meta") or {}
        token = meta.get("next_page_token") or meta.get("next_token")
        pages += 1
        if not token:
            break
    return rows


def _beacon_head_snapshot() -> tuple[int, float]:
    """Single paginated pass for active count and total balance at head."""
    active = 0
    total_gwei = 0
    try:
        rows = _beacon_paginate(f"{BEACON_API}/eth/v1/beacon/states/head/validators")
        for item in rows:
            total_gwei += int(item.get("balance") or 0)
            status = (item.get("status") or "").lower()
            if status.startswith("active"):
                active += 1
        if active == 0:
            active = len(rows)
    except (urllib.error.URLError, ValueError, TypeError, KeyError):
        return 0, 0.0
    return active, total_gwei / 1e9


def get_active_validators(slot: str = "head") -> int:
    if slot == "head":
        active, _ = _beacon_head_snapshot()
        return active
    try:
        rows = _beacon_paginate(
            f"{BEACON_API}/eth/v1/beacon/states/{slot}/validators?status=active"
        )
        return len(rows)
    except (urllib.error.URLError, ValueError, KeyError, TypeError):
        return 0


def get_beacon_total_balance_eth(slot: str = "head") -> float:
    if slot == "head":
        _, balance = _beacon_head_snapshot()
        return balance
    try:
        rows = _beacon_paginate(f"{BEACON_API}/eth/v1/beacon/states/{slot}/validators")
        total_gwei = sum(int(item.get("balance") or 0) for item in rows)
        return total_gwei / 1e9
    except (urllib.error.URLError, ValueError, TypeError, KeyError):
        return 0.0


def _withdrawal_rewards_wei(before: str | None = None) -> int:
    """Reward portion of CL withdrawals; the first 32 ETH of each exit is principal."""
    if before:
        sql = (
            "SELECT COALESCE(SUM(CASE "
            f"WHEN w.amount::numeric >= {WITHDRAWAL_PRINCIPAL_WEI} "
            f"THEN w.amount::numeric - {WITHDRAWAL_PRINCIPAL_WEI} "
            "ELSE w.amount::numeric END), 0) "
            "FROM withdrawals w JOIN blocks b ON b.hash = w.block_hash "
            f"WHERE b.timestamp < '{before}'"
        )
    else:
        sql = (
            "SELECT COALESCE(SUM(CASE "
            f"WHEN amount::numeric >= {WITHDRAWAL_PRINCIPAL_WEI} "
            f"THEN amount::numeric - {WITHDRAWAL_PRINCIPAL_WEI} "
            "ELSE amount::numeric END), 0) FROM withdrawals"
        )
    try:
        return int(_docker_psql(sql) or 0)
    except ValueError:
        return 0


def _beacon_rewards_on_cl_eth(slot: str = "head") -> float:
    """Consensus rewards still compounding on active validators (balance above 32 ETH)."""
    rewards_gwei = 0
    try:
        rows = _beacon_paginate(
            f"{BEACON_API}/eth/v1/beacon/states/{slot}/validators"
        )
        for item in rows:
            status = (item.get("status") or "").lower()
            if not status.startswith("active"):
                continue
            balance_gwei = int(item.get("balance") or 0)
            if balance_gwei > PRINCIPAL_GWEI:
                rewards_gwei += balance_gwei - PRINCIPAL_GWEI
    except (urllib.error.URLError, ValueError, TypeError, KeyError):
        return 0.0
    return rewards_gwei / 1e9


def compute_consensus_rewards(slot: str = "head", before: str | None = None) -> float:
    rewards_on_cl = _beacon_rewards_on_cl_eth(slot)
    withdrawn_rewards = _withdrawal_rewards_wei(before) / 1e18
    return rewards_on_cl + withdrawn_rewards - _genesis_cl_balance_eth()


def _max_block_number_before(before: str) -> int:
    sql = f"SELECT COALESCE(MAX(number), 0) FROM blocks WHERE timestamp < '{before}'"
    try:
        return int(_docker_psql(sql) or 0)
    except ValueError:
        return 0


def _sum_el_circulating_eth(max_block: int | None = None) -> float:
    """Sum latest indexed execution-layer balance per address (Blockscout)."""
    if max_block is None:
        where = ""
    else:
        where = f"WHERE block_number <= {max_block}"
    sql = f"""
    WITH latest AS (
      SELECT DISTINCT ON (address_hash) value
      FROM address_coin_balances
      {where}
      ORDER BY address_hash, block_number DESC
    )
    SELECT COALESCE(SUM(value::numeric), 0) FROM latest
    """
    try:
        return int(_docker_psql(sql) or 0) / 1e18
    except ValueError:
        return 0.0


def _supply_from_balance_audit(
    *,
    slot: str = "head",
    before: str | None = None,
    max_block: int | None = None,
) -> tuple[float, float, float, float]:
    """Return (estimated_total, el_circulating, rewards_on_cl, cl_issuance)."""
    if max_block is None and before is not None:
        max_block = _max_block_number_before(before)
    el_circ = _sum_el_circulating_eth(max_block)
    try:
        rewards_on_cl = _beacon_rewards_on_cl_eth(slot)
    except (urllib.error.URLError, ValueError, TypeError, KeyError):
        rewards_on_cl = 0.0
    cl_issuance = compute_consensus_rewards(slot, before)
    estimated_total = el_circ + rewards_on_cl
    if el_circ <= 0 and max_block and max_block > 0:
        # Pre-indexer days: fall back to genesis + CL rewards only.
        genesis_total = _genesis_supply_eth()
        burnt = _sum_burnt_fees_wei(before) / 1e18 if before else _sum_burnt_fees_wei() / 1e18
        estimated_total = genesis_total + cl_issuance - burnt
        el_circ = max(0.0, estimated_total - rewards_on_cl)
    return estimated_total, el_circ, rewards_on_cl, cl_issuance


def compute_supply_metrics(slot: str = "head") -> dict[str, float]:
    b_now = get_beacon_total_balance_eth(slot)
    w_total = _sum_withdrawals_wei() / 1e18
    d_total = _sum_deposits_wei() / 1e18
    w_rewards = _withdrawal_rewards_wei() / 1e18
    burnt = _sum_burnt_fees_wei() / 1e18
    genesis_total = _genesis_supply_eth()

    estimated_total, el_circ, rewards_on_cl, cl_issuance = _supply_from_balance_audit(slot=slot)
    net_issuance = estimated_total - genesis_total
    el_execution_issuance = max(0.0, net_issuance - cl_issuance)

    return {
        "beacon_total_balance_cnet": b_now,
        "cumulative_deposits_cnet": d_total,
        "cumulative_withdrawals_cnet": w_total,
        "cumulative_withdrawn_rewards_cnet": w_rewards,
        "el_circulating_cnet": el_circ,
        "el_execution_issuance_cnet": el_execution_issuance,
        "consensus_rewards_on_cl_cnet": rewards_on_cl,
        "consensus_issuance_cnet": cl_issuance,
        "burnt_fees_cnet": burnt,
        "net_consensus_issuance_cnet": net_issuance,
        "estimated_total_supply_cnet": estimated_total,
        "genesis_supply_cnet": genesis_total,
        "genesis_cl_balance_cnet": _genesis_cl_balance_eth(),
    }


def _genesis_validator_offset() -> int:
    raw = os.environ.get("CONET_GENESIS_VALIDATOR_OFFSET", "4").strip()
    try:
        return int(raw)
    except ValueError:
        return 4


def _count_validators_sql(before: str) -> int:
    sql = (
        "SELECT "
        "(SELECT COUNT(*) FROM beacon_deposits "
        "WHERE status IN ('completed', 'pending') "
        f"AND block_timestamp < '{before}') - "
        "(SELECT COUNT(*) FROM withdrawals w "
        "JOIN blocks b ON b.hash = w.block_hash "
        "WHERE w.amount >= 32000000000000000000 "
        f"AND b.timestamp < '{before}') + "
        f"{_genesis_validator_offset()}"
    )
    try:
        return max(0, int(_docker_psql(sql) or 0))
    except ValueError:
        return 0


def compute_day_snapshot(day: date, *, live: bool = False) -> dict[str, float | int]:
    """Daily chart point from balance audit (EL sum + CL rewards on chain)."""
    before = f"{(day + timedelta(days=1)).isoformat()} 00:00:00"
    burnt = _sum_burnt_fees_wei(before) / 1e18
    genesis_total = _genesis_supply_eth()

    if live:
        supply = compute_supply_metrics()
        return {
            "staked_validators": get_active_validators(),
            "net_consensus_issuance": supply["net_consensus_issuance_cnet"],
            "burnt_fees": supply["burnt_fees_cnet"],
            "estimated_total_supply": supply["estimated_total_supply_cnet"],
        }

    validators = _count_validators_sql(before)
    slot = str(_slot_for_day_end(day))
    max_block = _max_block_number_before(before)
    estimated_total, _, _, _ = _supply_from_balance_audit(
        slot=slot, before=before, max_block=max_block
    )
    net_issuance = estimated_total - genesis_total
    return {
        "staked_validators": validators,
        "net_consensus_issuance": net_issuance,
        "burnt_fees": burnt,
        "estimated_total_supply": estimated_total,
    }


def _history_conn() -> sqlite3.Connection:
    conn = sqlite3.connect(HISTORY_DB, timeout=30.0)
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS daily_snapshots (
            day TEXT PRIMARY KEY,
            staked_validators INTEGER NOT NULL,
            net_consensus_issuance REAL NOT NULL,
            burnt_fees REAL NOT NULL,
            estimated_total_supply REAL NOT NULL,
            updated_at TEXT NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """
    )
    return conn


def _meta_get(conn: sqlite3.Connection, key: str) -> str | None:
    row = conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
    return row[0] if row else None


def _meta_set(conn: sqlite3.Connection, key: str, value: str) -> None:
    conn.execute(
        "INSERT INTO meta(key, value) VALUES(?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        (key, value),
    )


def _upsert_snapshot(conn: sqlite3.Connection, day: date, snap: dict[str, float | int]) -> None:
    conn.execute(
        """
        INSERT INTO daily_snapshots(
            day, staked_validators, net_consensus_issuance,
            burnt_fees, estimated_total_supply, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(day) DO UPDATE SET
            staked_validators = excluded.staked_validators,
            net_consensus_issuance = excluded.net_consensus_issuance,
            burnt_fees = excluded.burnt_fees,
            estimated_total_supply = excluded.estimated_total_supply,
            updated_at = excluded.updated_at
        """,
        (
            day.isoformat(),
            int(snap["staked_validators"]),
            float(snap["net_consensus_issuance"]),
            float(snap["burnt_fees"]),
            float(snap["estimated_total_supply"]),
            datetime.now(timezone.utc).isoformat(),
        ),
    )


def _chain_start_day() -> date:
    raw = _docker_psql(
        "SELECT COALESCE(MIN(timestamp)::date::text, CURRENT_DATE::text) FROM blocks"
    )
    try:
        return date.fromisoformat(raw)
    except ValueError:
        return datetime.now(timezone.utc).date()


def _backfill_history(force: bool = False) -> None:
    global _BACKFILL_DONE
    with _BACKFILL_LOCK:
        conn = _history_conn()
        try:
            if not force and _meta_get(conn, "backfill_done") == BACKFILL_VERSION:
                _BACKFILL_DONE = True
                return
            start = _chain_start_day()
            today = datetime.now(timezone.utc).date()
            day = start
            while day <= today:
                snap = compute_day_snapshot(day, live=(day == today))
                _upsert_snapshot(conn, day, snap)
                conn.commit()
                day += timedelta(days=1)
            _meta_set(conn, "backfill_done", BACKFILL_VERSION)
            conn.commit()
            _BACKFILL_DONE = True
        finally:
            conn.close()


def _ensure_backfill_async() -> None:
    global _BACKFILL_STARTED
    if _BACKFILL_DONE:
        return
    with _BACKFILL_LOCK:
        if _BACKFILL_STARTED:
            return
        _BACKFILL_STARTED = True

    def _run() -> None:
        try:
            _backfill_history()
        except Exception:
            pass

    threading.Thread(target=_run, daemon=True).start()


def refresh_today_snapshot() -> None:
    today = datetime.now(timezone.utc).date()
    snap = compute_day_snapshot(today, live=True)
    conn = _history_conn()
    try:
        _upsert_snapshot(conn, today, snap)
        conn.commit()
    finally:
        conn.close()


def _load_snapshots() -> list[sqlite3.Row]:
    conn = _history_conn()
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            "SELECT day, staked_validators, net_consensus_issuance, burnt_fees, "
            "estimated_total_supply FROM daily_snapshots ORDER BY day ASC"
        ).fetchall()
        return rows
    finally:
        conn.close()


def _chart_value(metric: str, value: float | int) -> str:
    if metric == "staked_validators":
        return str(int(value))
    return format(float(value), ".12f").rstrip("0").rstrip(".")


def _rows_to_chart(rows: list[sqlite3.Row], column: str, metric: str) -> list[dict]:
    today = datetime.now(timezone.utc).date().isoformat()
    chart: list[dict] = []
    for row in rows:
        day = row["day"]
        point = {
            "date": day,
            "date_to": day,
            "value": _chart_value(metric, row[column]),
        }
        if day == today:
            point["is_approximate"] = True
        chart.append(point)
    return chart


def build_charts_payload() -> dict:
    _ensure_backfill_async()
    rows = _load_snapshots()
    if not rows:
        live = build_payload()
        today = datetime.now(timezone.utc).date().isoformat()
        rows_data = [
            {
                "day": today,
                "staked_validators": live["staked_validators"],
                "net_consensus_issuance": live["net_consensus_issuance_cnet"],
                "burnt_fees": live["burnt_fees_cnet"],
                "estimated_total_supply": live["estimated_total_supply_cnet"],
            }
        ]
    else:
        rows_data = [dict(r) for r in rows]

    def chart_for(key: str, metric: str, title: str, description: str) -> dict:
        chart_rows = [
            {
                "day": r["day"],
                "staked_validators": r["staked_validators"],
                "net_consensus_issuance": r["net_consensus_issuance"],
                "burnt_fees": r["burnt_fees"],
                "estimated_total_supply": r["estimated_total_supply"],
            }
            for r in rows_data
        ]
        col_map = {
            "staked_validators": "staked_validators",
            "net_consensus_issuance": "net_consensus_issuance",
            "burnt_fees": "burnt_fees",
            "estimated_total_supply": "estimated_total_supply",
        }
        col = col_map[key]
        today = datetime.now(timezone.utc).date().isoformat()
        chart = []
        for row in chart_rows:
            point = {
                "date": row["day"],
                "date_to": row["day"],
                "value": _chart_value(metric, row[col]),
            }
            if row["day"] == today:
                point["is_approximate"] = True
            chart.append(point)
        return {
            "chart": chart,
            "info": {
                "id": key,
                "title": title,
                "description": description,
                "units": "CoNET" if metric != "staked_validators" else None,
                "resolutions": ["DAY"],
            },
        }

    return {
        "staked_validators": chart_for(
            "staked_validators",
            "staked_validators",
            "Total staked validators",
            "Active validators on the beacon chain over time",
        ),
        "net_consensus_issuance": chart_for(
            "net_consensus_issuance",
            "net_consensus_issuance",
            "Net issuance since genesis",
            "Total CNET minted since genesis (CL rewards + EL block rewards; balance audit)",
        ),
        "burnt_fees": chart_for(
            "burnt_fees",
            "burnt_fees",
            "Burned",
            "Cumulative base fee burned on execution layer",
        ),
        "estimated_total_supply": chart_for(
            "estimated_total_supply",
            "estimated_total_supply",
            "Estimated total supply",
            "Sum of indexed EL balances plus CL rewards still on beacon chain",
        ),
        "backfill_complete": _BACKFILL_DONE,
    }


def _format_signed(value: float) -> str:
    text = f"{value:+,.4f}".rstrip("0").rstrip(".")
    if text in ("+", "-"):
        return "+0"
    return text


def _format_amount(value: float) -> str:
    return f"{value:,.4f}".rstrip("0").rstrip(".")


def build_payload() -> dict:
    active = get_active_validators()
    supply = compute_supply_metrics()
    return {
        "staked_validators": active,
        "active_validators": active,
        "staked_validators_formatted": f"{active:,}",
        **{k: round(v, 6) for k, v in supply.items()},
        "net_consensus_issuance_formatted": _format_signed(supply["net_consensus_issuance_cnet"]),
        "burnt_fees_formatted": _format_amount(supply["burnt_fees_cnet"]),
        "estimated_total_supply_formatted": _format_amount(supply["estimated_total_supply_cnet"]),
        "consensus_issuance_formatted": _format_signed(supply["consensus_issuance_cnet"]),
        "supply_increase_cnet": round(supply["net_consensus_issuance_cnet"], 6),
        "supply_increase_formatted": _format_signed(supply["net_consensus_issuance_cnet"]),
        "excluded_principal_sweep_cnet": 0.0,
        "excluded_principal_sweep_formatted": "+0",
        "cumulative_withdrawals_formatted": _format_signed(supply["cumulative_withdrawals_cnet"]),
    }


def main() -> None:
    from http.server import BaseHTTPRequestHandler, HTTPServer

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            path = self.path.split("?", 1)[0]
            if path == "/api/conet/homepage-metrics/charts":
                body = json.dumps(build_charts_payload()).encode()
            elif path in ("/", "/metrics", "/api/conet/homepage-metrics"):
                body = json.dumps(build_payload()).encode()
            else:
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "public, max-age=60")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *args):  # noqa: A003
            return

    _ensure_backfill_async()

    def _refresh_loop() -> None:
        while True:
            try:
                refresh_today_snapshot()
            except Exception:
                pass
            time.sleep(int(os.environ.get("CONET_METRICS_REFRESH_SEC", "3600")))

    threading.Thread(target=_refresh_loop, daemon=True).start()

    host = os.environ.get("CONET_METRICS_HOST", "127.0.0.1")
    port = int(os.environ.get("CONET_METRICS_PORT", "4084"))
    HTTPServer((host, port), Handler).serve_forever()


if __name__ == "__main__":
    main()
