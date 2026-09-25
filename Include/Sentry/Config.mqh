//+------------------------------------------------------------------+
//| Config.mqh — SENTRY inputs, enums, constants                     |
//| Every threshold is an input with a documented default            |
//| (see README.md, "Inputs").                                       |
//+------------------------------------------------------------------+
#ifndef SENTRY_CONFIG_MQH
#define SENTRY_CONFIG_MQH

//--- Regime (buffer 0)
enum ENUM_SENTRY_REGIME
  {
   SENTRY_REGIME_RANGE      = 0,
   SENTRY_REGIME_TREND_UP   = 1,
   SENTRY_REGIME_TREND_DOWN = 2,
   SENTRY_REGIME_CHOP       = 3,
   SENTRY_REGIME_SPIKE      = 4
  };

//--- State (buffer 2)
enum ENUM_SENTRY_STATE
  {
   SENTRY_STATE_STAND_ASIDE = 0,
   SENTRY_STATE_CAUTION     = 1,
   SENTRY_STATE_GO          = 2
  };

//--- Strategy hint (buffer 3)
enum ENUM_SENTRY_HINT
  {
   SENTRY_HINT_NONE           = 0,
   SENTRY_HINT_CONTINUATION   = 1,
   SENTRY_HINT_MEAN_REVERSION = 2
  };

//--- Session time mode
enum ENUM_SENTRY_SESSION_TIME_MODE
  {
   SENTRY_SESSION_TIME_AUTO   = 0,   // AUTO: server GMT+2 / GMT+3 (US DST), local exchange hours
   SENTRY_SESSION_TIME_MANUAL = 1    // MANUAL: fixed server offset, GMT hours
  };

//--- Veto bit flags (buffer 4)
const int SENTRY_VETO_NEWS   = 1;   // bit0
const int SENTRY_VETO_SPREAD = 2;   // bit1
const int SENTRY_VETO_SPIKE  = 4;   // bit2
const int SENTRY_VETO_CHOP   = 8;   // bit3

//--- Buffer indices (0-7 are INDICATOR_DATA, readable via iCustom)
const int SENTRY_BUF_REGIME     = 0;
const int SENTRY_BUF_SCORE      = 1;
const int SENTRY_BUF_STATE      = 2;
const int SENTRY_BUF_HINT       = 3;
const int SENTRY_BUF_VETO       = 4;
const int SENTRY_BUF_ER         = 5;
const int SENTRY_BUF_CHOP       = 6;
const int SENTRY_BUF_ATRPCT     = 7;
//--- INDICATOR_CALCULATIONS (internal state, not part of the public contract)
const int SENTRY_BUF_ATR        = 8;
const int SENTRY_BUF_EMA        = 9;
const int SENTRY_BUF_RAW_REGIME = 10;
const int SENTRY_DATA_BUFFERS   = 8;

//--- Engine constants (not trading thresholds)
const int    SENTRY_EMA_SETTLE_BARS         = 100;        // EMA bars discarded after its SMA seed
const int    SENTRY_H1_SECONDS              = 3600;
const long   SENTRY_SECONDS_PER_HOUR        = 3600;
const long   SENTRY_SECONDS_PER_DAY         = 86400;
const int    SENTRY_AUTO_WINTER_OFFSET_HOURS = 2;         // AUTO server offset outside US DST
const int    SENTRY_AUTO_SUMMER_OFFSET_HOURS = 3;         // AUTO server offset during US DST
const long   SENTRY_LIVE_OFFSET_TOLERANCE_SECONDS = 900;  // live offset check tolerance (clock drift)
const int    SENTRY_TIMER_SECONDS           = 2;          // retry timer: calendar probe / H1 history refresh
const ulong  SENTRY_CALENDAR_WAIT_MS        = 30000;      // startup wait before computing without news
const ulong  SENTRY_H1_RETRY_MS             = 60000;      // timer refreshes while H1 history loads (then ticks only)
const long   SENTRY_H1_WARMUP_SECONDS       = 21 * 86400; // H1 history loaded before the first chart bar
const long   SENTRY_H1_COPY_MARGIN_SECONDS  = 86400;      // upper bound of the H1 copy range past TimeCurrent()
const ulong  SENTRY_NEWS_REFRESH_MS         = 3600000;    // calendar cache refreshed at most hourly
const string SENTRY_NEWS_CURRENCY           = "USD";
const string SENTRY_NAME                    = "SENTRY";

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "Calculation"
input int    InpMaxBars             = 5000;   // Max closed bars computed (older bars stay empty)

input group "Metrics"
input int    InpERPeriod            = 20;     // Efficiency Ratio period
input int    InpChopPeriod          = 14;     // Choppiness Index period
input int    InpATRPeriod           = 14;     // ATR period
input int    InpATRPctLookback      = 500;    // ATR percentile lookback (bars, incl. current)
input int    InpEMAPeriod           = 50;     // EMA period used by Slope
input int    InpSlopeLag            = 5;      // Slope lag (bars)

input group "Regime"
input double InpSpikeATRPct         = 95.0;   // SPIKE: ATR percentile above
input double InpSpikeBarRangeX      = 2.5;    // SPIKE: bar range / ATR above
input double InpChopIndexMin        = 61.8;   // CHOP: Choppiness Index above
input double InpChopERMax           = 0.25;   // CHOP: Efficiency Ratio below
input double InpTrendERMin          = 0.35;   // TREND: Efficiency Ratio above
input double InpTrendSlopeMin       = 0.15;   // TREND: |Slope| above
input int    InpAntiFlickerBars     = 2;      // Anti-flicker: bars a new regime must hold

input group "Score"
input int    InpWeightRegime        = 35;     // Weight: regime clarity
input int    InpWeightVolatility    = 20;     // Weight: volatility in healthy zone
input int    InpWeightSession       = 15;     // Weight: London / New York session
input int    InpWeightH1            = 15;     // Weight: H1 alignment
input int    InpWeightSpread        = 10;     // Weight: spread <= max
input int    InpWeightNews          = 5;      // Weight: distance from news
input double InpRangeClarityERMax   = 0.25;   // Regime clarity for RANGE: ER at or below
input double InpVolHealthyMin       = 30.0;   // Healthy volatility: ATR percentile from
input double InpVolHealthyMax       = 85.0;   // Healthy volatility: ATR percentile to
input int    InpVetoScoreCap        = 25;     // Score cap when any veto is active
input int    InpGoScore             = 70;     // GO when score >=
input int    InpCautionScore        = 40;     // CAUTION when score >= (else STAND ASIDE)

input group "Spread"
input double InpMaxSpreadPrice      = 0.50;   // Max spread in price units (USD for XAUUSD)

input group "Sessions"
input ENUM_SENTRY_SESSION_TIME_MODE InpSessionTimeMode = SENTRY_SESSION_TIME_AUTO; // Session time mode
input int    InpLondonStartLocal    = 8;      // AUTO: London start hour (Europe/London local)
input int    InpLondonEndLocal      = 17;     // AUTO: London end hour (Europe/London local, exclusive)
input int    InpNewYorkStartLocal   = 8;      // AUTO: New York start hour (America/New_York local)
input int    InpNewYorkEndLocal     = 17;     // AUTO: New York end hour (America/New_York local, exclusive)
input int    InpServerGMTOffset     = 2;      // MANUAL: broker server GMT offset (hours)
input int    InpLondonStartGMT      = 7;      // MANUAL: London start hour (GMT)
input int    InpLondonEndGMT        = 16;     // MANUAL: London end hour (GMT, exclusive)
input int    InpNewYorkStartGMT     = 12;     // MANUAL: New York start hour (GMT)
input int    InpNewYorkEndGMT       = 21;     // MANUAL: New York end hour (GMT, exclusive)

input group "News (USD high impact)"
input bool   InpUseNews             = true;   // Use economic calendar
input int    InpNewsVetoMinutes     = 15;     // Veto window around an event (± minutes)
input int    InpNewsDistanceMinutes = 60;     // "Distance from news" factor window (± minutes)
input int    InpPostNewsBufferMin   = 15;     // Come back at: minutes after the event (used from the Come-back stage)

//+------------------------------------------------------------------+
//| Rejects inputs that would make the engine meaningless.            |
//+------------------------------------------------------------------+
bool Config_IsHour(const int hour)
  {
   return (hour >= 0 && hour <= 23);
  }

bool Config_Validate()
  {
   string problem = "";
   if(InpMaxBars < 1)
      problem = "MaxBars must be >= 1";
   else if(InpERPeriod < 1 || InpChopPeriod < 2 || InpATRPeriod < 1 || InpEMAPeriod < 1 || InpSlopeLag < 1)
      problem = "metric periods must be >= 1 (Choppiness period >= 2)";
   else if(InpATRPctLookback < 2)
      problem = "ATR percentile lookback must be >= 2";
   else if(InpAntiFlickerBars < 1)
      problem = "anti-flicker bars must be >= 1";
   else if(InpWeightRegime < 0 || InpWeightVolatility < 0 || InpWeightSession < 0 ||
           InpWeightH1 < 0 || InpWeightSpread < 0 || InpWeightNews < 0)
      problem = "score weights must be >= 0";
   else if(InpWeightRegime + InpWeightVolatility + InpWeightSession + InpWeightH1 + InpWeightSpread <= 0)
      problem = "at least one non-news score weight must be > 0";
   else if(InpVolHealthyMin > InpVolHealthyMax)
      problem = "healthy volatility range is inverted";
   else if(InpCautionScore > InpGoScore)
      problem = "CAUTION score must be <= GO score";
   else if(!Config_IsHour(InpLondonStartGMT) || !Config_IsHour(InpLondonEndGMT) ||
           !Config_IsHour(InpNewYorkStartGMT) || !Config_IsHour(InpNewYorkEndGMT) ||
           !Config_IsHour(InpLondonStartLocal) || !Config_IsHour(InpLondonEndLocal) ||
           !Config_IsHour(InpNewYorkStartLocal) || !Config_IsHour(InpNewYorkEndLocal))
      problem = "session hours must be 0-23";
   else if(InpServerGMTOffset < -12 || InpServerGMTOffset > 14)
      problem = "server GMT offset must be between -12 and +14";
   else if(InpNewsVetoMinutes < 0 || InpNewsDistanceMinutes < 0 || InpPostNewsBufferMin < 0)
      problem = "news windows must be >= 0";
   else if(InpRangeClarityERMax < 0.0)
      problem = "RANGE clarity ER threshold must be >= 0";
   else if(InpMaxSpreadPrice < 0.0)
      problem = "max spread must be >= 0";

   if(problem == "")
      return true;
   Print(SENTRY_NAME, ": invalid inputs: ", problem);
   return false;
  }

#endif // SENTRY_CONFIG_MQH
//+------------------------------------------------------------------+
