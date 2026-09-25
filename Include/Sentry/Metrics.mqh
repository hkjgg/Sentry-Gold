//+------------------------------------------------------------------+
//| Metrics.mqh — ER, CHOP, ATR, ATR percentile, slope, bar range,   |
//| H1 bias.                                                         |
//|                                                                  |
//| Indexing: every array in this file is NON-series (index 0 is the |
//| oldest bar). Each function reads only indices <= i.              |
//| A function returns EMPTY_VALUE when there is not enough history. |
//|                                                                  |
//| The metric functions are pure (arrays + index + inputs, no       |
//| globals), so the same code runs on the indicator buffers and on  |
//| large standalone arrays (Stage 2 Proof engine, chunked runs).    |
//+------------------------------------------------------------------+
#ifndef SENTRY_METRICS_MQH
#define SENTRY_METRICS_MQH

#include "Config.mqh"

//--- Per-bar metric snapshot (input of Regime_Classify)
struct SentryMetrics
  {
   double            er;
   double            chop;
   double            atrPct;
   double            slope;
   double            barRangeX;
   double            h1ER;
   double            h1Slope;
  };

bool Metrics_IsEmpty(const double value)
  {
   return (value == EMPTY_VALUE);
  }

//+------------------------------------------------------------------+
//| True range of bar k (needs k >= 1).                              |
//+------------------------------------------------------------------+
double Metrics_TrueRange(const double &high[], const double &low[], const double &close[], const int k)
  {
   const double prevClose = close[k - 1];
   return MathMax(high[k], prevClose) - MathMin(low[k], prevClose);
  }

//+------------------------------------------------------------------+
//| ATR: simple average of the last `period` true ranges.            |
//+------------------------------------------------------------------+
double Metrics_ATR(const double &high[], const double &low[], const double &close[], const int i, const int period)
  {
   if(period < 1 || i < period)
      return EMPTY_VALUE;
   double sum = 0.0;
   for(int k = i - period + 1; k <= i; k++)
      sum += Metrics_TrueRange(high, low, close, k);
   return sum / period;
  }

//+------------------------------------------------------------------+
//| EMA seeded at index start + period - 1 with the SMA of           |
//| price[start .. start + period - 1]; recursive afterwards.        |
//| ema[] holds the values already computed for bars < i.            |
//+------------------------------------------------------------------+
double Metrics_EMA(const double &price[], const double &ema[], const int i, const int period, const int start)
  {
   const int seedIndex = start + period - 1;
   if(period < 1 || start < 0 || i < seedIndex)
      return EMPTY_VALUE;
   if(i == seedIndex)
     {
      double sum = 0.0;
      for(int k = start; k <= seedIndex; k++)
         sum += price[k];
      return sum / period;
     }
   if(Metrics_IsEmpty(ema[i - 1]))
      return EMPTY_VALUE;
   const double alpha = 2.0 / (period + 1.0);
   return price[i] * alpha + ema[i - 1] * (1.0 - alpha);
  }

//+------------------------------------------------------------------+
//| Kaufman Efficiency Ratio: net move / path length over `period`.  |
//+------------------------------------------------------------------+
double Metrics_ER(const double &close[], const int i, const int period)
  {
   if(period < 1 || i < period)
      return EMPTY_VALUE;
   const double netMove = MathAbs(close[i] - close[i - period]);
   double path = 0.0;
   for(int k = i - period + 1; k <= i; k++)
      path += MathAbs(close[k] - close[k - 1]);
   if(path <= 0.0)
      return 0.0;   // flat price: no directional efficiency
   return netMove / path;
  }

//+------------------------------------------------------------------+
//| Choppiness Index: 100*log10(sum TR / (HH - LL)) / log10(period). |
//+------------------------------------------------------------------+
double Metrics_CHOP(const double &high[], const double &low[], const double &close[], const int i, const int period)
  {
   if(period < 2 || i < period)
      return EMPTY_VALUE;
   double sumTR = 0.0;
   double highest = high[i];
   double lowest  = low[i];
   for(int k = i - period + 1; k <= i; k++)
     {
      sumTR += Metrics_TrueRange(high, low, close, k);
      highest = MathMax(highest, high[k]);
      lowest  = MathMin(lowest, low[k]);
     }
   const double range = highest - lowest;
   if(range <= 0.0 || sumTR <= 0.0)
      return EMPTY_VALUE;
   return 100.0 * MathLog10(sumTR / range) / MathLog10((double)period);
  }

//+------------------------------------------------------------------+
//| ATR percentile: share (0-100) of the previous lookback-1 ATR     |
//| values that are strictly below the current ATR.                  |
//| One pass over the contiguous ATR history (no sorting).           |
//+------------------------------------------------------------------+
double Metrics_ATRPercentile(const double &atr[], const int i, const int lookback)
  {
   if(lookback < 2 || i - lookback + 1 < 0)
      return EMPTY_VALUE;
   const double current = atr[i];
   if(Metrics_IsEmpty(current))
      return EMPTY_VALUE;
   const int first = i - lookback + 1;
   if(Metrics_IsEmpty(atr[first]))   // ATR is contiguous: the oldest value decides
      return EMPTY_VALUE;
   int below = 0;
   for(int k = first; k < i; k++)
     {
      if(atr[k] < current)
         below++;
     }
   return 100.0 * below / (lookback - 1);
  }

//+------------------------------------------------------------------+
//| Slope: (EMA[i] - EMA[i-lag]) / ATR[i].                           |
//| Valid only once the EMA has settled SENTRY_EMA_SETTLE_BARS past  |
//| its seed (emaStart + emaPeriod - 1).                             |
//+------------------------------------------------------------------+
double Metrics_Slope(const double &ema[], const double &atr[], const int i, const int lag,
                     const int emaPeriod, const int emaStart)
  {
   if(lag < 1 || i - lag < emaStart + emaPeriod - 1 + SENTRY_EMA_SETTLE_BARS)
      return EMPTY_VALUE;
   if(Metrics_IsEmpty(ema[i]) || Metrics_IsEmpty(ema[i - lag]) || Metrics_IsEmpty(atr[i]) || atr[i] <= 0.0)
      return EMPTY_VALUE;
   return (ema[i] - ema[i - lag]) / atr[i];
  }

//+------------------------------------------------------------------+
//| BarRangeX: (High - Low) / ATR of the same bar.                   |
//+------------------------------------------------------------------+
double Metrics_BarRangeX(const double &high[], const double &low[], const double &atr[], const int i)
  {
   if(Metrics_IsEmpty(atr[i]) || atr[i] <= 0.0)
      return EMPTY_VALUE;
   return (high[i] - low[i]) / atr[i];
  }

//+------------------------------------------------------------------+
//| H1 cache (non-series). Filled by ONE CopyRates call per          |
//| calculation (H1_Update); H1 ER and slope are computed once per   |
//| H1 bar when it is appended. Only CLOSED H1 bars are stored: the  |
//| newest bar returned by CopyRates may still be forming.           |
//+------------------------------------------------------------------+
datetime g_h1Time[];
double   g_h1High[];
double   g_h1Low[];
double   g_h1Close[];
double   g_h1ATR[];
double   g_h1EMA[];
double   g_h1ER[];
double   g_h1Slope[];
int      g_h1Count      = 0;
datetime g_h1LatestOpen = 0;   // open time of the newest H1 bar seen (closed or forming)
int      g_h1Ptr        = -1;  // moving pointer: last H1 bar mapped to a chart bar

void H1_Reset()
  {
   ArrayFree(g_h1Time);
   ArrayFree(g_h1High);
   ArrayFree(g_h1Low);
   ArrayFree(g_h1Close);
   ArrayFree(g_h1ATR);
   ArrayFree(g_h1EMA);
   ArrayFree(g_h1ER);
   ArrayFree(g_h1Slope);
   g_h1Count      = 0;
   g_h1LatestOpen = 0;
   g_h1Ptr        = -1;
  }

void H1_Resize(const int size)
  {
   const int reserve = 256;
   ArrayResize(g_h1Time,  size, reserve);
   ArrayResize(g_h1High,  size, reserve);
   ArrayResize(g_h1Low,   size, reserve);
   ArrayResize(g_h1Close, size, reserve);
   ArrayResize(g_h1ATR,   size, reserve);
   ArrayResize(g_h1EMA,   size, reserve);
   ArrayResize(g_h1ER,    size, reserve);
   ArrayResize(g_h1Slope, size, reserve);
  }

void H1_ComputeMetrics(const int j)
  {
   g_h1ATR[j]   = Metrics_ATR(g_h1High, g_h1Low, g_h1Close, j, InpATRPeriod);
   g_h1EMA[j]   = Metrics_EMA(g_h1Close, g_h1EMA, j, InpEMAPeriod, 0);
   g_h1ER[j]    = Metrics_ER(g_h1Close, j, InpERPeriod);
   g_h1Slope[j] = Metrics_Slope(g_h1EMA, g_h1ATR, j, InpSlopeLag, InpEMAPeriod, 0);
  }

//+------------------------------------------------------------------+
//| One CopyRates call: the first call loads from `chartFrom` minus  |
//| the H1 warm-up, later calls only fetch bars after the cache.     |
//| Returns false while H1 history is not available (e.g. 4401); the |
//| terminal starts loading it and the caller simply returns.        |
//+------------------------------------------------------------------+
bool H1_Update(const datetime chartFrom)
  {
   const datetime from = (g_h1Count > 0)
                         ? (datetime)((long)g_h1Time[g_h1Count - 1] + 1)
                         : (datetime)((long)chartFrom - SENTRY_H1_WARMUP_SECONDS);
   const datetime to = (datetime)((long)TimeCurrent() + SENTRY_H1_COPY_MARGIN_SECONDS);

   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   ResetLastError();
   const int copied = CopyRates(_Symbol, PERIOD_H1, from, to, rates);
   if(copied <= 0)
      return false;

   if(rates[copied - 1].time > g_h1LatestOpen)
      g_h1LatestOpen = rates[copied - 1].time;

   const int closedCount = copied - 1;   // newest copied bar may still be forming
   if(closedCount <= 0)
      return true;

   const int oldCount = g_h1Count;
   H1_Resize(oldCount + closedCount);
   for(int k = 0; k < closedCount; k++)
     {
      const int j = oldCount + k;
      g_h1Time[j]  = rates[k].time;
      g_h1High[j]  = rates[k].high;
      g_h1Low[j]   = rates[k].low;
      g_h1Close[j] = rates[k].close;
      H1_ComputeMetrics(j);
     }
   g_h1Count = oldCount + closedCount;
   return true;
  }

//+------------------------------------------------------------------+
//| True when every H1 bar closing at or before chartCloseTime is    |
//| final: a newer H1 bar has already been seen.                     |
//+------------------------------------------------------------------+
bool H1_IsReadyFor(const datetime chartCloseTime)
  {
   const long hourFloor = ((long)chartCloseTime / SENTRY_H1_SECONDS) * SENTRY_H1_SECONDS;
   return ((long)g_h1LatestOpen >= hourFloor);
  }

//+------------------------------------------------------------------+
//| Binary search fallback: last cached H1 bar with open <= limit.   |
//+------------------------------------------------------------------+
int H1_SearchLastOpenAtOrBefore(const long limit)
  {
   int lo = 0;
   int hi = g_h1Count - 1;
   int found = -1;
   while(lo <= hi)
     {
      const int mid = (lo + hi) / 2;
      if((long)g_h1Time[mid] <= limit)
        {
         found = mid;
         lo = mid + 1;
        }
      else
         hi = mid - 1;
     }
   return found;
  }

//+------------------------------------------------------------------+
//| Index of the last cached H1 bar whose close time <= t, or -1.    |
//| Moving pointer: amortised O(1) when chart bars arrive in order.  |
//+------------------------------------------------------------------+
int H1_LastClosedIndex(const datetime t)
  {
   const long limit = (long)t - SENTRY_H1_SECONDS;   // open time + 1h <= t
   if(g_h1Ptr >= g_h1Count || (g_h1Ptr >= 0 && (long)g_h1Time[g_h1Ptr] > limit))
      g_h1Ptr = H1_SearchLastOpenAtOrBefore(limit);   // time went backwards
   while(g_h1Ptr + 1 < g_h1Count && (long)g_h1Time[g_h1Ptr + 1] <= limit)
      g_h1Ptr++;
   return g_h1Ptr;
  }

//+------------------------------------------------------------------+
//| H1 bias for a chart bar closing at chartCloseTime (no lookahead: |
//| only the last H1 bar whose close time <= chartCloseTime).        |
//+------------------------------------------------------------------+
bool Metrics_H1Bias(const datetime chartCloseTime, double &h1ER, double &h1Slope)
  {
   h1ER    = EMPTY_VALUE;
   h1Slope = EMPTY_VALUE;
   const int j = H1_LastClosedIndex(chartCloseTime);
   if(j < 0)
      return false;
   h1ER    = g_h1ER[j];
   h1Slope = g_h1Slope[j];
   return (!Metrics_IsEmpty(h1ER) && !Metrics_IsEmpty(h1Slope));
  }

#endif // SENTRY_METRICS_MQH
//+------------------------------------------------------------------+
