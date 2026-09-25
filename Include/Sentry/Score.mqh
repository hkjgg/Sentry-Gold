//+------------------------------------------------------------------+
//| Score.mqh — factors, weighted score, vetoes, state, hint         |
//| Every factor is binary (met / not met).                          |
//+------------------------------------------------------------------+
#ifndef SENTRY_SCORE_MQH
#define SENTRY_SCORE_MQH

#include "Config.mqh"

struct SentryFactors
  {
   bool              regimeClear;
   bool              volatilityHealthy;
   bool              inSession;
   bool              h1Aligned;
   bool              spreadOk;
   bool              newsAvailable;    // false: news factor is not evaluated
   bool              farFromNews;
  };

//+------------------------------------------------------------------+
//| Regime clarity: published regime is TREND or RANGE and the raw   |
//| regime of the bar agrees with it.                                |
//+------------------------------------------------------------------+
bool Score_RegimeClear(const ENUM_SENTRY_REGIME published, const ENUM_SENTRY_REGIME raw)
  {
   if(published == SENTRY_REGIME_CHOP || published == SENTRY_REGIME_SPIKE)
      return false;
   return (raw == published);
  }

//+------------------------------------------------------------------+
//| Healthy volatility: ATR percentile inside [min, max].            |
//+------------------------------------------------------------------+
bool Score_VolatilityHealthy(const double atrPct)
  {
   return (atrPct >= InpVolHealthyMin && atrPct <= InpVolHealthyMax);
  }

//+------------------------------------------------------------------+
//| H1 alignment: TREND_UP needs H1 trending up, TREND_DOWN needs H1 |
//| trending down, RANGE needs H1 not trending (same trend           |
//| thresholds as the chart); CHOP and SPIKE are never aligned.      |
//+------------------------------------------------------------------+
bool Score_H1Aligned(const ENUM_SENTRY_REGIME published, const double h1ER, const double h1Slope)
  {
   const bool h1Trending = (h1ER > InpTrendERMin && MathAbs(h1Slope) > InpTrendSlopeMin);
   switch(published)
     {
      case SENTRY_REGIME_TREND_UP:
         return (h1Trending && h1Slope > 0.0);
      case SENTRY_REGIME_TREND_DOWN:
         return (h1Trending && h1Slope < 0.0);
      case SENTRY_REGIME_RANGE:
         return !h1Trending;
      default:
         return false;
     }
  }

//+------------------------------------------------------------------+
//| Spread ok: bar spread (price units) <= max spread.               |
//+------------------------------------------------------------------+
bool Score_SpreadOk(const double spreadPrice)
  {
   return (spreadPrice <= InpMaxSpreadPrice);
  }

//+------------------------------------------------------------------+
//| Weighted score: 100 * met weights / evaluated weights, rounded.  |
//| When news is unavailable its weight is left out of both sums.    |
//+------------------------------------------------------------------+
int Score_Weighted(const SentryFactors &f)
  {
   int evaluated = InpWeightRegime + InpWeightVolatility + InpWeightSession + InpWeightH1 + InpWeightSpread;
   int met = 0;
   if(f.regimeClear)
      met += InpWeightRegime;
   if(f.volatilityHealthy)
      met += InpWeightVolatility;
   if(f.inSession)
      met += InpWeightSession;
   if(f.h1Aligned)
      met += InpWeightH1;
   if(f.spreadOk)
      met += InpWeightSpread;
   if(f.newsAvailable)
     {
      evaluated += InpWeightNews;
      if(f.farFromNews)
         met += InpWeightNews;
     }
   if(evaluated <= 0)
      return 0;
   return (int)MathRound(100.0 * met / evaluated);
  }

//+------------------------------------------------------------------+
//| Veto mask: news inside the veto window, spread above max,        |
//| published SPIKE, published CHOP.                                 |
//+------------------------------------------------------------------+
int Score_VetoMask(const bool newsInVetoWindow, const bool spreadOk, const ENUM_SENTRY_REGIME published)
  {
   int mask = 0;
   if(newsInVetoWindow)
      mask |= SENTRY_VETO_NEWS;
   if(!spreadOk)
      mask |= SENTRY_VETO_SPREAD;
   if(published == SENTRY_REGIME_SPIKE)
      mask |= SENTRY_VETO_SPIKE;
   if(published == SENTRY_REGIME_CHOP)
      mask |= SENTRY_VETO_CHOP;
   return mask;
  }

//+------------------------------------------------------------------+
//| Any veto caps the score at InpVetoScoreCap.                      |
//+------------------------------------------------------------------+
int Score_ApplyVetoCap(const int score, const int vetoMask)
  {
   if(vetoMask != 0 && score > InpVetoScoreCap)
      return InpVetoScoreCap;
   return score;
  }

//+------------------------------------------------------------------+
//| State: GO >= InpGoScore, CAUTION >= InpCautionScore, else        |
//| STAND_ASIDE.                                                     |
//+------------------------------------------------------------------+
ENUM_SENTRY_STATE Score_State(const int score)
  {
   if(score >= InpGoScore)
      return SENTRY_STATE_GO;
   if(score >= InpCautionScore)
      return SENTRY_STATE_CAUTION;
   return SENTRY_STATE_STAND_ASIDE;
  }

//+------------------------------------------------------------------+
//| Strategy hint: TREND -> continuation, RANGE -> mean reversion,   |
//| otherwise none.                                                  |
//+------------------------------------------------------------------+
ENUM_SENTRY_HINT Score_StrategyHint(const ENUM_SENTRY_REGIME published)
  {
   if(published == SENTRY_REGIME_TREND_UP || published == SENTRY_REGIME_TREND_DOWN)
      return SENTRY_HINT_CONTINUATION;
   if(published == SENTRY_REGIME_RANGE)
      return SENTRY_HINT_MEAN_REVERSION;
   return SENTRY_HINT_NONE;
  }

#endif // SENTRY_SCORE_MQH
//+------------------------------------------------------------------+
