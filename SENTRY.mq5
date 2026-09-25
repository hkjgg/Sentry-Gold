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
//| Startup: if the economic calendar is not ready in OnInit, the    |
//| full-history calculation waits (probe every 2 s via OnTimer, up  |
//| to 30 s). After that it runs once, without news if necessary,    |
//| and prints one warning.                                          |
//+------------------------------------------------------------------+
#property copyright   "SENTRY"
#property version     "0.10"
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

//--- Engine state
int      g_nextBar          = 0;       // first closed bar not computed yet
datetime g_firstBarTime     = 0;       // time[0] when the history was last computed
bool     g_fullHistoryDone  = false;
bool     g_h1WaitLogged     = false;
bool     g_timingPrinted    = false;
bool     g_calendarWaiting  = false;   // full history delayed until the calendar is ready
ulong    g_calendarWaitFrom = 0;       // GetTickCount64() when the wait started
bool     g_newsHistoryWarned = false;
ulong    g_maxIncrementalUs = 0;
int      g_incrementalCount = 0;

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
   g_nextBar          = 0;
   g_firstBarTime     = 0;
   g_fullHistoryDone  = false;
   g_h1WaitLogged     = false;
   g_timingPrinted    = false;
   g_newsHistoryWarned = false;
   g_maxIncrementalUs = 0;
   g_incrementalCount = 0;

   g_calendarWaiting = false;
   if(News_IsEnabled() && !News_Probe())
     {
      g_calendarWaiting  = true;
      g_calendarWaitFrom = GetTickCount64();
      if(!EventSetTimer(SENTRY_CALENDAR_RETRY_SECONDS))
         PrintFormat("%s: timer unavailable (error %d); calendar wait continues on ticks.", SENTRY_NAME, GetLastError());
     }
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_incrementalCount > 0)
      PrintFormat("%s: incremental updates: %d, slowest %.3f ms (budget 5 ms per new bar).",
                  SENTRY_NAME, g_incrementalCount, (double)g_maxIncrementalUs / 1000.0);
   H1_Reset();
  }

//+------------------------------------------------------------------+
//| Startup calendar wait                                            |
//+------------------------------------------------------------------+
bool Sentry_CalendarWaitExpired()
  {
   return (GetTickCount64() - g_calendarWaitFrom >= SENTRY_CALENDAR_WAIT_MS);
  }

void Sentry_StopCalendarWait()
  {
   g_calendarWaiting = false;
   EventKillTimer();
  }

//+------------------------------------------------------------------+
//| Probes the calendar every 2 s; when it is ready or 30 s have     |
//| passed, releases the full-history calculation and refreshes the  |
//| chart so it runs now, even without ticks.                        |
//+------------------------------------------------------------------+
void OnTimer()
  {
   if(!g_calendarWaiting)
     {
      EventKillTimer();
      return;
     }
   if(!News_Probe() && !Sentry_CalendarWaitExpired())
      return;
   Sentry_StopCalendarWait();
   if(ChartSymbol(0) == _Symbol && ChartPeriod(0) == _Period)
     {
      if(!ChartSetSymbolPeriod(0, _Symbol, _Period))
         PrintFormat("%s: chart refresh failed (error %d); calculation starts on the next tick.", SENTRY_NAME, GetLastError());
     }
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

//+------------------------------------------------------------------+
//| Writes EMPTY_VALUE to the public buffers only (warm-up bars keep |
//| their internal ATR / EMA values, which later bars need).         |
//+------------------------------------------------------------------+
void Sentry_SetPublicEmpty(const int i)
  {
   g_bufRegime[i]    = EMPTY_VALUE;
   g_bufScore[i]     = EMPTY_VALUE;
   g_bufState[i]     = EMPTY_VALUE;
   g_bufHint[i]      = EMPTY_VALUE;
   g_bufVeto[i]      = EMPTY_VALUE;
   g_bufER[i]        = EMPTY_VALUE;
   g_bufCHOP[i]      = EMPTY_VALUE;
   g_bufATRPct[i]    = EMPTY_VALUE;
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
   g_firstBarTime    = firstBarTime;
   g_fullHistoryDone = false;
  }

//+------------------------------------------------------------------+
//| Computes closed bar i once. Returns false (nothing written) when |
//| the H1 data this bar needs is not final yet.                     |
//+------------------------------------------------------------------+
bool Sentry_ComputeBar(const int i,
                       const datetime &time[],
                       const double &high[],
                       const double &low[],
                       const double &close[],
                       const int &spread[])
  {
   const datetime openTime  = time[i];
   const datetime closeTime = Sessions_BarCloseTime(openTime);
   if(!H1_IsReadyFor(closeTime))
      return false;

   g_bufATR[i] = Metrics_ATR(high, low, close, i, InpATRPeriod);
   g_bufEMA[i] = Metrics_EMA(close, g_bufEMA, i, InpEMAPeriod);

   SentryMetrics m;
   ZeroMemory(m);
   if(!Metrics_Collect(i, closeTime, high, low, close, g_bufATR, g_bufEMA, m))
     {
      Sentry_SetPublicEmpty(i);   // warm-up: not enough history
      return true;
     }

   const ENUM_SENTRY_REGIME raw       = Regime_Classify(m);
   const ENUM_SENTRY_REGIME published = Regime_Publish(g_bufRawRegime, g_bufRegime, i, raw);

   const bool   newsAvailable = News_IsAvailable();
   const bool   newsVeto      = newsAvailable && News_EventWithin(openTime, closeTime, InpNewsVetoMinutes);
   const bool   newsNear      = newsAvailable && News_EventWithin(openTime, closeTime, InpNewsDistanceMinutes);
   const double spreadPrice   = spread[i] * _Point;   // this bar's own spread, never the live one

   SentryFactors f;
   ZeroMemory(f);
   f.regimeClear       = Score_RegimeClear(published, raw, m.er);
   f.volatilityHealthy = Score_VolatilityHealthy(m.atrPct);
   f.inSession         = Sessions_IsActive(openTime);
   f.h1Aligned         = Score_H1Aligned(published, m.h1ER, m.h1Slope);
   f.spreadOk          = Score_SpreadOk(spreadPrice);
   f.newsAvailable     = newsAvailable;
   f.farFromNews       = !newsNear;

   const int vetoMask = Score_VetoMask(newsVeto, f.spreadOk, published);
   const int score    = Score_ApplyVetoCap(Score_Weighted(f), vetoMask);

   g_bufRawRegime[i] = (double)raw;
   g_bufRegime[i]    = (double)published;
   g_bufScore[i]     = (double)score;
   const ENUM_SENTRY_STATE state = Score_State(score);
   g_bufState[i]     = (double)state;
   g_bufHint[i]      = (double)Score_StrategyHint(published, state);
   g_bufVeto[i]      = (double)vetoMask;
   g_bufER[i]        = m.er;
   g_bufCHOP[i]      = m.chop;
   g_bufATRPct[i]    = m.atrPct;
   return true;
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
      Sentry_Reset(time[0]);

   //--- bars not computed yet (including the forming bar) hold EMPTY_VALUE
   for(int i = g_nextBar; i < rates_total; i++)
      Sentry_SetEmpty(i);

   //--- startup: full history waits for the calendar (timer probes it)
   if(g_calendarWaiting)
     {
      if(!Sentry_CalendarWaitExpired())
         return 0;
      Sentry_StopCalendarWait();   // timer did not fire in time: continue on this tick
     }

   const int lastClosed = rates_total - 2;
   if(g_nextBar > lastClosed)
      return rates_total;

   const ulong newsStartUs = GetMicrosecondCount();
   News_Refresh((datetime)((long)time[0] - (long)InpNewsDistanceMinutes * 60));
   const ulong startUs = GetMicrosecondCount();
   const ulong newsUs  = startUs - newsStartUs;

   if(!H1_Update(time[0]))
     {
      if(!g_h1WaitLogged)
        {
         g_h1WaitLogged = true;
         PrintFormat("%s: waiting for H1 history of %s (error %d).", SENTRY_NAME, _Symbol, GetLastError());
        }
      return g_fullHistoryDone ? rates_total : 0;
     }

   const int firstToCompute = g_nextBar;
   for(int i = g_nextBar; i <= lastClosed; i++)
     {
      if(!Sentry_ComputeBar(i, time, high, low, close, spread))
         break;   // H1 bar not final yet: retry on the next tick
      g_nextBar = i + 1;
     }
   const int computed  = g_nextBar - firstToCompute;
   const ulong elapsed = GetMicrosecondCount() - startUs;   // engine time, calendar load excluded

   if(!g_fullHistoryDone)
     {
      g_fullHistoryDone = true;
      if(!g_timingPrinted)
        {
         g_timingPrinted = true;
         const double ms      = (double)elapsed / 1000.0;
         const double per5000 = (computed > 0) ? ms * 5000.0 / computed : 0.0;
         PrintFormat("%s: full history %s %s: %d bars in %.2f ms (%.2f ms per 5000 bars; budget 200 ms). Calendar load %.2f ms.",
                     SENTRY_NAME, _Symbol, EnumToString(_Period), computed, ms, per5000, (double)newsUs / 1000.0);
        }
      if(News_IsEnabled() && !News_IsAvailable() && !g_newsHistoryWarned)
        {
         g_newsHistoryWarned = true;
         PrintFormat("%s WARNING: economic calendar not available (error %d). History was computed WITHOUT news: " +
                     "news vetoes and the news factor are missing from past bars. Live bars use news once the calendar loads (retried hourly); past bars are not rescored.",
                     SENTRY_NAME, g_newsLastError);
        }
     }
   else if(computed > 0)
     {
      Sessions_CheckLiveOffset();
      g_incrementalCount++;
      if(elapsed > g_maxIncrementalUs)
         g_maxIncrementalUs = elapsed;
     }
   return rates_total;
  }
//+------------------------------------------------------------------+
