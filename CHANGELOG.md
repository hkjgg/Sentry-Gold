# Changelog

## [Unreleased]

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
- Automatic server GMT offset with DST handling. It would have to be derived from history, because `TimeGMT()` is not meaningful in the tester.
- Retry a failed calendar load sooner than one hour, and optionally rescore bars that were computed while the calendar was unavailable. Rescoring needs an explicit non-repaint policy.
- ATR percentile over a sorted sliding window (O(log n) per bar) if the performance budget ever gets tight.
- Notice once on non-gold symbols (planned for Stage 8).
