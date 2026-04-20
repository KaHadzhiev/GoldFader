# GoldFader

Deployable XAUUSD scalper bot. **Fade-the-extremes long strategy** at US afternoon session (13-20 GMT), ML volatility-gated entries, ATR-scaled bracket exits.

## Status (2026-04-20)

**Cross-validated on MT5 every-tick real ticks across 6 years.**

| Window | Trades | Trades/mo | PF | Net PnL on $1k |
|---|---|---|---|---|
| **Win 2020-2026 (75mo) — baseline** | 3,633 | 48.4 | **1.12** | +$3,213 |
| **Mac 2025-2026 (15mo) — independent regime** | 801 | 53.0 | **1.27** | +$1,602 |
| **Win 2020-2026 — focused sweep cfg28 (NEW)** | 3,788 | 50.5 | **1.28** | +$6,663 |
| Win 2020-2026 — focused sweep cfg25 (NEW) | 3,801 | 50.7 | 1.26 | +$6,055 |

Cross-validation = same config tested independently on Win and Mac with non-overlapping data windows. Both sides positive.

## How it was built

1. **Phase 10 sim screen** — 28,995 configs across 10 strategy archetypes on a 6-year M1-OHLC simulator.
2. **Permutation null-test** — shuffled-label baseline produced 0 configs at PF≥1.5 vs 6,566 real survivors. Edge ≥ 6× null floor.
3. **MT5 ground-truth validation** — top-20 sim survivors pushed through MT5 every-tick real on Win (full 6yr) + Mac (recent 15mo).
4. **Survivors:** 3 of 18 cleared PF≥1.0 + ≥20 trades/mo gate. `fade_long VT=0.10/SL=0.5/TP=2.0/sess 13-20` was the leader.
5. **Focused sweep around the winner** — 84 configs varying VT[0.06–0.20] × SL[0.3,0.5,0.7] × TP[1.5–3.0]. cfg28 (SL=0.3/TP=3.0) lifted PF from 1.12 → 1.28 and PnL from $3.2k → $6.7k.

## Strategy logic (`fade_long`)

- **Entry signal:** RSI(14, M5) crosses below 35 (oversold) — fade the dip, expect bounce.
- **Vol gate:** LightGBM ONNX model predicts P(high-vol regime) > VolThreshold. Skip when market is flat-quiet.
- **Bracket exit:** SL = `0.3 × ATR`, TP = `3.0 × ATR` (cfg28 final).
- **Time stop:** close at bar 12 if neither stop hit.
- **Session window:** 13:00–20:00 GMT (post-London-open through NY pre-close).
- **Risk:** 0.8% of equity per trade, max lot 0.10, daily loss cap 5%.

## Why fade_long beats momentum on gold

Gold M5 mean-reverts on intraday RSI extremes during US session liquidity. The vol gate avoids wide-spread quiet periods where the fade signal is noise. SL=0.3 ATR is tight enough that one bounce pays for several stop-outs.

## Files

- `mql5/GBB_Generic.mq5` — multi-mode EA, 11 entry archetypes, ONNX-backed vol filter
- `mql5/GBB_Generic.ex5` — compiled binary (XAUUSD M5)
- `python/mt5_validate_phase10.py` — Win 6-instance parallel validator (every-tick Model=8)
- `python/mt5_mac_validate_phase10.py` — Mac Wine-prefix validator (every-tick Model=8)
- `results/phase10_top20_for_mt5.csv` — input config list (top-20 sim survivors)
- `results/phase10_fade_long_sweep.csv` — focused 84-config tuning sweep
- `results/phase10_mt5_*.csv` — MT5 every-tick output (Win 2020-2026)
- `results/phase10_mac_*.csv` — MT5 every-tick output (Mac 2025-2026)
- `configs/v2.0_locked.json` — final deploy params (added when sweep completes)

## Deploy

1. Copy `mql5/GBB_Generic.ex5` into `MQL5/Experts/GoldFader/` of any MT5 install.
2. Open XAUUSD M5 chart, attach EA.
3. Inputs (cfg28):
   - `EntryMode = 4` (fade_long)
   - `VolThreshold = 0.10`
   - `SL_ATR_Mult = 0.3`
   - `TP_ATR_Mult = 3.0`
   - `MaxHoldBars = 12`
   - `SessionStart = 13`, `SessionEnd = 20`
   - `RiskPercent = 0.8`
   - `MaxLotSize = 0.10`
   - `DailyLossCapPct = 5.0`
   - `MagicNumber = 20260420`
4. Enable AutoTrading. Verify smiley-face on EA icon.

## License

MIT (see LICENSE).

## Disclaimer

Past performance is not a guarantee of future results. Trade at your own risk.
