# SENTRY — Gold Regime & No-Trade Engine (MT5)

SENTRY is a MetaTrader 5 indicator for XAUUSD. It does not give buy/sell signals.
It answers one question: **is gold tradeable right now, what kind of strategy fits, and if not, when should I come back?**

Structure tools tell you **where**. Signal tools tell you **when**. SENTRY tells you **whether**.

> Status: **Stage 1 (engine)**. Buffers 0-7 are filled. There are no visuals, objects or panel yet.

---

## Install (development)

1. Put this repository under `MQL5\Indicators\SENTRY\` so the indicator is `MQL5\Indicators\SENTRY\SENTRY.mq5`.
2. Compile `SENTRY.mq5` in MetaEditor. Includes are relative (`Include\Sentry\*.mqh`), so no files are needed in `MQL5\Include`.
3. Attach SENTRY to an XAUUSD chart (the defaults assume M15).

---

## Indexing and non-repainting

- **All arrays are non-series**: index `0` is the oldest bar and `rates_total-1` is the forming bar. This holds for the `OnCalculate` inputs, every indicator buffer and every internal array (H1 cache, news cache).
- Only closed bars (`index <= rates_total-2`) are computed. Each closed bar is computed **once**, in order, and never rewritten. The forming bar holds `EMPTY_VALUE` in every buffer.
- A full recompute happens only when the terminal reloads history (`prev_calculated == 0`) or the first bar of the chart changes.
- Warm-up bars (not enough history for any metric, including the H1 bias) hold `EMPTY_VALUE` in every public buffer. With the defaults the first valid bar is index 513, because ATR percentile needs 500 ATR(14) values.
- Higher timeframe: a chart bar closing at time T uses only the last H1 bar whose close time is at or before T. A chart bar is not computed until the terminal has a newer H1 bar, so the H1 bar it reads is final.
- Spread for a bar is that bar's own `MqlRates.spread` value (the `spread[]` array of `OnCalculate`), never the live symbol spread.

---

## Buffers (readable via `iCustom`)

| # | Name | Values |
|---|---|---|
| 0 | Regime | 0 RANGE, 1 TREND_UP, 2 TREND_DOWN, 3 CHOP, 4 SPIKE (published, after anti-flicker) |
| 1 | Score | 0-100 (integer) |
| 2 | State | 0 STAND_ASIDE, 1 CAUTION, 2 GO |
| 3 | StrategyHint | 0 none, 1 continuation, 2 mean reversion |
| 4 | VetoMask | bit0 news (1), bit1 spread (2), bit2 spike (4), bit3 chop (8) |
| 5 | ER | Efficiency Ratio, 0-1 |
| 6 | CHOP | Choppiness Index, 0-100 |
| 7 | ATRpct | ATR percentile, 0-100 |

Buffers 8-10 are `INDICATOR_CALCULATIONS` (internal state, not part of the public contract): 8 ATR(14), 9 EMA(50), 10 raw (unfiltered) regime.
Drawing buffers for later stages will come after these and will be documented separately.

`EMPTY_VALUE` (`DBL_MAX`) means "no value": the forming bar, or a warm-up bar.

Example:

```mql5
int h = iCustom(_Symbol, PERIOD_M15, "SENTRY\\SENTRY");
double state[];
if(CopyBuffer(h, 2, 1, 1, state) == 1 && state[0] != EMPTY_VALUE)
   Print("Last closed bar state: ", (int)state[0]);
```

---

## Rules (one sentence each, one function each)

### Metrics — `Include/Sentry/Metrics.mqh`
- **True range** (`Metrics_TrueRange`): max(High, previous Close) minus min(Low, previous Close).
- **ATR** (`Metrics_ATR`): the simple average of the last 14 true ranges (same as MT5 `iATR`).
- **EMA** (`Metrics_EMA`): exponential average of Close with alpha = 2/(50+1), seeded with the simple average of the first 50 closes.
- **ER** (`Metrics_ER`): |Close[i] − Close[i−20]| divided by the sum of the 20 absolute close-to-close changes, and 0 when that sum is 0.
- **CHOP** (`Metrics_CHOP`): 100 × log10(sum of the last 14 true ranges ÷ (highest High − lowest Low of those 14 bars)) ÷ log10(14).
- **ATRpct** (`Metrics_ATRPercentile`): the percentage of the previous 499 ATR(14) values that are strictly below the current ATR(14). The window is 500 bars, including the current one.
- **Slope** (`Metrics_Slope`): (EMA50[i] − EMA50[i−5]) ÷ ATR(14)[i], valid only once the EMA is 100 bars past its seed.
- **BarRangeX** (`Metrics_BarRangeX`): (High − Low) ÷ ATR(14) of the same bar.
- **H1 bias** (`Metrics_H1Bias`): ER(20) and Slope computed on H1 bars, read from the last H1 bar whose close time is at or before the chart bar's close time.

### Regime — `Include/Sentry/Regime.mqh`
- **Raw regime** (`Regime_Classify`): SPIKE if ATRpct > 95 or BarRangeX > 2.5, else CHOP if CHOP > 61.8 and ER < 0.25, else TREND_UP / TREND_DOWN (by the sign of Slope) if ER > 0.35 and |Slope| > 0.15, else RANGE.
- **Anti-flicker** (`Regime_Publish`): the published regime changes only after the new raw regime holds for 2 consecutive closed bars. SPIKE is published immediately, and the first valid bar after warm-up publishes its raw regime.

### Sessions — `Include/Sentry/Sessions.mqh`
- **Session** (`Sessions_IsActive`): a bar is in session when its open time falls in the London or the New York window.
- **Server offset, AUTO** (`Sessions_ServerOffsetSeconds`): the server is GMT+3 when the bar's server time falls in US DST, and GMT+2 otherwise. This is evaluated separately for every bar.
- **US DST** (`Sessions_IsUSDST`): from the second Sunday of March at 07:00 UTC to the first Sunday of November at 06:00 UTC.
- **UK DST** (`Sessions_IsUKDST`): from the last Sunday of March at 01:00 UTC to the last Sunday of October at 01:00 UTC.
- **London, AUTO** (`Sessions_InLondon`): the bar's open time, converted to Europe/London local time with UK DST, is within [08:00, 17:00).
- **New York, AUTO** (`Sessions_InNewYork`): the bar's open time, converted to America/New_York local time with US DST, is within [08:00, 17:00).
- **MANUAL mode**: the server offset is the fixed `InpServerGMTOffset`, and the windows are London [07:00, 16:00) and New York [12:00, 21:00) GMT (the pre-DST behaviour).
- **Live offset check** (`Sessions_CheckLiveOffset`): in AUTO mode on live bars, SENTRY compares the AUTO offset with `TimeTradeServer() − TimeGMT()`. If they differ by more than 15 minutes, it logs a warning once.

### News — `Include/Sentry/News.mqh`
- **Events** (`News_Load`): USD events of high importance with an exact release time (`CALENDAR_TIMEMODE_DATETIME`), from `CalendarValueHistory`, cached and refreshed at most once per hour.
- **Event near a bar** (`News_EventWithin`): an event falls within [bar open − N minutes, bar close + N minutes].
- **Strategy Tester**: the news veto and the news factor are disabled, and this is logged once.
- **Startup wait** (`OnInit` / `OnTimer` in `SENTRY.mq5`, `News_Probe`): if the calendar is not ready when SENTRY starts, the full-history calculation waits. SENTRY checks the calendar every 2 seconds for up to 30 seconds, then calculates once.
- **No calendar after the wait**: SENTRY computes the history without news and prints one warning that news vetoes are missing from past bars.
- **Live bars** are always computed once and never rescored. They start using news as soon as an hourly retry loads the calendar.

### Score — `Include/Sentry/Score.mqh`
Every factor is binary: it is either met or not met.

| Factor | Weight | Met when (function) |
|---|---|---|
| Regime clarity | 35 | the published regime is TREND_UP or TREND_DOWN, or it is RANGE with ER ≤ 0.25 (a clean, quiet range), and this bar's raw regime is the same. A RANGE with ER > 0.25 is a transition and scores 0 (`Score_RegimeClear`) |
| Volatility healthy | 20 | 30 ≤ ATRpct ≤ 85 (`Score_VolatilityHealthy`) |
| Session | 15 | the bar is in the London or New York session (`Sessions_IsActive`) |
| H1 alignment | 15 | TREND_UP with H1 trending up, TREND_DOWN with H1 trending down, or RANGE with H1 not trending, where "H1 trending" means H1 ER > 0.35 and \|H1 Slope\| > 0.15 (`Score_H1Aligned`) |
| Spread | 10 | the bar's spread × Point ≤ 0.50 in price units (`Score_SpreadOk`) |
| Distance from news | 5 | no USD high-impact event within ±60 min of the bar (`News_EventWithin`) |

- **Score** (`Score_Weighted`): round(100 × sum of met weights ÷ sum of evaluated weights). When news is unavailable, the news weight is left out of both sums.
- **Vetoes** (`Score_VetoMask`): news within ±15 min of the bar, spread above max, published SPIKE, or published CHOP.
- **Veto cap** (`Score_ApplyVetoCap`): when any veto is active, the score is capped at 25.
- **State** (`Score_State`): GO if score ≥ 70, CAUTION if score ≥ 40, otherwise STAND_ASIDE.
- **Strategy hint** (`Score_StrategyHint`): none when State is STAND_ASIDE. Otherwise TREND_UP / TREND_DOWN → continuation, RANGE → mean reversion, and anything else → none. The Regime buffer still shows the regime.

---

## Inputs

| Group | Input | Default | Meaning |
|---|---|---|---|
| Metrics | `InpERPeriod` | 20 | Efficiency Ratio period (chart and H1) |
| | `InpChopPeriod` | 14 | Choppiness Index period |
| | `InpATRPeriod` | 14 | ATR period (chart and H1) |
| | `InpATRPctLookback` | 500 | ATR percentile window, current bar included |
| | `InpEMAPeriod` | 50 | EMA period used by Slope (chart and H1) |
| | `InpSlopeLag` | 5 | Slope lag in bars |
| Regime | `InpSpikeATRPct` | 95.0 | SPIKE when ATRpct is above this |
| | `InpSpikeBarRangeX` | 2.5 | SPIKE when BarRangeX is above this |
| | `InpChopIndexMin` | 61.8 | CHOP needs a Choppiness Index above this |
| | `InpChopERMax` | 0.25 | CHOP needs ER below this |
| | `InpTrendERMin` | 0.35 | TREND needs ER above this (also used for H1 trending) |
| | `InpTrendSlopeMin` | 0.15 | TREND needs \|Slope\| above this (also used for H1 trending) |
| | `InpAntiFlickerBars` | 2 | closed bars a new raw regime must hold before it is published |
| Score | `InpWeightRegime` | 35 | weight: regime clarity |
| | `InpWeightVolatility` | 20 | weight: healthy volatility |
| | `InpWeightSession` | 15 | weight: London / New York |
| | `InpWeightH1` | 15 | weight: H1 alignment |
| | `InpWeightSpread` | 10 | weight: spread ≤ max |
| | `InpWeightNews` | 5 | weight: distance from news |
| | `InpRangeClarityERMax` | 0.25 | RANGE earns regime clarity only when ER ≤ this |
| | `InpVolHealthyMin` | 30.0 | healthy ATRpct lower bound (inclusive) |
| | `InpVolHealthyMax` | 85.0 | healthy ATRpct upper bound (inclusive) |
| | `InpVetoScoreCap` | 25 | score cap when any veto is active |
| | `InpGoScore` | 70 | GO when score ≥ this |
| | `InpCautionScore` | 40 | CAUTION when score ≥ this |
| Spread | `InpMaxSpreadPrice` | 0.50 | max spread in price units (USD per oz on XAUUSD) |
| Sessions | `InpSessionTimeMode` | AUTO | AUTO: server GMT+2 / GMT+3 with US DST, and local exchange hours. MANUAL: fixed offset and GMT hours |
| | `InpLondonStartLocal` / `InpLondonEndLocal` | 8 / 17 | AUTO: London window, Europe/London local hours, end exclusive |
| | `InpNewYorkStartLocal` / `InpNewYorkEndLocal` | 8 / 17 | AUTO: New York window, America/New_York local hours, end exclusive |
| | `InpServerGMTOffset` | 2 | MANUAL: broker server GMT offset in hours (fixed) |
| | `InpLondonStartGMT` / `InpLondonEndGMT` | 7 / 16 | MANUAL: London window, GMT hours, end exclusive |
| | `InpNewYorkStartGMT` / `InpNewYorkEndGMT` | 12 / 21 | MANUAL: New York window, GMT hours, end exclusive |
| News | `InpUseNews` | true | use the economic calendar |
| | `InpNewsVetoMinutes` | 15 | veto window around an event (± minutes) |
| | `InpNewsDistanceMinutes` | 60 | "distance from news" factor window (± minutes) |
| | `InpPostNewsBufferMin` | 15 | "come back at" = event + this (used from the come-back stage) |

Invalid inputs (for example periods < 1, inverted ranges, or hours outside 0-23) make `OnInit` return `INIT_PARAMETERS_INCORRECT` and print the reason.

Engine constants that are not trading thresholds are in `Config.mqh`:
- EMA settle bars: 100.
- H1 warm-up: 21 days of H1 before the first chart bar.
- Calendar refresh interval: 1 hour.
- Startup calendar probe: every 2 s, for up to 30 s.
- AUTO offsets: +2 in winter, +3 during US DST.
- Live offset check tolerance: 15 min.

---

## Known limitations (Stage 1)

- **AUTO assumes a New York-close broker** (GMT+2 in winter, GMT+3 during US DST). Brokers on another convention should use MANUAL. The live offset check logs once when the assumption looks wrong.
- **MANUAL uses a fixed offset.** With a broker that changes offset for DST, session windows are one hour off for part of the year.
- **Missing news is permanent for those bars.** If the calendar is still unavailable after the 30 s startup wait, those history bars are scored without news and a warning is printed. They are not rescored later, so a fresh instance may give a different result for those bars.
- **Recursive EMA depends on the history start.** The EMA settles over 100+ bars, so values are identical for identical history but can differ by rounding noise when the history start differs.
