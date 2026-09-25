# CLAUDE.md — SENTRY · Gold Regime & No-Trade Engine (MT5)

This file is the single source of truth for this project. Read it fully before every task.
If a request conflicts with this file, stop and ask.

---

## 1. What we are building

SENTRY is a MetaTrader 5 indicator for **XAUUSD only**, sold on the MQL5 Market.
It does NOT give buy/sell signals. It answers one question:

> **Is gold tradeable right now, what kind of strategy fits, and if not, when should I come back?**

Positioning (use this wording in docs and marketing):
- Structure tools tell you **where**. Signal tools tell you **when**. SENTRY tells you **whether**.
- "Works on top of any signal or SMC tool."
- Honest by design: no win-rate claims. The indicator proves its own value on the user's chart (Proof panel).

What makes it different from every product in the market:
1. **Ghost candles**: candles fade during no-trade periods.
2. **Come back at…**: when the verdict is STAND ASIDE, it says when conditions are expected to reopen (news end, next session) or says honestly that it is waiting for the regime to change.
3. **Session Tape**: a horizontal strip showing today's regimes by session, a "now" marker, and upcoming news pins.
4. **Proof panel**: statistics computed on the user's own history showing how breakouts behaved in GO vs STAND ASIDE.
5. Regime ribbon, tradeability score 0-100 with visible weights, strategy hint, vetoes.

---

## 2. Non-negotiable rules

- **Non-repainting.** The value for bar i depends only on data of bars <= i. Bar 0 (forming) never writes any buffer. A closed bar's values never change afterwards.
- **No lookahead on higher timeframes.** For a chart bar closing at time T, use only the last H1 bar whose close time <= T.
- **Future data is only allowed inside the Proof engine**, and only to score the outcome of past events, never to compute State.
- No DLLs. No web requests. No external files required to run.
- Compiles in MetaEditor with **zero errors and zero warnings**.
- Must not crash or spam errors on non-gold symbols, in the Strategy Tester, or when the economic calendar is unavailable.
- Performance: full history (5000 bars) < 200 ms, incremental update < 5 ms per new bar. Panel redraw throttled (max ~4 per second).
- All objects use a unique prefix + instance ID. Full cleanup in OnDeinit. Any chart property changed (e.g. hidden candles) is restored on removal.
- Every threshold is an input with a documented default.
- Every rule is defined in one sentence in README.md and implemented in one function.

---

## 3. Repository structure

```
SENTRY/
  CLAUDE.md
  README.md                 buffer map, input list, one-sentence rule definitions
  TESTING.md                how to run and read each test
  CHANGELOG.md
  SENTRY.mq5                main indicator
  Include/Sentry/
    Config.mqh              inputs, enums, constants, colors
    Metrics.mqh             ER, CHOP, ATR percentile, slope, bar range, H1 bias
    Regime.mqh              classification + anti-flicker
    Score.mqh               score, vetoes, state, strategy hint
    News.mqh                economic calendar (USD high impact)
    Sessions.mqh            session windows, next-window calculation
    ComeBack.mqh            "come back at" logic
    Proof.mqh               historical proof statistics
    Visuals.mqh             ghost candles, ribbon, score strip
    Panel.mqh               CCanvas panel (all layouts)
    Tape.mqh                session tape
    Alerts.mqh              popup / push / sound, one alert per event
  Tests/
    SENTRY_RepaintHarness.mq5   EA that verifies non-repainting
  Utilities/
    SENTRY_Guard.mq5            free companion utility
  Docs/
    Manual_EN.md
    Manual_AR.md
```

---

## 4. Engine definitions (defaults for XAUUSD M15)

### Metrics (per closed bar)
- **ER**: Kaufman Efficiency Ratio, period 20.
- **CHOP**: Choppiness Index, period 14.
- **ATRpct**: percentile rank of ATR(14) within the last 500 bars (0-100).
- **Slope**: (EMA50[i] - EMA50[i-5]) / ATR(14)[i].
- **BarRangeX**: (High - Low) / ATR(14) of the same bar.
- **H1 bias**: ER(20) and Slope on H1, using the no-lookahead rule.

### Regime (priority order)
1. **SPIKE**: ATRpct > 95 OR BarRangeX > 2.5
2. **CHOP**: CHOP > 61.8 AND ER < 0.25
3. **TREND_UP / TREND_DOWN**: ER > 0.35 AND |Slope| > 0.15
4. **RANGE**: everything else

**Anti-flicker**: the published regime changes only after the new raw regime holds for 2 consecutive closed bars. SPIKE applies immediately.

### Tradeability score (0-100)
| Factor | Weight |
|---|---|
| Regime clarity | 35 |
| Volatility in healthy zone (ATRpct 30-85) | 20 |
| Session (London / New York) | 15 |
| H1 alignment | 15 |
| Spread <= max | 10 |
| Distance from news | 5 |

**Vetoes** cap the score at 25: high-impact USD event within ±15 min, spread above max, SPIKE, CHOP.

**State**: GO >= 70 · CAUTION 40-69 · STAND_ASIDE < 40.

**Strategy hint**: TREND → continuation · RANGE → mean reversion · otherwise → none.

### Come back at (ComeBack.mqh)
- News veto → event time + post-news buffer (input, default 15 min).
- Off-session → next London or New York open.
- Spread veto → "when spread normalizes" (no time shown).
- SPIKE / CHOP → "watching for regime change" (no time shown). Never invent a time.
- If several apply, show the latest one.

### Buffers (INDICATOR_DATA, readable via iCustom)
| # | Name | Values |
|---|---|---|
| 0 | Regime | 0 RANGE, 1 TREND_UP, 2 TREND_DOWN, 3 CHOP, 4 SPIKE |
| 1 | Score | 0-100 |
| 2 | State | 0 STAND_ASIDE, 1 CAUTION, 2 GO |
| 3 | StrategyHint | 0 none, 1 continuation, 2 mean reversion |
| 4 | VetoMask | bit0 news, bit1 spread, bit2 spike, bit3 chop |
| 5 | ER | |
| 6 | CHOP | |
| 7 | ATRpct | |
Additional drawing buffers for visuals come after these and are documented separately.

---

## 5. Stages

Work one stage at a time. Do not start a stage until the previous one is accepted.
Each stage ends with: compiled code, updated README/TESTING/CHANGELOG, and a short report of what was done and any assumptions.

### Stage 0 — Setup
- Create the repo structure, Config.mqh with all inputs and enums, empty modules that compile.
- **Done when**: project compiles with zero warnings.

### Stage 1 — Engine
- Metrics, Regime (with anti-flicker), Score, vetoes, State, StrategyHint, News, Sessions.
- Buffers 0-7 filled. No visuals.
- News: CalendarValueHistory for USD high impact, cached, refreshed at most hourly. In the tester or if unavailable: disable news veto silently, log once.
- **Done when**: buffers readable via iCustom from a test script, values look sane on XAUUSD M15, full-history time within budget.

### Stage 2 — Proof engine + GATE
- Breakout event: a closed bar closes above the highest high (or below the lowest low) of the previous 20 bars.
- Failed breakout: within the next 8 bars, price closes back inside the broken level before moving +1.0 ATR in the breakout direction.
- Record MFE and MAE over the next 12 bars (ATR units).
- Group by State of the breakout bar. Output count, failed %, avg MFE, avg MAE, MFE/MAE per state.
- Print table to Experts log and write `SENTRY_proof_<symbol>_<tf>.csv` to MQL5/Files.
- **GATE (must pass before any visual work)**, over at least 2 years of XAUUSD M15:
  - at least 150 events in both GO and STAND_ASIDE;
  - STAND_ASIDE failed % is at least 15 percentage points higher than GO failed %;
  - GO MFE/MAE is higher than STAND_ASIDE MFE/MAE.
- If the gate fails: report numbers, propose rule changes, re-test. Never tune on the full history only; keep the last 6 months as an out-of-sample check and report both.

### Stage 3 — Non-repaint harness
- `Tests/SENTRY_RepaintHarness.mq5`: EA that records every buffer of every closed bar, re-checks them on every following bar, then recomputes the full history with a fresh instance and compares.
- Run on XAUUSD M1, M5, M15, H1 with "Every tick based on real ticks".
- **Done when**: zero mismatches on all runs. Record results in TESTING.md.

### Stage 4 — Chart visuals
- **Ghost candles**: draw candles with DRAW_COLOR_CANDLES. Normal colors for GO/CAUTION, blended toward the chart background for STAND_ASIDE (compute the blend; MT5 has no real alpha on buffers). Hide the native candles while active and restore them on removal.
- **Regime ribbon**: background bands behind price by regime.
- **Score strip**: thin colored strip (subwindow or bottom band), green/amber/red.
- Inputs to switch each visual on/off.
- **Done when**: looks correct on dark and light chart themes, no flicker on new bars.

### Stage 5 — Panel (CCanvas)
- Anti-aliased, draggable, collapsible, dark/light theme, auto DPI scaling (2K/4K).
- Font: Bahnschrift with fallback to Segoe UI.
- Visual identity: graphite background, amber (gold) accent, muted regime colors. Avoid neon green/red.
- **Layouts**: Minimized (verdict only) · Compact (verdict + reasons + come back) · Standard (+ factors with weights + session tape) · Full (+ proof panel + MTF regime row).
- Content:
  - Verdict (GO / CAUTION / STAND ASIDE) + score.
  - Reason chips (e.g. "CPI in 12m", "ATR 2.3x", "Spread ok").
  - Come back at.
  - Factor list with weights, filled dot when met.
  - Session tape (Tape.mqh).
  - Proof panel with the user's own numbers and the analysed period.
  - Footer: "Closed bars only · no repaint".
- **Done when**: every layout renders cleanly at 100%, 150%, 200% scaling.

### Stage 6 — Alerts
- Regime change, state change into GO, entering STAND_ASIDE due to news.
- Popup / push / sound / e-mail toggles. One alert per event, no duplicates on reload.

### Stage 7 — SENTRY Guard (free utility)
- Separate EA that reads SENTRY buffers.
- Shows a large on-chart warning when the user opens a trade during STAND_ASIDE.
- Optional: publish a global variable other EAs can check to pause entries.
- Never closes trades by default. Any closing behaviour is opt-in and clearly labelled.

### Stage 8 — Market readiness
- Passes MQL5 Market automatic validation (tester runs on multiple symbols/timeframes without errors, no division by zero, no array out of range, handles missing history).
- Graceful behaviour on non-gold symbols (works, shows a notice once).
- Final performance check against budgets in section 2.

### Stage 9 — Launch package
- Manual_EN.md and Manual_AR.md (install, layouts, reading the verdict, iCustom buffer usage).
- Product description with a "What SENTRY is not" section: not a signal service, not a forecast, the score is agreement between explicit conditions, not a probability.
- Screenshot plan: hero shot with half ghost / half clear chart; panel close-up; session tape; proof panel with real numbers; SENTRY on top of another tool.
- Headline options: "Know when not to trade." / "The best trade is sometimes no trade."

---

## 6. What we will have at the end

1. **SENTRY.ex5**: the indicator (engine, visuals, panel, alerts, 8 EA buffers).
2. **SENTRY Guard**: free companion utility.
3. **Repaint harness** with recorded zero-mismatch results.
4. **Proof results** on 2+ years of gold, used honestly in marketing.
5. **Manuals** in English and Arabic.
6. **Market listing assets**: description, screenshots, banners.
7. A codebase structured to become the base of the next products (Apex, and a future EA that uses SENTRY as its filter).

---

## 7. How to work in this repo

- One stage per session. Small commits with clear messages.
- Before finishing any task, re-read changed functions for lookahead bugs and list assumptions.
- Never add features that are not in the current stage. Put ideas in CHANGELOG.md under "Ideas".
- If a definition is unclear, ask. Do not guess trading logic.
- Keep code readable: short functions, named constants, no magic numbers.
