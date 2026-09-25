//+------------------------------------------------------------------+
//| Sessions.mqh — bar close time and London / New York membership   |
//|                                                                  |
//| AUTO (default): server offset is GMT+2, or GMT+3 during US DST,  |
//| computed per bar; sessions are defined in local exchange time    |
//| (Europe/London and America/New_York, each with its own DST).     |
//| MANUAL: fixed InpServerGMTOffset and session hours in GMT.       |
//+------------------------------------------------------------------+
#ifndef SENTRY_SESSIONS_MQH
#define SENTRY_SESSIONS_MQH

#include "Config.mqh"

//--- DST boundaries (UTC) cached for one calendar year
int      g_dstYear              = 0;
datetime g_usDstStart           = 0;
datetime g_usDstEnd             = 0;
datetime g_ukDstStart           = 0;
datetime g_ukDstEnd             = 0;
bool     g_offsetMismatchLogged = false;

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
//| Calendar helpers                                                 |
//+------------------------------------------------------------------+
datetime Sessions_MakeDate(const int year, const int month, const int day)
  {
   MqlDateTime dt;
   ZeroMemory(dt);
   dt.year = year;
   dt.mon  = month;
   dt.day  = day;
   return StructToTime(dt);
  }

int Sessions_Year(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.year;
  }

int Sessions_DayOfWeek(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.day_of_week;   // 0 = Sunday
  }

//--- 00:00 of the n-th Sunday of a month
datetime Sessions_NthSunday(const int year, const int month, const int n)
  {
   const int firstDow    = Sessions_DayOfWeek(Sessions_MakeDate(year, month, 1));
   const int firstSunday = 1 + (7 - firstDow) % 7;
   return Sessions_MakeDate(year, month, firstSunday + 7 * (n - 1));
  }

//--- 00:00 of the last Sunday of a month
datetime Sessions_LastSunday(const int year, const int month)
  {
   const int  nextMonth = (month == 12) ? 1 : month + 1;
   const int  nextYear  = (month == 12) ? year + 1 : year;
   const long lastDay   = (long)Sessions_MakeDate(nextYear, nextMonth, 1) - SENTRY_SECONDS_PER_DAY;
   const int  lastDow   = Sessions_DayOfWeek((datetime)lastDay);
   return (datetime)(lastDay - (long)lastDow * SENTRY_SECONDS_PER_DAY);
  }

//+------------------------------------------------------------------+
//| US DST: 2nd Sunday of March 02:00 EST (07:00 UTC) to 1st Sunday  |
//| of November 02:00 EDT (06:00 UTC).                               |
//| UK DST: last Sunday of March 01:00 UTC to last Sunday of October |
//| 01:00 UTC.                                                       |
//+------------------------------------------------------------------+
void Sessions_PrepareYear(const int year)
  {
   if(year == g_dstYear)
      return;
   g_dstYear    = year;
   g_usDstStart = (datetime)((long)Sessions_NthSunday(year, 3, 2)  + 7 * SENTRY_SECONDS_PER_HOUR);
   g_usDstEnd   = (datetime)((long)Sessions_NthSunday(year, 11, 1) + 6 * SENTRY_SECONDS_PER_HOUR);
   g_ukDstStart = (datetime)((long)Sessions_LastSunday(year, 3)    + 1 * SENTRY_SECONDS_PER_HOUR);
   g_ukDstEnd   = (datetime)((long)Sessions_LastSunday(year, 10)   + 1 * SENTRY_SECONDS_PER_HOUR);
  }

bool Sessions_IsUSDST(const datetime utc)
  {
   Sessions_PrepareYear(Sessions_Year(utc));
   return (utc >= g_usDstStart && utc < g_usDstEnd);
  }

bool Sessions_IsUKDST(const datetime utc)
  {
   Sessions_PrepareYear(Sessions_Year(utc));
   return (utc >= g_ukDstStart && utc < g_ukDstEnd);
  }

//+------------------------------------------------------------------+
//| Server GMT offset (seconds) at a server time.                    |
//| AUTO: GMT+3 when that server time falls in US DST, else GMT+2.   |
//| (DST switches happen on Sunday, while gold is closed, so every   |
//| trading bar is unambiguous.)                                     |
//+------------------------------------------------------------------+
long Sessions_ServerOffsetSeconds(const datetime serverTime)
  {
   if(InpSessionTimeMode == SENTRY_SESSION_TIME_MANUAL)
      return (long)InpServerGMTOffset * SENTRY_SECONDS_PER_HOUR;
   const long summerOffset = (long)SENTRY_AUTO_SUMMER_OFFSET_HOURS * SENTRY_SECONDS_PER_HOUR;
   if(Sessions_IsUSDST((datetime)((long)serverTime - summerOffset)))
      return summerOffset;
   return (long)SENTRY_AUTO_WINTER_OFFSET_HOURS * SENTRY_SECONDS_PER_HOUR;
  }

datetime Sessions_ServerToUTC(const datetime serverTime)
  {
   return (datetime)((long)serverTime - Sessions_ServerOffsetSeconds(serverTime));
  }

//+------------------------------------------------------------------+
//| Minute of the day (0-1439) of a timestamp.                       |
//+------------------------------------------------------------------+
int Sessions_MinuteOfDay(const datetime t)
  {
   const long secondOfDay = (((long)t % SENTRY_SECONDS_PER_DAY) + SENTRY_SECONDS_PER_DAY) % SENTRY_SECONDS_PER_DAY;
   return (int)(secondOfDay / 60);
  }

//+------------------------------------------------------------------+
//| [startHour, endHour); wraps past midnight if start > end.        |
//+------------------------------------------------------------------+
bool Sessions_InWindow(const int minute, const int startHour, const int endHour)
  {
   const int startMin = startHour * 60;
   const int endMin   = endHour * 60;
   if(startMin == endMin)
      return false;
   if(startMin < endMin)
      return (minute >= startMin && minute < endMin);
   return (minute >= startMin || minute < endMin);
  }

//+------------------------------------------------------------------+
//| London: AUTO 08:00-17:00 Europe/London, MANUAL GMT hours.        |
//+------------------------------------------------------------------+
bool Sessions_InLondon(const datetime serverTime)
  {
   const datetime utc = Sessions_ServerToUTC(serverTime);
   if(InpSessionTimeMode == SENTRY_SESSION_TIME_MANUAL)
      return Sessions_InWindow(Sessions_MinuteOfDay(utc), InpLondonStartGMT, InpLondonEndGMT);
   const long localOffset = Sessions_IsUKDST(utc) ? SENTRY_SECONDS_PER_HOUR : 0;
   const datetime local = (datetime)((long)utc + localOffset);
   return Sessions_InWindow(Sessions_MinuteOfDay(local), InpLondonStartLocal, InpLondonEndLocal);
  }

//+------------------------------------------------------------------+
//| New York: AUTO 08:00-17:00 America/New_York, MANUAL GMT hours.   |
//+------------------------------------------------------------------+
bool Sessions_InNewYork(const datetime serverTime)
  {
   const datetime utc = Sessions_ServerToUTC(serverTime);
   if(InpSessionTimeMode == SENTRY_SESSION_TIME_MANUAL)
      return Sessions_InWindow(Sessions_MinuteOfDay(utc), InpNewYorkStartGMT, InpNewYorkEndGMT);
   const long localOffset = (Sessions_IsUSDST(utc) ? -4 : -5) * SENTRY_SECONDS_PER_HOUR;
   const datetime local = (datetime)((long)utc + localOffset);
   return Sessions_InWindow(Sessions_MinuteOfDay(local), InpNewYorkStartLocal, InpNewYorkEndLocal);
  }

//+------------------------------------------------------------------+
//| A bar is in session when its open time is inside London or NY.   |
//+------------------------------------------------------------------+
bool Sessions_IsActive(const datetime barOpenTime)
  {
   return (Sessions_InLondon(barOpenTime) || Sessions_InNewYork(barOpenTime));
  }

//+------------------------------------------------------------------+
//| Live bars, AUTO only: compares the AUTO offset with              |
//| TimeTradeServer() - TimeGMT() and logs once if they disagree.    |
//+------------------------------------------------------------------+
void Sessions_CheckLiveOffset()
  {
   if(InpSessionTimeMode != SENTRY_SESSION_TIME_AUTO || g_offsetMismatchLogged || MQLInfoInteger(MQL_TESTER) != 0)
      return;
   const datetime serverNow = TimeTradeServer();
   const long expected = Sessions_ServerOffsetSeconds(serverNow);
   const long actual   = (long)serverNow - (long)TimeGMT();
   const long diff     = (actual > expected) ? actual - expected : expected - actual;
   if(diff <= SENTRY_LIVE_OFFSET_TOLERANCE_SECONDS)
      return;
   g_offsetMismatchLogged = true;
   PrintFormat("%s: server GMT offset mismatch: AUTO expects %.2f h, live server reports %.2f h (TimeTradeServer - TimeGMT). " +
               "Session windows may be shifted; check the PC clock or use Session time mode = MANUAL.",
               SENTRY_NAME, (double)expected / 3600.0, (double)actual / 3600.0);
  }

#endif // SENTRY_SESSIONS_MQH
//+------------------------------------------------------------------+
