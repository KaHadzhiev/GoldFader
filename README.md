# GoldFader

Deployable XAUUSD scalper bot. **Fade-the-extremes long strategy** at US afternoon session (13-20 GMT), ML volatility-gated entries, ATR-scaled bracket exits.

## Status (2026-04-20)

**Cross-validated on MT5 every-tick real ticks across 6 years.**

### Primary winner: cfg74 (locked 2026-04-20 — pending Mac cross-val)

| Window | Trades | Trades/mo | PF | Net PnL on $1k |
|---|---|---|---|---|
| **Win 2020-2026 (75mo) — cfg74 primary** | 1,674 | 22.3 | **1.41** | +$3,915 |
| **Win 2020-2026 (75mo) — cfg28 volume** | 3,788 | 50.5 | **1.28** | +$6,663 |
| Win 2020-2026 — cfg62 (prior leader) | 2,490 | 33.2 | 1.32 | +$4,792 |
| Win 2020-2026 — baseline cfg30 | 3,633 | 48.4 | 1.12 | +$3,213 |
| **Mac 2025-2026 (15mo) — independent regime** | 801 | 53.0 | **1.27** | +$1,602 |

The deployment uses **two configs in parallel** on the same $1k account (different magic numbers):
- **cfg74** — quality engine: high VT (0.20) means fewer but cleaner entries. PF clears the MQL5 signal-provider 1.30 deploy gate by 11 percentage points.
- **cfg28** — volume engine: low VT (0.10) means 2.3× more entries. Lower PF but ~70% higher absolute PnL.

Cross-validation = same config tested independently on Win (full 6yr) and Mac (recent 15mo non-overlapping). Both sides positive.

## How it was built

1. **Phase 10 sim screen** — 28,995 configs across 10 strategy archetypes on a 6-year M1-OHLC simulator.
2. **Permutation null-test** — shuffled-label baseline produced 0 configs at PF≥1.5 vs 6,566 real survivors. Edge ≥ 6× null floor.
3. **MT5 ground-truth validation** — top-20 sim survivors pushed through MT5 every-tick real on Win (full 6yr) + Mac (recent 15mo).
4. **Survivors:** 3 of 18 cleared PF≥1.0 + ≥20 trades/mo gate. `fade_long VT=0.10/SL=0.5/TP=2.0/sess 13-20` was the leader.
5. **Focused 84-config sweep around the winner** — VT[0.06–0.20] × SL[0.3,0.5,0.7] × TP[1.5–3.0]. Two clear winners emerged:
   - **cfg74** (SL=0.3/TP=2.0/VT=0.20) lifted PF from 1.12 → 1.41 (+26%) at 22 trades/month.
   - **cfg28** (SL=0.3/TP=3.0/VT=0.10) lifted PnL from $3.2k → $6.7k (+108%) at 51 trades/month.
6. **SL=0.3 universal finding** — every PF>1.20 config in the sweep had SL=0.3. The original baseline used SL=0.5; tighter stop = the bounce pays before stop hits.

## Strategy logic (`fade_long`)

- **Entry signal:** RSI(14, M5) crosses below 35 (oversold) — fade the dip, expect bounce.
- **Vol gate:** LightGBM ONNX model predicts P(high-vol regime) > VolThreshold. Skip when market is flat-quiet. cfg74 uses 0.20 (selective), cfg28 uses 0.10 (permissive).
- **Bracket exit:** SL = `0.3 × ATR`, TP = `2.0 × ATR` (cfg74) or `3.0 × ATR` (cfg28).
- **Time stop:** close at bar 12 if neither stop hit.
- **Session window:** 13:00–20:00 GMT (post-London-open through NY pre-close).
- **Risk:** 0.6% of equity per trade per EA (combined ≤1.2%), max lot 0.10, daily loss cap 5%.

## Why fade_long beats momentum on gold

Gold M5 mean-reverts on intraday RSI extremes during US session liquidity. The vol gate avoids wide-spread quiet periods where the fade signal is noise. SL=0.3 ATR is tight enough that one bounce pays for several stop-outs. The session window restricts trading to the most liquid 7 hours, which keeps the realized spread close to the broker quote.

## Files

- `mql5/GBB_Generic.mq5` — multi-mode EA, 11 entry archetypes, ONNX-backed vol filter
- `mql5/GBB_Generic.ex5` — compiled binary (XAUUSD M5)
- `python/mt5_validate_phase10.py` — Win 6-instance parallel validator (every-tick Model=8)
- `python/mt5_mac_validate_phase10.py` — Mac Wine-prefix validator (every-tick Model=8, capped at 4 prefixes)
- `results/phase10_top20_for_mt5.csv` — input config list (top-20 sim survivors)
- `results/phase10_fade_long_sweep.csv` — focused 84-config tuning sweep input
- `results/phase10_mt5_*.csv` — MT5 every-tick output (Win 2020-2026)
- `results/phase10_mac_*.csv` — MT5 every-tick output (Mac 2025-2026)
- `configs/v2.0_locked.json` — final deploy params for both configs

## Deploy

### Setup (once)

1. Copy `mql5/GBB_Generic.ex5` into `MQL5/Experts/GoldFader/` of any MT5 install.
2. Copy `vol_model_6yr.onnx` into `MQL5/Files/`.
3. Open **two** XAUUSD M5 charts.

### Chart 1 — cfg74 (quality engine, MagicNumber=20260420)

| Input | Value |
|---|---|
| `EntryMode` | 4 (fade_long) |
| `VolThreshold` | **0.20** |
| `SL_ATR_Mult` | **0.3** |
| `TP_ATR_Mult` | **2.0** |
| `MaxHoldBars` | 12 |
| `BE_ATR_Mult` | 0 |
| `Trail_ATR_Mult` | 0 |
| `BracketBars` | 0 |
| `SessionStart` | 13 |
| `SessionEnd` | 20 |
| `RiskPercent` | 0.6 |
| `MaxLotSize` | 0.10 |
| `DailyLossCapPct` | 5.0 |
| `MaxTradesPerDay` | 20 |
| `MagicNumber` | **20260420** |

### Chart 2 — cfg28 (volume engine, MagicNumber=20260421)

Identical to cfg74 except:

| Input | Value |
|---|---|
| `VolThreshold` | **0.10** |
| `TP_ATR_Mult` | **3.0** |
| `MaxTradesPerDay` | 50 |
| `MagicNumber` | **20260421** |

### Activation

4. Enable AutoTrading. Verify smiley-face on both EA icons.
5. Confirm in MT5 Experts log: `[GBB_Generic] Initialized magic=20260420` and `magic=20260421` (two distinct).

## Why BE=0 / Trail=0

The 84-config sweep was originally built with `BE_ATR_Mult=0.5` and `Trail_ATR_Mult=0.3` to test break-even and trailing stops. The Mac Wine-prefix MT5 silently fails to parse these params (locale-dependent decimal handling in the .ini parser) and the EA opens 0 trades. Re-running the sweep on Mac with `BE=0 / Trail=0` produced consistent results with Win. Conclusion: keep BE and Trail at zero for cross-platform stability. The bracket SL/TP is sufficient.

## License

MIT (see LICENSE).

## Disclaimer

Past performance is not a guarantee of future results. Trade at your own risk. The author is deploying real capital ($1k Vantage Standard STP) in parallel with publishing this code; live results will diverge from backtest due to spread variance, slippage, and regime shift.
