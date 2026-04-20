#!/usr/bin/env python3
"""Mac MT5 validator for Phase 10 top-20 — runs on 2025-2026 recent regime.

Non-overlapping with Windows (2020-2026 full history) so results are
independent signals. Uses Wine prefixes mt5_prefix_1..8.

workers=1 per prefix (memory rule: workers>1 corrupts MT5 grids). Runs
serially across prefixes via 'open' + shell command file. Launches
COMPLEMENTARY window to Win to avoid same-data redundancy.
"""
import csv
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

import pandas as pd

WINE = Path("/Applications/MetaTrader 5.app/Contents/SharedSupport/wine/bin/wine64")
HOME = Path.home()
RESULTS = HOME / "GoldBigBrain" / "results"
OUT_DIR = RESULTS / "phase10_mac_mt5"
OUT_DIR.mkdir(parents=True, exist_ok=True)

STRATEGY_TO_MODE = {
    "atr_bracket": 0, "asian_range": 1,
    "momentum_long": 2, "momentum_short": 3,
    "fade_long": 4, "fade_short": 5,
    "ema_cross_long": 6, "ema_cross_short": 7,
    "breakout_range": 8, "vol_spike_bracket": 9,
    "null_bracket": 10,
}

FROM_DATE = "2025.01.01"
TO_DATE = "2026.04.10"
N_PREFIXES = 8


def fmt(v):
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, float):
        s = f"{v:.10f}".rstrip("0")
        return s + "0" if s.endswith(".") else s
    return str(v)


def prefix_path(worker_id):
    return HOME / f"mt5_prefix_{worker_id}"


def build_params(row):
    vt = float(row["vt"]); sl = float(row["sl"]); tp = float(row["tp"])
    hold = int(row["hold"]); be = float(row["be"]); trail = float(row["trail"])
    ss = int(row["session_start"]); se = int(row["session_end"])
    mode = STRATEGY_TO_MODE[row["strategy"]]
    return {
        "EntryMode": mode, "RiskPercent": 0.8,
        "SL_ATR_Mult": sl, "TP_ATR_Mult": tp,
        "BracketOffset": 0.3, "BracketBars": 3,
        "MaxTradesPerDay": 20, "DailyLossCapPct": 5.0,
        "SessionStart": ss, "SessionEnd": se,
        "MagicNumber": 20260420, "MaxLotSize": 0.10,
        "EnableBreakEven": be > 0, "BE_ATR_Mult": be,
        "EnableTrailing": trail > 0, "Trail_ATR_Mult": trail,
        "EnableTimeStop": True, "MaxHoldBars": hold,
        "VolThreshold": vt,
        "AsianStart": 0, "AsianEnd": 7,
        "BreakoutBars": 20, "VolSpikeThresh": 2.0,
        "FadeLongRSI": 35.0, "FadeShortRSI": 65.0,
    }


def run_config(job):
    idx, row = job
    worker_id = (idx % N_PREFIXES) + 1
    prefix = prefix_path(worker_id)
    mt5_dir = prefix / "drive_c/Program Files/MetaTrader 5"
    logs = mt5_dir / "Tester" / "logs"
    logs.mkdir(parents=True, exist_ok=True)

    label = f"cfg{row['_rank']:02d}_{row['strategy']}"[:40]
    ts = int(time.time() * 1000) + idx
    ini_name = f"p10v_w{worker_id}_{ts}.ini"
    ini_path = mt5_dir / ini_name

    params = build_params(row)
    lines = [
        "[Tester]", "Expert=GoldBigBrain\\GBB_Generic", "Symbol=XAUUSD", "Period=M5",
        "Model=8", "Optimization=0",
        f"FromDate={FROM_DATE}", f"ToDate={TO_DATE}",
        "ForwardMode=0", "Deposit=1000", "Currency=USD", "Leverage=500",
        "ExecutionMode=0", "Visual=0", "ShutdownTerminal=1", "ReplaceReport=1",
        f"Report={label}_{ts}.htm",
        "", "[TesterInputs]",
    ]
    for k, v in params.items():
        fv = fmt(v)
        lines.append(f"{k}={fv}||{fv}||0||{fv}||N")
    ini_path.write_text("\n".join(lines) + "\n")

    datestamp = datetime.now().strftime("%Y%m%d")
    today_log = logs / f"{datestamp}.log"
    pre_size = today_log.stat().st_size if today_log.exists() else 0

    done_flag = Path(f"/tmp/p10m_done_w{worker_id}_{ts}")
    done_flag.unlink(missing_ok=True)
    cmd_path = Path(f"/tmp/p10m_cmd_w{worker_id}_{ts}.command")
    ini_wine = f"C:\\Program Files\\MetaTrader 5\\{ini_name}"
    cmd_path.write_text(
        '#!/bin/bash\n'
        f'export WINEPREFIX="{prefix}"\n'
        f'"{WINE}" "C:\\Program Files\\MetaTrader 5\\terminal64.exe" '
        f'"/config:{ini_wine}" > /dev/null 2>&1\n'
        f'touch {done_flag}\n'
        f'rm -f "{cmd_path}"\n'
    )
    cmd_path.chmod(0o755)

    t0 = time.time()
    subprocess.run(["open", str(cmd_path)], capture_output=True)
    deadline = t0 + 1800
    while time.time() < deadline:
        if done_flag.exists():
            done_flag.unlink()
            break
        time.sleep(0.5)
    else:
        subprocess.run(["pkill", "-f", f"mt5_prefix_{worker_id}.*terminal64"],
                       capture_output=True)
        cmd_path.unlink(missing_ok=True)
        return {"label": label, "error": "timeout"}

    elapsed = round(time.time() - t0, 1)
    time.sleep(0.3)
    ini_path.unlink(missing_ok=True)

    result = {"label": label, "strategy": row["strategy"],
              "vt": row["vt"], "sl": row["sl"], "tp": row["tp"],
              "session_start": row["session_start"], "session_end": row["session_end"],
              "hold": row["hold"], "be": row["be"], "trail": row["trail"],
              "sim_median_pf": row.get("median_pf", ""),
              "sim_trades_per_month": row.get("trades_per_month", ""),
              "wall_time_s": elapsed, "worker": worker_id}

    if not today_log.exists():
        result["error"] = "no log"
        return result
    post_size = today_log.stat().st_size
    if post_size <= pre_size:
        result["error"] = "log unchanged"
        return result

    with open(today_log, "rb") as f:
        f.seek(max(pre_size - 500, 0))
        raw = f.read()
    text = raw.decode("utf-16-le", errors="replace").replace("\x00", "")

    for line in reversed(text.splitlines()):
        m = re.search(r"final balance\s+([\d.]+)\s+USD", line, re.IGNORECASE)
        if m:
            result["final_balance"] = float(m.group(1))
            result["pnl"] = round(result["final_balance"] - 1000.0, 2)
            break

    buys, sells = {}, {}
    for line in text.splitlines():
        dm = re.search(r"deal #(\d+)\s+(buy|sell)\s+([\d.]+)\s+XAUUSD\s+at\s+([\d.]+)",
                       line, re.IGNORECASE)
        if dm:
            oid = int(dm.group(1))
            price = float(dm.group(4))
            lots = float(dm.group(3))
            if dm.group(2).lower() == "buy": buys[oid] = (price, lots)
            else: sells[oid] = (price, lots)

    ids = sorted(set(list(buys) + list(sells)))
    wins = losses = 0; gp = gl = 0.0
    for i in range(0, len(ids) - 1, 2):
        o, c = ids[i], ids[i + 1]
        if o in buys and c in sells:
            pnl = (sells[c][0] - buys[o][0]) * buys[o][1] * 100
        elif o in sells and c in buys:
            pnl = (sells[o][0] - buys[c][0]) * sells[o][1] * 100
        else: continue
        if pnl > 0: wins += 1; gp += pnl
        else: losses += 1; gl += abs(pnl)
    total = wins + losses
    result["trades"] = total
    result["wr"] = round(wins / total, 4) if total else 0
    result["pf"] = round(gp / gl, 4) if gl > 0 else 0
    return result


def main():
    csv_in = Path(sys.argv[1] if len(sys.argv) > 1
                  else HOME / "GoldBigBrain/results/phase10_top20_for_mt5.csv")
    df = pd.read_csv(csv_in).reset_index(drop=True)
    df["_rank"] = df.index + 1
    jobs = list(enumerate(df.to_dict(orient="records")))
    out = OUT_DIR / f"phase10_mac_{datetime.now():%Y%m%d_%H%M%S}.csv"
    print(f"Mac validating {len(jobs)} configs on {N_PREFIXES} Wine prefixes ({FROM_DATE}-{TO_DATE}) -> {out}", flush=True)

    with ThreadPoolExecutor(max_workers=N_PREFIXES) as pool:
        results = list(pool.map(run_config, jobs))

    fields = ["label","strategy","vt","sl","tp","session_start","session_end","hold","be","trail",
              "sim_median_pf","sim_trades_per_month","worker","wall_time_s",
              "final_balance","pnl","trades","wr","pf","error"]
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for r in results: w.writerow({k: r.get(k, "") for k in fields})

    results_sorted = sorted(results, key=lambda r: r.get("pf") or 0, reverse=True)
    print("\n=== MAC MT5 RESULTS (2025-2026 regime, sorted by PF) ===", flush=True)
    for r in results_sorted:
        print(f"  {r.get('strategy','?'):20s} vt={r.get('vt')} sl={r.get('sl')} tp={r.get('tp')} | "
              f"t={r.get('trades',0)} PF={r.get('pf',0):.2f} pnl=${r.get('pnl',0):+.0f} | "
              f"{r.get('wall_time_s',0):.0f}s {r.get('error','')}", flush=True)
    print(f"\nDONE -> {out}", flush=True)


if __name__ == "__main__":
    main()
