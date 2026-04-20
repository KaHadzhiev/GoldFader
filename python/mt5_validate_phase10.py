#!/usr/bin/env python3
"""Windows MT5 validator for Phase 10 top-20 sim survivors.

Runs each config through MT5 (GBB_Generic EA, every-tick real model) on
the full 2020-2026 window. Uses 6 Win instances in parallel (workers=1
per instance per `feedback_workers3_race_corrupts`: the race is within a
single Python process; separate instances = separate logs = safe).

Each config -> (label, strategy, params) -> MT5 INI -> launch -> parse log.
"""
import csv
import ctypes
import ctypes.wintypes
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

import pandas as pd

INSTANCES = [Path(fr"C:\MT5-Instances\Instance{i}") for i in range(1, 7)]
RESULTS = Path(r"C:\Users\kahad\IdeaProjects\GoldBigBrain\results")
OUT_DIR = RESULTS / "phase10_mt5"
OUT_DIR.mkdir(parents=True, exist_ok=True)

STRATEGY_TO_MODE = {
    "atr_bracket": 0, "asian_range": 1,
    "momentum_long": 2, "momentum_short": 3,
    "fade_long": 4, "fade_short": 5,
    "ema_cross_long": 6, "ema_cross_short": 7,
    "breakout_range": 8, "vol_spike_bracket": 9,
    "null_bracket": 10,
}

SW_MINIMIZE = 6
FROM_DATE = "2020.01.01"
TO_DATE = "2026.04.10"


def fmt(v):
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, float):
        s = f"{v:.10f}".rstrip("0")
        return s + "0" if s.endswith(".") else s
    return str(v)


def minimize_by_pid(pid):
    user32 = ctypes.windll.user32
    @ctypes.WINFUNCTYPE(ctypes.wintypes.BOOL, ctypes.wintypes.HWND, ctypes.wintypes.LPARAM)
    def cb(hwnd, _):
        pid_out = ctypes.wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid_out))
        if pid_out.value == pid and user32.IsWindowVisible(hwnd):
            user32.ShowWindow(hwnd, SW_MINIMIZE)
        return True
    user32.EnumWindows(cb, 0)


def build_params(row):
    vt = float(row["vt"])
    sl = float(row["sl"])
    tp = float(row["tp"])
    hold = int(row["hold"])
    be = float(row["be"])
    trail = float(row["trail"])
    ss = int(row["session_start"])
    se = int(row["session_end"])
    mode = STRATEGY_TO_MODE[row["strategy"]]
    p = {
        "EntryMode": mode,
        "RiskPercent": 0.8,
        "SL_ATR_Mult": sl,
        "TP_ATR_Mult": tp,
        "BracketOffset": 0.3,
        "BracketBars": 3,
        "MaxTradesPerDay": 20,
        "DailyLossCapPct": 5.0,
        "SessionStart": ss,
        "SessionEnd": se,
        "MagicNumber": 20260420,
        "MaxLotSize": 0.10,
        "EnableBreakEven": be > 0,
        "BE_ATR_Mult": be,
        "EnableTrailing": trail > 0,
        "Trail_ATR_Mult": trail,
        "EnableTimeStop": True,
        "MaxHoldBars": hold,
        "VolThreshold": vt,
        "AsianStart": 0,
        "AsianEnd": 7,
        "BreakoutBars": 20,
        "VolSpikeThresh": 2.0,
        "FadeLongRSI": 35.0,
        "FadeShortRSI": 65.0,
    }
    return p


def run_config(job):
    idx, row_dict = job
    inst = INSTANCES[idx % len(INSTANCES)]
    label = f"cfg{row_dict['_rank']:02d}_{row_dict['strategy']}_vt{row_dict['vt']}_sl{row_dict['sl']}_tp{row_dict['tp']}"
    label = label.replace(".", "p")[:60]
    ts = int(time.time() * 1000) + idx
    report_name = f"p10_{label}_{ts}"
    ini = inst / f"{report_name}.ini"

    params = build_params(row_dict)

    lines = [
        "[Tester]", "Expert=GoldBigBrain\\GBB_Generic", "Symbol=XAUUSD", "Period=M5",
        "Optimization=0", "Model=8",
        f"FromDate={FROM_DATE}", f"ToDate={TO_DATE}",
        "ForwardMode=0", "Deposit=1000", "Currency=USD", "ProfitInPips=0",
        "Leverage=500", "ExecutionMode=0", "Visual=0", "ShutdownTerminal=1",
        f"Report={report_name}.htm", "ReplaceReport=1",
        "", "[TesterInputs]",
    ]
    for k, v in params.items():
        fv = fmt(v)
        lines.append(f"{k}={fv}||{fv}||0||{fv}||N")
    content = "\r\n".join(lines) + "\r\n"
    with open(ini, "wb") as f:
        f.write(b"\xff\xfe")
        f.write(content.encode("utf-16-le"))

    log_dir = inst / "Tester" / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    datestamp = datetime.now().strftime("%Y%m%d")
    today_log = log_dir / f"{datestamp}.log"
    pre_size = today_log.stat().st_size if today_log.exists() else 0

    terminal = inst / "terminal64.exe"

    si = subprocess.STARTUPINFO()
    si.dwFlags |= subprocess.STARTF_USESHOWWINDOW | 0x00000004
    si.wShowWindow = 7
    si.dwX = -32000
    si.dwY = -32000

    t0 = time.time()
    proc = subprocess.Popen(
        [str(terminal), f"/config:{ini}", "/portable"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        startupinfo=si,
        creationflags=0x08000000,
    )
    for _ in range(10):
        time.sleep(0.3)
        try: minimize_by_pid(proc.pid)
        except Exception: pass

    try:
        proc.wait(timeout=3600)
    except subprocess.TimeoutExpired:
        proc.kill()
        return {"label": label, "strategy": row_dict["strategy"], "error": "timeout"}
    elapsed = round(time.time() - t0, 1)
    time.sleep(1.0)
    try: os.unlink(ini)
    except OSError: pass

    result = {
        "label": label, "strategy": row_dict["strategy"],
        "vt": row_dict["vt"], "sl": row_dict["sl"], "tp": row_dict["tp"],
        "session_start": row_dict["session_start"], "session_end": row_dict["session_end"],
        "hold": row_dict["hold"], "be": row_dict["be"], "trail": row_dict["trail"],
        "sim_median_pf": row_dict.get("median_pf", ""),
        "sim_trades_per_month": row_dict.get("trades_per_month", ""),
        "time_s": elapsed, "instance": idx % len(INSTANCES) + 1,
    }

    if not today_log.exists():
        result["error"] = "no log"
        return result
    post_size = today_log.stat().st_size
    if post_size <= pre_size:
        result["error"] = "log unchanged"
        return result

    read_start = max(pre_size - 500, 0)
    with open(today_log, "rb") as f:
        f.seek(read_start)
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
            if dm.group(2).lower() == "buy":
                buys[oid] = (price, lots)
            else:
                sells[oid] = (price, lots)

    ids = sorted(set(list(buys) + list(sells)))
    wins = losses = 0
    gp = gl = 0.0
    for i in range(0, len(ids) - 1, 2):
        o, c = ids[i], ids[i + 1]
        if o in buys and c in sells:
            pnl = (sells[c][0] - buys[o][0]) * buys[o][1] * 100
        elif o in sells and c in buys:
            pnl = (sells[o][0] - buys[c][0]) * sells[o][1] * 100
        else:
            continue
        if pnl > 0:
            wins += 1; gp += pnl
        else:
            losses += 1; gl += abs(pnl)
    total = wins + losses
    result["trades"] = total
    result["wr"] = round(wins / total, 4) if total else 0
    result["pf"] = round(gp / gl, 4) if gl > 0 else 0
    return result


def main():
    csv_in = Path(sys.argv[1]) if len(sys.argv) > 1 else RESULTS / "phase10_top20_for_mt5.csv"
    df = pd.read_csv(csv_in)
    df = df.reset_index(drop=True)
    df["_rank"] = df.index + 1
    jobs = list(enumerate(df.to_dict(orient="records")))

    out = OUT_DIR / f"phase10_mt5_{datetime.now():%Y%m%d_%H%M%S}.csv"
    print(f"Validating {len(jobs)} configs on 6 Win instances -> {out}", flush=True)

    with ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(run_config, jobs))

    fields = ["label","strategy","vt","sl","tp","session_start","session_end","hold","be","trail",
              "sim_median_pf","sim_trades_per_month","instance","time_s",
              "final_balance","pnl","trades","wr","pf","error"]
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for r in results:
            w.writerow({k: r.get(k, "") for k in fields})

    results_sorted = sorted(results, key=lambda r: r.get("pf") or 0, reverse=True)
    print("\n=== MT5 VALIDATION RESULTS (sorted by MT5 PF) ===", flush=True)
    for r in results_sorted:
        simpf = r.get("sim_median_pf", "")
        simpf_str = f"{float(simpf):.2f}" if simpf not in ("", None) else "-"
        print(f"  {r.get('strategy','?'):20s} vt={r.get('vt')} sl={r.get('sl')} tp={r.get('tp')} "
              f"sess={r.get('session_start')}-{r.get('session_end')} hold={r.get('hold')} | "
              f"MT5 t={r.get('trades',0)} PF={r.get('pf',0):.2f} pnl=${r.get('pnl',0):+.0f} | "
              f"sim PF={simpf_str} | {r.get('time_s',0):.0f}s "
              f"{r.get('error','')}", flush=True)
    print(f"\nDONE -> {out}", flush=True)


if __name__ == "__main__":
    main()
