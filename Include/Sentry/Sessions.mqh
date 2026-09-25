//+------------------------------------------------------------------+
//| Sessions.mqh — bar close time and London / New York membership   |
//| Server time -> GMT uses the fixed InpServerGMTOffset input.       |
//+------------------------------------------------------------------+
#ifndef SENTRY_SESSIONS_MQH
#define SENTRY_SESSIONS_MQH

#include "Config.mqh"

//+------------------------------------------------------------------+
//| Close time of a chart bar that opened at openTime.               |
//| MN1 bars use the calendar month length.                          |
//+------------------------------------------------------------------+
datetime Sessions_BarCloseTime(const datetime openTime)
  {
   if(_Period == PERIOD_MN1)
     {
      MqlDateTime dt;
      TimeToStruct(openTime, dt);
      dt.mon++;
      if(dt.mon > 12)
        {
         dt.mon = 1;
         dt.year++;
        }
      dt.day  = 1;
      dt.hour = 0;
      dt.min  = 0;
      dt.sec  = 0;
      return StructToTime(dt);
     }
   return (datetime)((long)openTime + PeriodSeconds(_Period));
  }

//+------------------------------------------------------------------+
//| Minute of the day (0-1439) in GMT for a server time.             |
//+------------------------------------------------------------------+
int Sessions_MinuteOfDayGMT(const datetime serverTime)
  {
   const long secondsPerDay = 86400;
   const long gmt = (long)serverTime - (long)InpServerGMTOffset * 3600;
   const long secondOfDay = ((gmt % secondsPerDay) + secondsPerDay) % secondsPerDay;
   return (int)(secondOfDay / 60);
  }

//+------------------------------------------------------------------+
//| [startHour, endHour) in GMT; wraps past midnight if start > end. |
//+------------------------------------------------------------------+
bool Sessions_InWindow(const int minuteGMT, const int startHour, const int endHour)
  {
   const int startMin = startHour * 60;
   const int endMin   = endHour * 60;
   if(startMin == endMin)
      return false;
   if(startMin < endMin)
      return (minuteGMT >= startMin && minuteGMT < endMin);
   return (minuteGMT >= startMin || minuteGMT < endMin);
  }

bool Sessions_InLondon(const datetime serverTime)
  {
   return Sessions_InWindow(Sessions_MinuteOfDayGMT(serverTime), InpLondonStartGMT, InpLondonEndGMT);
  }

bool Sessions_InNewYork(const datetime serverTime)
  {
   return Sessions_InWindow(Sessions_MinuteOfDayGMT(serverTime), InpNewYorkStartGMT, InpNewYorkEndGMT);
  }

//+------------------------------------------------------------------+
//| A bar is in session when its open time is inside London or NY.   |
//+------------------------------------------------------------------+
bool Sessions_IsActive(const datetime barOpenTime)
  {
   return (Sessions_InLondon(barOpenTime) || Sessions_InNewYork(barOpenTime));
  }

#endif // SENTRY_SESSIONS_MQH
//+------------------------------------------------------------------+
