//+------------------------------------------------------------------+
//| SENTRY_BufferCheck.mq5 — loads SENTRY via iCustom and prints the |
//| last N closed bars of buffers 0-7 (oldest first).                |
//| Copy to MQL5\Scripts\ (or keep the repo under MQL5\) and set     |
//| InpIndicatorPath relative to MQL5\Indicators\.                   |
//+------------------------------------------------------------------+
#property copyright   "SENTRY"
#property version     "0.10"
#property description "Prints the last closed bars of SENTRY buffers 0-7."
#property script_show_inputs

input string          InpSymbol        = "XAUUSD";         // Symbol (empty = chart symbol)
input ENUM_TIMEFRAMES InpTimeframe     = PERIOD_M15;       // Timeframe
input string          InpIndicatorPath = "SENTRY\\SENTRY"; // Path under MQL5\Indicators\ (no extension)
input int             InpBarsToPrint   = 20;               // Closed bars to print
input int             InpWaitSeconds   = 60;               // Max wait for the indicator to calculate

const int BUFFER_COUNT = 8;
const int VETO_NEWS   = 1;   // mirrors SENTRY_VETO_* in Include/Sentry/Config.mqh
const int VETO_SPREAD = 2;
const int VETO_SPIKE  = 4;
const int VETO_CHOP   = 8;
const string REGIME_NAMES[] = {"RANGE", "TREND_UP", "TREND_DOWN", "CHOP", "SPIKE"};
const string STATE_NAMES[]  = {"STAND_ASIDE", "CAUTION", "GO"};
const string HINT_NAMES[]   = {"none", "continuation", "mean_reversion"};

//+------------------------------------------------------------------+
//| Name lookup for an enum-valued buffer ("-" when empty/unknown).  |
//+------------------------------------------------------------------+
string EnumName(const string &names[], const double v)
  {
   if(v == EMPTY_VALUE)
      return "-";
   const int idx = (int)v;
   if(idx < 0 || idx >= ArraySize(names))
      return "?";
   return names[idx];
  }

string VetoText(const double v)
  {
   if(v == EMPTY_VALUE)
      return "-";
   const int mask = (int)v;
   if(mask == 0)
      return "0";
   string text = IntegerToString(mask) + ":";
   if((mask & VETO_NEWS) != 0)
      text += "N";
   if((mask & VETO_SPREAD) != 0)
      text += "S";
   if((mask & VETO_SPIKE) != 0)
      text += "K";
   if((mask & VETO_CHOP) != 0)
      text += "C";
   return text;
  }

string Num(const double v, const int digits)
  {
   if(v == EMPTY_VALUE)
      return "EMPTY";
   return DoubleToString(v, digits);
  }

//+------------------------------------------------------------------+
void OnStart()
  {
   const string symbol = (InpSymbol == "") ? _Symbol : InpSymbol;
   if(!SymbolSelect(symbol, true))
     {
      PrintFormat("BufferCheck: symbol %s not found (error %d).", symbol, GetLastError());
      return;
     }
   if(InpBarsToPrint < 1)
     {
      Print("BufferCheck: InpBarsToPrint must be >= 1.");
      return;
     }

   const int handle = iCustom(symbol, InpTimeframe, InpIndicatorPath);
   if(handle == INVALID_HANDLE)
     {
      PrintFormat("BufferCheck: iCustom(%s) failed (error %d).", InpIndicatorPath, GetLastError());
      return;
     }

   const int   waitSeconds = (InpWaitSeconds < 1) ? 1 : InpWaitSeconds;
   const ulong waitMs      = (ulong)waitSeconds * 1000;
   const ulong started     = GetTickCount64();
   while(BarsCalculated(handle) <= 0 && !IsStopped() && GetTickCount64() - started < waitMs)
      Sleep(100);
   if(BarsCalculated(handle) <= 0)
     {
      PrintFormat("BufferCheck: SENTRY did not calculate within %d s.", waitSeconds);
      IndicatorRelease(handle);
      return;
     }

   //--- series order: [0] = last closed bar (shift 1)
   double table[][8];
   ArrayResize(table, InpBarsToPrint);
   double column[];
   ArraySetAsSeries(column, true);
   for(int b = 0; b < BUFFER_COUNT; b++)
     {
      const int got = CopyBuffer(handle, b, 1, InpBarsToPrint, column);
      if(got != InpBarsToPrint)
        {
         PrintFormat("BufferCheck: CopyBuffer(%d) returned %d (error %d).", b, got, GetLastError());
         IndicatorRelease(handle);
         return;
        }
      for(int r = 0; r < InpBarsToPrint; r++)
         table[r][b] = column[r];
     }

   datetime times[];
   ArraySetAsSeries(times, true);
   if(CopyTime(symbol, InpTimeframe, 1, InpBarsToPrint, times) != InpBarsToPrint)
     {
      PrintFormat("BufferCheck: CopyTime failed (error %d).", GetLastError());
      IndicatorRelease(handle);
      return;
     }

   PrintFormat("BufferCheck: %s %s, last %d closed bars (oldest first). Veto: N=news S=spread K=spike C=chop",
               symbol, EnumToString(InpTimeframe), InpBarsToPrint);
   PrintFormat("%-17s %-11s %6s %-12s %-15s %-7s %8s %8s %8s",
               "Time", "Regime", "Score", "State", "Hint", "Veto", "ER", "CHOP", "ATRpct");
   for(int r = InpBarsToPrint - 1; r >= 0; r--)
     {
      PrintFormat("%-17s %-11s %6s %-12s %-15s %-7s %8s %8s %8s",
                  TimeToString(times[r], TIME_DATE | TIME_MINUTES),
                  EnumName(REGIME_NAMES, table[r][0]),
                  Num(table[r][1], 0),
                  EnumName(STATE_NAMES, table[r][2]),
                  EnumName(HINT_NAMES, table[r][3]),
                  VetoText(table[r][4]),
                  Num(table[r][5], 3),
                  Num(table[r][6], 2),
                  Num(table[r][7], 1));
     }
   IndicatorRelease(handle);
  }
//+------------------------------------------------------------------+
