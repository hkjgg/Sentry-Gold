//+------------------------------------------------------------------+
//| Regime.mqh — raw classification + anti-flicker publication       |
//| Indexing: NON-series (index 0 = oldest bar).                     |
//+------------------------------------------------------------------+
#ifndef SENTRY_REGIME_MQH
#define SENTRY_REGIME_MQH

#include "Config.mqh"
#include "Metrics.mqh"

//+------------------------------------------------------------------+
//| Raw regime of one closed bar, in priority order:                 |
//| SPIKE > CHOP > TREND_UP / TREND_DOWN > RANGE.                    |
//+------------------------------------------------------------------+
ENUM_SENTRY_REGIME Regime_Classify(const SentryMetrics &m)
  {
   if(m.atrPct > InpSpikeATRPct || m.barRangeX > InpSpikeBarRangeX)
      return SENTRY_REGIME_SPIKE;
   if(m.chop > InpChopIndexMin && m.er < InpChopERMax)
      return SENTRY_REGIME_CHOP;
   if(m.er > InpTrendERMin && MathAbs(m.slope) > InpTrendSlopeMin)
     {
      if(m.slope > 0.0)
         return SENTRY_REGIME_TREND_UP;
      return SENTRY_REGIME_TREND_DOWN;
     }
   return SENTRY_REGIME_RANGE;
  }

//+------------------------------------------------------------------+
//| Anti-flicker: the published regime changes only after the new    |
//| raw regime holds for InpAntiFlickerBars consecutive closed bars; |
//| SPIKE is published immediately. After warm-up (or any invalid    |
//| bar) the first valid bar publishes its raw regime.               |
//| rawRegime[] / published[] hold bars < i.                         |
//+------------------------------------------------------------------+
ENUM_SENTRY_REGIME Regime_Publish(const double &rawRegime[],
                                  const double &published[],
                                  const int i,
                                  const ENUM_SENTRY_REGIME raw)
  {
   if(raw == SENTRY_REGIME_SPIKE)
      return raw;
   if(i < 1 || Metrics_IsEmpty(published[i - 1]))
      return raw;

   const ENUM_SENTRY_REGIME previous = (ENUM_SENTRY_REGIME)(int)published[i - 1];
   if(raw == previous)
      return raw;

   for(int k = 1; k < InpAntiFlickerBars; k++)
     {
      if(i - k < 0 || Metrics_IsEmpty(rawRegime[i - k]) || (int)rawRegime[i - k] != (int)raw)
         return previous;
     }
   return raw;
  }

#endif // SENTRY_REGIME_MQH
//+------------------------------------------------------------------+
