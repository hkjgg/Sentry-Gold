//+------------------------------------------------------------------+
//| SENTRY.mq5 — Gold Regime & No-Trade Engine (XAUUSD)              |
//|                                                                  |
//| Stage 1: engine only (buffers 0-7, no visuals).                   |
//|                                                                  |
//| Indexing: all arrays (OnCalculate inputs and indicator buffers)  |
//| are NON-series: index 0 is the oldest bar, rates_total-1 is the  |
//| forming bar.                                                     |
//|                                                                  |
//| Non-repainting: only closed bars (index <= rates_total-2) are     |
//| computed, each exactly once and in order; the forming bar holds  |
//| EMPTY_VALUE in every buffer. A full recompute happens only when  |
//| the terminal reloads history (prev_calculated == 0) or the first |
//| bar changes.                                                     |
//|                                                                  |
//| Range: the full calculation covers the last InpMaxBars closed    |
//| bars (plus an internal warm-up for ATR / EMA). Older bars stay   |
//| EMPTY_VALUE. New bars are then computed incrementally.           |
//|                                                                  |
//| Pipeline: data is fetched once per calculation (one H1 CopyRates |
//| call, at most one calendar load), then five phases run over the  |
//| bar range: metrics, ATR percentile, H1 mapping, news, regime and |
//| score. No data request and no wait happen inside a per-bar loop. |
//|                                                                  |
//| Startup: if the economic calendar is not ready in OnInit, the    |
//| full calculation waits (probe every 2 s via OnTimer, up to 30 s),|
//| then runs once, without news if necessary, with one warning.     |
//| Missing H1 history (e.g. error 4401): OnCalculate returns 0, the |
//| timer refreshes the chart until the data arrives.                |
//+------------------------------------------------------------------+
#property copyright   "SENTRY"
#property version     "1.00"
#property description "SENTRY - Gold Regime & No-Trade Engine. Tells you whether gold is tradeable now."
#property description "Closed bars only - no repaint."

#property indicator_chart_window
#property indicator_buffers 11
#property indicator_plots   8

#property indicator_type1  DRAW_NONE
#property indicator_label1 "Regime"
#property indicator_type2  DRAW_NONE
#property indicator_label2 "Score"
#property indicator_type3  DRAW_NONE
#property indicator_label3 "State"
#property indicator_type4  DRAW_NONE
#property indicator_label4 "StrategyHint"
#property indicator_type5  DRAW_NONE
#property indicator_label5 "VetoMask"
#property indicator_type6  DRAW_NONE
#property indicator_label6 "ER"
#property indicator_type7  DRAW_NONE
#property indicator_label7 "CHOP"
#property indicator_type8  DRAW_NONE
#property indicator_label8 "ATRpct"

#include "Include\Sentry\Config.mqh"
#include "Include\Sentry\Metrics.mqh"
#include "Include\Sentry\Regime.mqh"
#include "Include\Sentry\Sessions.mqh"
#include "Include\Sentry\News.mqh"
#include "Include\Sentry\Score.mqh"
//--- Placeholders for later stages (empty)
#include "Include\Sentry\ComeBack.mqh"
#include "Include\Sentry\Proof.mqh"
#include "Include\Sentry\Visuals.mqh"
#include "Include\Sentry\Panel.mqh"
#include "Include\Sentry\Tape.mqh"
#include "Include\Sentry\Alerts.mqh"

//--- Public buffers (INDICATOR_DATA)
double g_bufRegime[];
double g_bufScore[];
double g_bufState[];
double g_bufHint[];
double g_bufVeto[];
double g_bufER[];
double g_bufCHOP[];
double g_bufATRPct[];
//--- Internal buffers (INDICATOR_CALCULATIONS)
double g_bufATR[];
double g_bufEMA[];
double g_bufRawRegime[];

//--- Per-range scratch arrays, index k = i - publicFrom
double g_sER[];
double g_sCHOP[];
double g_sATRPct[];
double g_sSlope[];
double g_sBarRangeX[];
double g_sH1ER[];
double g_sH1Slope[];
bool   g_sNewsVeto[];
bool   g_sNewsNear[];

//--- Timing of one calculation (microseconds)
struct SentryTiming
  {
   ulong             metricsUs;
   ulong             atrPctUs;
   ulong             h1Us;
   ulong             newsUs;
   ulong             scoreUs;
  };

//--- Engine state
int      g_nextBar           = 0;       // first bar not computed yet
int      g_firstPublicBar    = 0;       // first bar with public values (last InpMaxBars closed bars)
int      g_emaStart          = 0;       // EMA seed start (first internally computed bar)
datetime g_firstBarTime      = 0;       // time[0] when the history was last computed
datetime g_newsFrom          = 0;       // calendar range start for this history
bool     g_fullHistoryDone   = false;
int      g_newsCursorVeto    = 0;       // moving pointers into the news cache
int      g_newsCursorNear    = 0;
bool     g_timingPrinted     = false;
bool     g_newsHistoryWarned = false;
ulong    g_maxIncrementalUs  = 0;
int      g_incrementalCount  = 0;

//--- Retry timer state
bool     g_timerOn           = false;
bool     g_calendarWaiting   = false;   // full calculation delayed until the calendar is ready
ulong    g_calendarWaitFrom  = 0;
bool     g_h1Pending         = false;   // H1 history requested, not available yet
ulong    g_h1PendingFrom     = 0;       // 0 = never pending
bool     g_h1WaitLogged      = false;

//+------------------------------------------------------------------+
//| Retry timer: runs while the calendar wait or an H1 history       |
//| request is pending, and is killed as soon as neither is.         |
//+------------------------------------------------------------------+
void Sentry_UpdateTimer()
  {
   const bool needed = (g_calendarWaiting || g_h1Pending);
   if(needed && !g_timerOn)
      g_timerOn = EventSetTimer(SENTRY_TIMER_SECONDS);
   else if(!needed && g_timerOn)
     {
      EventKillTimer();
      g_timerOn = false;
     }
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(!Config_Validate())
      return INIT_PARAMETERS_INCORRECT;

   SetIndexBuffer(SENTRY_BUF_REGIME,     g_bufRegime,     INDICATOR_DATA);
   SetIndexBuffer(SENTRY_BUF_SCORE,      g_bufScore,      INDICATOR_DATA);
   SetIndexBuffer(SENTRY_BUF_STATE,      g_bufState,      INDICATOR_DATA);
   SetIndexBuffer(SENTRY_BUF_HINT,       g_bufHint,       INDICATOR_DATA);
   SetIndexBuffer(SENTRY_BUF_VETO,       g_bufVeto,       INDICATOR_DATA);
   SetIndexBuffer(SENTRY_BUF_ER,         g_bufER,         INDICATOR_DATA);
   SetIndexBuffer(SENTRY_BUF_CHOP,       g_bufCHOP,       INDICATOR_DATA);
   SetIndexBuffer(SENTRY_BUF_ATRPCT,     g_bufATRPct,     INDICATOR_DATA);
   SetIndexBuffer(SENTRY_BUF_ATR,        g_bufATR,        INDICATOR_CALCULATIONS);
   SetIndexBuffer(SENTRY_BUF_EMA,        g_bufEMA,        INDICATOR_CALCULATIONS);
   SetIndexBuffer(SENTRY_BUF_RAW_REGIME, g_bufRawRegime,  INDICATOR_CALCULATIONS);

   ArraySetAsSeries(g_bufRegime,    false);
   ArraySetAsSeries(g_bufScore,     false);
   ArraySetAsSeries(g_bufState,     false);
   ArraySetAsSeries(g_bufHint,      false);
   ArraySetAsSeries(g_bufVeto,      false);
   ArraySetAsSeries(g_bufER,        false);
   ArraySetAsSeries(g_bufCHOP,      false);
   ArraySetAsSeries(g_bufATRPct,    false);
   ArraySetAsSeries(g_bufATR,       false);
   ArraySetAsSeries(g_bufEMA,       false);
   ArraySetAsSeries(g_bufRawRegime, false);

   for(int plot = 0; plot < SENTRY_DATA_BUFFERS; plot++)
      PlotIndexSetDouble(plot, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   IndicatorSetString(INDICATOR_SHORTNAME, SENTRY_NAME);
   IndicatorSetInteger(INDICATOR_DIGITS, 4);

   News_Init();
   H1_Reset();
   g_nextBar           = 0;
   g_firstPublicBar    = 0;
   g_emaStart          = 0;
   g_firstBarTime      = 0;
   g_newsFrom          = 0;
   g_fullHistoryDone   = false;
   g_timingPrinted     = false;
   g_newsHistoryWarned = false;
   g_maxIncrementalUs  = 0;
   g_incrementalCount  = 0;
   g_timerOn           = false;
   g_h1Pending         = false;
   g_h1PendingFrom     = 0;
   g_h1WaitLogged      = false;

   g_calendarWaiting  = (News_IsEnabled() && !News_Probe());
   g_calendarWaitFrom = GetTickCount64();
   Sentry_UpdateTimer();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_timerOn)
      EventKillTimer();
   g_timerOn = false;
   if(g_incrementalCount > 0)
      PrintFormat("%s: incremental updates: %d, slowest %.3f ms (budget 5 ms per new bar).",
                  SENTRY_NAME, g_incrementalCount, (double)g_maxIncrementalUs / 1000.0);
   H1_Reset();
  }

bool Sentry_CalendarWaitExpired()
  {
   return (GetTickCount64() - g_calendarWaitFrom >= SENTRY_CALENDAR_WAIT_MS);
  }

//+------------------------------------------------------------------+
//| Chart refresh makes the terminal call OnCalculate again, even    |
//| without ticks (only when SENTRY runs on this chart's symbol/TF). |
//+------------------------------------------------------------------+
void Sentry_RefreshChart()
  {
   if(ChartSymbol(0) != _Symbol || ChartPeriod(0) != _Period)
      return;
   if(!ChartSetSymbolPeriod(0, _Symbol, _Period))
      PrintFormat("%s: chart refresh failed (error %d); calculation continues on the next tick.", SENTRY_NAME, GetLastError());
  }

//+------------------------------------------------------------------+
//| Every 2 s: releases the calendar wait when the calendar is ready |
//| or 30 s have passed; refreshes the chart while H1 history loads  |
//| (up to SENTRY_H1_RETRY_MS, then ticks only).                     |
//+------------------------------------------------------------------+
void OnTimer()
  {
   bool refresh = false;
   if(g_calendarWaiting)
     {
      if(News_Probe() || Sentry_CalendarWaitExpired())
        {
         g_calendarWaiting = false;
         refresh = true;
        }
     }
   else if(g_h1Pending)
     {
      if(GetTickCount64() - g_h1PendingFrom >= SENTRY_H1_RETRY_MS)
         g_h1Pending = false;
      else
         refresh = true;
     }
   Sentry_UpdateTimer();
   if(refresh)
      Sentry_RefreshChart();
  }

//+------------------------------------------------------------------+
//| H1 history not available: log once, keep the timer refreshing.   |
//+------------------------------------------------------------------+
void Sentry_OnH1Missing(const int error)
  {
   if(!g_h1WaitLogged)
     {
      g_h1WaitLogged = true;
      PrintFormat("%s: H1 history of %s requested (error %d); calculation continues when it arrives.",
                  SENTRY_NAME, _Symbol, error);
     }
   const ulong now = GetTickCount64();
   if(g_h1PendingFrom == 0)
      g_h1PendingFrom = now;
   g_h1Pending = (now - g_h1PendingFrom < SENTRY_H1_RETRY_MS);
   Sentry_UpdateTimer();
  }

void Sentry_OnH1Ready()
  {
   if(!g_h1Pending)
      return;
   g_h1Pending = false;
   Sentry_UpdateTimer();
  }

//+------------------------------------------------------------------+
//| Writes EMPTY_VALUE to every buffer at bar i.                     |
//+------------------------------------------------------------------+
void Sentry_SetEmpty(const int i)
  {
   g_bufRegime[i]    = EMPTY_VALUE;
   g_bufScore[i]     = EMPTY_VALUE;
   g_bufState[i]     = EMPTY_VALUE;
   g_bufHint[i]      = EMPTY_VALUE;
   g_bufVeto[i]      = EMPTY_VALUE;
   g_bufER[i]        = EMPTY_VALUE;
   g_bufCHOP[i]      = EMPTY_VALUE;
   g_bufATRPct[i]    = EMPTY_VALUE;
   g_bufATR[i]       = EMPTY_VALUE;
   g_bufEMA[i]       = EMPTY_VALUE;
   g_bufRawRegime[i] = EMPTY_VALUE;
  }

void Sentry_Reset(const datetime firstBarTime)
  {
   ArrayInitialize(g_bufRegime,    EMPTY_VALUE);
   ArrayInitialize(g_bufScore,     EMPTY_VALUE);
   ArrayInitialize(g_bufState,     EMPTY_VALUE);
   ArrayInitialize(g_bufHint,      EMPTY_VALUE);
   ArrayInitialize(g_bufVeto,      EMPTY_VALUE);
   ArrayInitialize(g_bufER,        EMPTY_VALUE);
   ArrayInitialize(g_bufCHOP,      EMPTY_VALUE);
   ArrayInitialize(g_bufATRPct,    EMPTY_VALUE);
   ArrayInitialize(g_bufATR,       EMPTY_VALUE);
   ArrayInitialize(g_bufEMA,       EMPTY_VALUE);
   ArrayInitialize(g_bufRawRegime, EMPTY_VALUE);
   H1_Reset();
   g_nextBar         = 0;
   g_firstPublicBar  = 0;
   g_emaStart        = 0;
   g_firstBarTime    = firstBarTime;
   g_fullHistoryDone = false;
   g_newsCursorVeto  = 0;
   g_newsCursorNear  = 0;
  }

//+------------------------------------------------------------------+
//| Internal bars computed before the first public bar so that ATR   |
//| percentile and the settled EMA slope are valid on it.            |
//+------------------------------------------------------------------+
int Sentry_WarmupBars()
  {
   const int atrPctNeed = InpATRPctLookback - 1;
   const int slopeNeed  = InpEMAPeriod - 1 + SENTRY_EMA_SETTLE_BARS + InpSlopeLag;
   return (atrPctNeed > slopeNeed) ? atrPctNeed : slopeNeed;
  }

void Sentry_ResizeScratch(const int size)
  {
   ArrayResize(g_sER,        size);
   ArrayResize(g_sCHOP,      size);
   ArrayResize(g_sATRPct,    size);
   ArrayResize(g_sSlope,     size);
   ArrayResize(g_sBarRangeX, size);
   ArrayResize(g_sH1ER,      size);
   ArrayResize(g_sH1Slope,   size);
   ArrayResize(g_sNewsVeto,  size);
   ArrayResize(g_sNewsNear,  size);
  }

//+------------------------------------------------------------------+
//| Phase 1: ATR / EMA for [from..to]; ER, CHOP, slope, BarRangeX    |
//| for the public part [publicFrom..to].                            |
//+------------------------------------------------------------------+
void Sentry_PhaseMetrics(const int from, const int publicFrom, const int to,
                         const double &high[], const double &low[], const double &close[])
  {
   for(int i = from; i <= to; i++)
     {
      g_bufATR[i] = Metrics_ATR(high, low, close, i, InpATRPeriod);
      g_bufEMA[i] = Metrics_EMA(close, g_bufEMA, i, InpEMAPeriod, g_emaStart);
      if(i < publicFrom)
         continue;
      const int k = i - publicFrom;
      g_sER[k]        = Metrics_ER(close, i, InpERPeriod);
      g_sCHOP[k]      = Metrics_CHOP(high, low, close, i, InpChopPeriod);
      g_sSlope[k]     = Metrics_Slope(g_bufEMA, g_bufATR, i, InpSlopeLag, InpEMAPeriod, g_emaStart);
      g_sBarRangeX[k] = Metrics_BarRangeX(high, low, g_bufATR, i);
     }
  }

//+------------------------------------------------------------------+
//| Phase 2: ATR percentile, one pass per bar over the ATR history.  |
//+------------------------------------------------------------------+
void Sentry_PhaseATRPct(const int publicFrom, const int to)
  {
   for(int i = publicFrom; i <= to; i++)
      g_sATRPct[i - publicFrom] = Metrics_ATRPercentile(g_bufATR, i, InpATRPctLookback);
  }

//+------------------------------------------------------------------+
//| Phase 3: map each bar to its H1 bar (moving pointer).            |
//+------------------------------------------------------------------+
void Sentry_PhaseH1(const int publicFrom, const int to, const datetime &time[])
  {
   for(int i = publicFrom; i <= to; i++)
     {
      const int k = i - publicFrom;
      double h1ER    = EMPTY_VALUE;
      double h1Slope = EMPTY_VALUE;
      Metrics_H1Bias(Sessions_BarCloseTime(time[i]), h1ER, h1Slope);
      g_sH1ER[k]    = h1ER;
      g_sH1Slope[k] = h1Slope;
     }
  }

//+------------------------------------------------------------------+
//| Phase 4: news flags per bar (moving pointers).                   |
//+------------------------------------------------------------------+
void Sentry_PhaseNews(const int publicFrom, const int to, const datetime &time[])
  {
   for(int i = publicFrom; i <= to; i++)
     {
      const int k = i - publicFrom;
      const datetime openTime  = time[i];
      const datetime closeTime = Sessions_BarCloseTime(openTime);
      g_sNewsVeto[k] = News_EventWithin(openTime, closeTime, InpNewsVetoMinutes, g_newsCursorVeto);
      g_sNewsNear[k] = News_EventWithin(openTime, closeTime, InpNewsDistanceMinutes, g_newsCursorNear);
     }
  }

//+------------------------------------------------------------------+
//| Phase 5: regime, anti-flicker, factors, score, state, hint.      |
//| Bars with any missing metric (warm-up) stay EMPTY_VALUE.         |
//+------------------------------------------------------------------+
void Sentry_PhaseScore(const int publicFrom, const int to, const datetime &time[], const int &spread[])
  {
   const bool newsAvailable = News_IsAvailable();
   for(int i = publicFrom; i <= to; i++)
     {
      const int k = i - publicFrom;
      SentryMetrics m;
      m.er        = g_sER[k];
      m.chop      = g_sCHOP[k];
      m.atrPct    = g_sATRPct[k];
      m.slope     = g_sSlope[k];
      m.barRangeX = g_sBarRangeX[k];
      m.h1ER      = g_sH1ER[k];
      m.h1Slope   = g_sH1Slope[k];
      if(Metrics_IsEmpty(m.er) || Metrics_IsEmpty(m.chop) || Metrics_IsEmpty(m.atrPct) ||
         Metrics_IsEmpty(m.slope) || Metrics_IsEmpty(m.barRangeX) ||
         Metrics_IsEmpty(m.h1ER) || Metrics_IsEmpty(m.h1Slope))
         continue;   // warm-up: buffers already hold EMPTY_VALUE

      const ENUM_SENTRY_REGIME raw       = Regime_Classify(m);
      const ENUM_SENTRY_REGIME published = Regime_Publish(g_bufRawRegime, g_bufRegime, i, raw);
      const double spreadPrice = spread[i] * _Point;   // this bar's own spread, never the live one

      SentryFactors f;
      ZeroMemory(f);
      f.regimeClear       = Score_RegimeClear(published, raw, m.er);
      f.volatilityHealthy = Score_VolatilityHealthy(m.atrPct);
      f.inSession         = Sessions_IsActive(time[i]);
      f.h1Aligned         = Score_H1Aligned(published, m.h1ER, m.h1Slope);
      f.spreadOk          = Score_SpreadOk(spreadPrice);
      f.newsAvailable     = newsAvailable;
      f.farFromNews       = !g_sNewsNear[k];

      const int vetoMask = Score_VetoMask(g_sNewsVeto[k], f.spreadOk, published);
      const int score    = Score_ApplyVetoCap(Score_Weighted(f), vetoMask);
      const ENUM_SENTRY_STATE state = Score_State(score);

      g_bufRawRegime[i] = (double)raw;
      g_bufRegime[i]    = (double)published;
      g_bufScore[i]     = (double)score;
      g_bufState[i]     = (double)state;
      g_bufHint[i]      = (double)Score_StrategyHint(published, state);
      g_bufVeto[i]      = (double)vetoMask;
      g_bufER[i]        = m.er;
      g_bufCHOP[i]      = m.chop;
      g_bufATRPct[i]    = m.atrPct;
     }
  }

//+------------------------------------------------------------------+
//| Runs phases 1-5 over [from..to]; public values from publicFrom.  |
//+------------------------------------------------------------------+
void Sentry_RunRange(const int from, const int publicFrom, const int to,
                     const datetime &time[], const double &high[], const double &low[],
                     const double &close[], const int &spread[], SentryTiming &t)
  {
   const int publicCount = (to >= publicFrom) ? to - publicFrom + 1 : 0;
   ulong mark = GetMicrosecondCount();
   Sentry_ResizeScratch(publicCount);
   Sentry_PhaseMetrics(from, publicFrom, to, high, low, close);
   ulong now = GetMicrosecondCount();
   t.metricsUs += now - mark;
   mark = now;
   if(publicCount == 0)
      return;

   Sentry_PhaseATRPct(publicFrom, to);
   now = GetMicrosecondCount();
   t.atrPctUs += now - mark;
   mark = now;

   Sentry_PhaseH1(publicFrom, to, time);
   now = GetMicrosecondCount();
   t.h1Us += now - mark;
   mark = now;

   Sentry_PhaseNews(publicFrom, to, time);
   now = GetMicrosecondCount();
   t.newsUs += now - mark;
   mark = now;

   Sentry_PhaseScore(publicFrom, to, time, spread);
   t.scoreUs += GetMicrosecondCount() - mark;
  }

//+------------------------------------------------------------------+
//| One-time timing breakdown after the full calculation.            |
//+------------------------------------------------------------------+
void Sentry_PrintTiming(const SentryTiming &t, const ulong totalUs, const int publicBars, const int warmupBars)
  {
   PrintFormat("%s: full calculation %s %s: %d bars (+%d warm-up). metrics %.2f ms | ATRpct %.2f ms | H1 %.2f ms | " +
               "news %.2f ms | regime/score %.2f ms | total %.2f ms (budget 200 ms).",
               SENTRY_NAME, _Symbol, EnumToString(_Period), publicBars, warmupBars,
               (double)t.metricsUs / 1000.0, (double)t.atrPctUs / 1000.0, (double)t.h1Us / 1000.0,
               (double)t.newsUs / 1000.0, (double)t.scoreUs / 1000.0, (double)totalUs / 1000.0);
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   ArraySetAsSeries(time,   false);
   ArraySetAsSeries(high,   false);
   ArraySetAsSeries(low,    false);
   ArraySetAsSeries(close,  false);
   ArraySetAsSeries(spread, false);

   if(rates_total < 2)
      return 0;

   if(prev_calculated == 0 || time[0] != g_firstBarTime || g_nextBar > rates_total - 1)
      Sentry_Reset(time[0]);   // every buffer is EMPTY_VALUE now
   else
     {
      //--- bars not computed yet (including the forming bar) hold EMPTY_VALUE
      for(int i = g_nextBar; i < rates_total; i++)
         Sentry_SetEmpty(i);
     }

   //--- startup: the full calculation waits for the calendar (timer probes it)
   if(g_calendarWaiting)
     {
      if(!Sentry_CalendarWaitExpired())
         return 0;
      g_calendarWaiting = false;   // timer did not release it in time: continue on this call
      Sentry_UpdateTimer();
     }

   const int  lastClosed = rates_total - 2;
   const bool fullRun    = !g_fullHistoryDone;
   if(fullRun)
     {
      const int firstPublic = lastClosed - InpMaxBars + 1;
      g_firstPublicBar = (firstPublic > 0) ? firstPublic : 0;
      const int emaStart = g_firstPublicBar - Sentry_WarmupBars();
      g_emaStart = (emaStart > 0) ? emaStart : 0;
      g_nextBar  = g_emaStart;   // bars before g_emaStart are never computed
      g_newsFrom = (datetime)((long)time[g_firstPublicBar] - (long)InpNewsDistanceMinutes * 60);
     }
   if(g_nextBar > lastClosed)
      return rates_total;

   const ulong startUs = GetMicrosecondCount();
   SentryTiming t;
   ZeroMemory(t);

   //--- H1: one CopyRates per calculation; never wait for it here
   ulong mark = GetMicrosecondCount();
   const bool h1Ok    = H1_Update(time[g_nextBar]);
   const int  h1Error = GetLastError();
   t.h1Us += GetMicrosecondCount() - mark;
   if(!h1Ok)
     {
      Sentry_OnH1Missing(h1Error);
      return fullRun ? 0 : rates_total;
     }
   Sentry_OnH1Ready();

   //--- last bar whose H1 bar is final (readiness is monotonic in time)
   int to = lastClosed;
   while(to >= g_nextBar && !H1_IsReadyFor(Sessions_BarCloseTime(time[to])))
      to--;
   if(to < g_nextBar)
      return fullRun ? 0 : rates_total;

   //--- news: at most one calendar load per calculation (hourly refresh)
   mark = GetMicrosecondCount();
   News_Refresh(g_newsFrom);
   t.newsUs += GetMicrosecondCount() - mark;

   const int from       = g_nextBar;
   const int publicFrom = (from > g_firstPublicBar) ? from : g_firstPublicBar;
   Sentry_RunRange(from, publicFrom, to, time, high, low, close, spread, t);
   g_nextBar = to + 1;

   const ulong totalUs = GetMicrosecondCount() - startUs;
   if(fullRun)
     {
      g_fullHistoryDone = true;
      if(!g_timingPrinted)
        {
         g_timingPrinted = true;
         Sentry_PrintTiming(t, totalUs, to - publicFrom + 1, publicFrom - from);
        }
      if(News_IsEnabled() && !News_IsAvailable() && !g_newsHistoryWarned)
        {
         g_newsHistoryWarned = true;
         PrintFormat("%s WARNING: economic calendar not available (error %d). History was computed WITHOUT news: " +
                     "news vetoes and the news factor are missing from past bars. Live bars use news once the calendar loads (retried hourly); past bars are not rescored.",
                     SENTRY_NAME, g_newsLastError);
        }
     }
   else
     {
      Sessions_CheckLiveOffset();
      g_incrementalCount++;
      if(totalUs > g_maxIncrementalUs)
         g_maxIncrementalUs = totalUs;
     }
   return rates_total;
  }
//+------------------------------------------------------------------+
