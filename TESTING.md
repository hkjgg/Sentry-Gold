# SENTRY — Testing

## Stage 1 — Buffer check (`Tests/SENTRY_BufferCheck.mq5`)

This test EA loads SENTRY through `iCustom`, waits for it with `OnTimer` (no `Sleep`), prints buffers 0-7 for the last 20 closed bars (oldest first), then removes itself.

**Setup**
1. Compile `SENTRY.mq5` (repo at `MQL5\Indicators\SENTRY\`).
2. Copy `Tests\SENTRY_BufferCheck.mq5` to `MQL5\Experts\` and compile it.
3. Open an XAUUSD chart and let M15 and H1 history load.

**Run**
Drag the EA onto any chart. AutoTrading does not need to be enabled, because the EA does not trade. The inputs are:

| Input | Default | Notes |
|---|---|---|
| `InpSymbol` | `XAUUSD` | Use your broker's exact name (for example `XAUUSD.m`). Leave it empty to use the chart symbol. |
| `InpTimeframe` | M15 | |
| `InpIndicatorPath` | `SENTRY\SENTRY` | Path relative to `MQL5\Indicators\`, without the extension. |
| `InpBarsToPrint` | 20 | |
| `InpWaitSeconds` | 60 | Maximum wait for the first calculation. |

**Read the output (Experts tab)**. The rows below only show the format; they are not real data.

```
Time              Regime       Score State        Hint            Veto          ER     CHOP   ATRpct
2026.09.24 14:00  TREND_UP        85 GO           continuation    0          0.412    38.20     64.3
2026.09.24 14:15  SPIKE           20 STAND_ASIDE  none            5:NK       0.380    35.10     97.1
```

Veto letters: N = news, S = spread, K = spike, C = chop. The number is the raw bitmask.

**Sanity checks**
- No row is `EMPTY` on a chart with 600 or more bars of history. Rows are only `EMPTY` during warm-up, if the newest H1 bar is not final yet, or if the bar is older than the last `InpMaxBars` closed bars.
- Score is between 0 and 100. When Veto ≠ 0, Score ≤ 25.
- State matches Score: ≥ 70 GO, 40-69 CAUTION, < 40 STAND_ASIDE.
- Hint is `none` on every STAND_ASIDE row. Otherwise TREND → continuation, RANGE → mean_reversion, CHOP/SPIKE → none.
- A RANGE row with ER > 0.25 cannot reach GO with the default weights, because it gets no regime-clarity points: the most it can score is 65.
- Session (AUTO mode): London runs 08:00-17:00 London time and New York runs 08:00-17:00 New York time, in both summer and winter. For a GMT+2/+3 broker in summer, London is 10:00-19:00 server time and New York is 15:00-00:00 server time.
- ER is between 0 and 1, CHOP between 0 and 100, and ATRpct between 0 and 100.
- A regime other than SPIKE never appears for only a single bar between two different regimes (anti-flicker).
- Around a USD high-impact release (CPI, NFP, FOMC), bars within ±15 min show the N veto (live terminal only, not the tester).

**Startup messages (live terminal)**
- If the calendar is slow to load, the first calculation can take up to 30 s to appear.
- `SENTRY WARNING: economic calendar not available ...` is printed once if the history was computed without news.
- `SENTRY: server GMT offset mismatch ...` is printed once in AUTO mode if the live server offset differs from the GMT+2 / GMT+3 rule. In that case, use MANUAL mode.

## Stage 1 — Performance

After the full calculation, the indicator prints one line to the Experts log:

```
SENTRY: full calculation XAUUSD PERIOD_M15: 5000 bars (+499 warm-up). metrics x ms | ATRpct x ms | H1 x ms | news x ms | regime/score x ms | total x ms (budget 200 ms).
```

- **H1** includes the single H1 `CopyRates` call and the H1 metrics. **news** includes the calendar load.
- The terminal message "indicator is too slow" must not appear.
- When the indicator is removed, it prints the number of incremental updates and the slowest one. The budget is 5 ms per new bar.
- If H1 history is missing, the log shows `SENTRY: H1 history of XAUUSD requested (error 4401) ...` once. The calculation then completes on its own, within a few seconds, without any tick.

| Date | Terminal build | Symbol / TF | Bars | metrics | ATRpct | H1 | news | regime/score | total (ms) | slowest incremental (ms) |
|---|---|---|---|---|---|---|---|---|---|---|
| _to be filled from a real MT5 run_ | | | | | | | | | | |

A C++ port of the five phases, run on synthetic data outside MT5, took about 2.3 ms for 5000 + 499 bars. It excludes the CopyRates call and the calendar load. This only shows the algorithmic cost; it does not replace the MT5 line above.

## Stage 3 — Non-repaint harness

`Tests/SENTRY_RepaintHarness.mq5` is a placeholder until Stage 3.
