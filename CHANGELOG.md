# Changelog

## [Unreleased]

### Stage 1 — Review changes
- Regime clarity: RANGE earns the 35 points only when ER ≤ 0.25 (new input `InpRangeClarityERMax`). A RANGE with a higher ER is a transition and scores 0. The TREND rule is unchanged.
- StrategyHint is 0 (none) whenever State is STAND_ASIDE. The Regime buffer is unchanged.
- Sessions: new `InpSessionTimeMode`, AUTO by default:
  - The server is GMT+2, or GMT+3 during US DST, evaluated for each bar.
  - Sessions are London 08:00-17:00 Europe/London and New York 08:00-17:00 America/New_York, with UK and US DST rules.
  - On live bars the AUTO offset is checked against `TimeTradeServer() − TimeGMT()`, with a warning logged once if they differ.
  - MANUAL keeps the previous fixed-offset GMT windows.
- Calendar at startup:
  - If the calendar is not ready in `OnInit`, the full history waits. `OnTimer` checks every 2 s for up to 30 s, then the history runs once (the chart is refreshed so it runs even without ticks).
  - If the calendar is still unavailable, SENTRY prints one warning that news vetoes are missing from history.
  - Calendar load failures no longer log on their own.

### Stage 1 — Engine
- `Config.mqh`: all inputs with documented defaults, the Regime/State/StrategyHint enums, veto bit flags, buffer indices, engine constants and input validation.
- `Metrics.mqh`: ER(20), CHOP(14), ATR(14), ATR percentile(500), EMA(50) slope, BarRangeX, and an H1 cache with an H1 bias lookup (no lookahead: only the last H1 bar whose close time ≤ the chart bar's close time).
- `Regime.mqh`: SPIKE > CHOP > TREND_UP/TREND_DOWN > RANGE, with 2-bar anti-flicker and SPIKE published immediately.
- `Sessions.mqh`: London / New York membership from server time and a fixed GMT offset, plus bar close time.
- `News.mqh`: USD high-impact events from `CalendarValueHistory`, cached and refreshed at most hourly. Disabled and logged once in the tester or when the calendar is unavailable.
- `Score.mqh`: binary factors with weights 35/20/15/15/10/5, veto mask, cap at 25, State, StrategyHint.
- `SENTRY.mq5`: buffers 0-7 (plus 3 internal calculation buffers). Closed bars only, each computed once. The forming bar is `EMPTY_VALUE`. Full history then incremental. Engine time is printed once.
- `Tests/SENTRY_BufferCheck.mq5`: prints the last 20 closed bars of buffers 0-7 via `iCustom`.

### Stage 0 — Setup
- Repository structure from CLAUDE.md §3. `ComeBack`, `Proof`, `Visuals`, `Panel`, `Tape` and `Alerts` are empty, compilable placeholders, and so are `SENTRY_RepaintHarness` and `SENTRY_Guard`.
- README.md, TESTING.md, CHANGELOG.md skeletons.

## Ideas
- Detect the broker's offset convention from history (for example the weekly open hour) for brokers that are not New York-close.
- Retry a failed calendar load sooner than one hour, and optionally rescore bars that were computed while the calendar was unavailable. Rescoring needs an explicit non-repaint policy.
- ATR percentile over a sorted sliding window (O(log n) per bar) if the performance budget ever gets tight.
- Notice once on non-gold symbols (planned for Stage 8).
