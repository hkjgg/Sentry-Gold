//+------------------------------------------------------------------+
//| News.mqh — USD high-impact events from the MQL5 economic calendar|
//| Loaded once for the calculated range into a sorted array of      |
//| event times (server time), refreshed at most once per hour. Disabled silently (logged once) in the    |
//| Strategy Tester. When the calendar is unavailable at startup the |
//| main file prints one warning (see SENTRY.mq5).                   |
//+------------------------------------------------------------------+
#ifndef SENTRY_NEWS_MQH
#define SENTRY_NEWS_MQH

#include "Config.mqh"

bool     g_newsUsable      = false;   // cache holds a successful load
bool     g_newsAttempted   = false;
bool     g_newsLogged      = false;
ulong    g_newsLastAttempt = 0;       // GetTickCount64() of the last load attempt
datetime g_newsFrom        = 0;       // start of the cached range
long     g_newsTimes[];               // sorted event times
int      g_newsCount       = 0;
int      g_newsLastError   = 0;       // last calendar error code (0 = none)

void News_LogOnce(const string message)
  {
   if(g_newsLogged)
      return;
   g_newsLogged = true;
   Print(message);
  }

bool News_IsEnabled()
  {
   return (InpUseNews && MQLInfoInteger(MQL_TESTER) == 0);
  }

void News_Init()
  {
   g_newsUsable      = false;
   g_newsAttempted   = false;
   g_newsLastAttempt = 0;
   g_newsFrom        = 0;
   g_newsCount       = 0;
   g_newsLastError   = 0;
   ArrayFree(g_newsTimes);
   if(InpUseNews && MQLInfoInteger(MQL_TESTER) != 0)
      News_LogOnce(SENTRY_NAME + ": economic calendar is not available in the Strategy Tester; news veto and news factor disabled.");
  }

//+------------------------------------------------------------------+
//| Available = enabled and at least one successful calendar load.   |
//+------------------------------------------------------------------+
bool News_IsAvailable()
  {
   return (News_IsEnabled() && g_newsUsable);
  }

int News_LowerBoundLong(const long &values[], const int count, const long value)
  {
   int lo = 0;
   int hi = count;
   while(lo < hi)
     {
      const int mid = (lo + hi) / 2;
      if(values[mid] < value)
         lo = mid + 1;
      else
         hi = mid;
     }
   return lo;
  }

bool News_ContainsId(const ulong &ids[], const int count, const ulong id)
  {
   int lo = 0;
   int hi = count;
   while(lo < hi)
     {
      const int mid = (lo + hi) / 2;
      if(ids[mid] < id)
         lo = mid + 1;
      else
         hi = mid;
     }
   return (lo < count && ids[lo] == id);
  }

//+------------------------------------------------------------------+
//| Loads USD high-impact events with an exact time since `from`.     |
//+------------------------------------------------------------------+
bool News_Load(const datetime from)
  {
   MqlCalendarEvent events[];
   ResetLastError();
   const int eventCount = CalendarEventByCurrency(SENTRY_NEWS_CURRENCY, events);
   if(eventCount <= 0)
     {
      g_newsLastError = GetLastError();
      return false;
     }

   ulong highIds[];
   ArrayResize(highIds, eventCount);
   int highCount = 0;
   for(int k = 0; k < eventCount; k++)
     {
      if(events[k].importance == CALENDAR_IMPORTANCE_HIGH && events[k].time_mode == CALENDAR_TIMEMODE_DATETIME)
        {
         highIds[highCount] = events[k].id;
         highCount++;
        }
     }
   ArrayResize(highIds, highCount);
   if(highCount > 1)
      ArraySort(highIds);

   MqlCalendarValue values[];
   ResetLastError();
   if(!CalendarValueHistory(values, from, (datetime)0, NULL, SENTRY_NEWS_CURRENCY))
     {
      g_newsLastError = GetLastError();
      return false;
     }

   const int valueCount = ArraySize(values);
   long times[];
   ArrayResize(times, valueCount);
   int timeCount = 0;
   for(int v = 0; v < valueCount; v++)
     {
      if(News_ContainsId(highIds, highCount, values[v].event_id))
        {
         times[timeCount] = (long)values[v].time;
         timeCount++;
        }
     }
   ArrayResize(times, timeCount);
   if(timeCount > 1)
      ArraySort(times);

   ArrayFree(g_newsTimes);
   if(timeCount > 0)
      ArrayCopy(g_newsTimes, times);
   g_newsCount     = timeCount;
   g_newsLastError = 0;
   return true;
  }

//+------------------------------------------------------------------+
//| Startup readiness probe: USD events are known and the last week  |
//| of USD values can be read.                                       |
//+------------------------------------------------------------------+
bool News_Probe()
  {
   if(!News_IsEnabled())
      return false;
   MqlCalendarEvent events[];
   ResetLastError();
   if(CalendarEventByCurrency(SENTRY_NEWS_CURRENCY, events) <= 0)
     {
      g_newsLastError = GetLastError();
      return false;
     }
   MqlCalendarValue values[];
   const datetime from = (datetime)((long)TimeTradeServer() - 7 * SENTRY_SECONDS_PER_DAY);
   ResetLastError();
   if(!CalendarValueHistory(values, from, (datetime)0, NULL, SENTRY_NEWS_CURRENCY) || ArraySize(values) == 0)
     {
      g_newsLastError = GetLastError();
      return false;
     }
   g_newsLastError = 0;
   return true;
  }

//+------------------------------------------------------------------+
//| Reloads the cache when never loaded, when older history is       |
//| needed, or when the last attempt is at least one hour old.       |
//+------------------------------------------------------------------+
void News_Refresh(const datetime from)
  {
   if(!News_IsEnabled())
      return;
   const ulong now = GetTickCount64();
   const bool needsOlder = (g_newsUsable && from < g_newsFrom);
   if(g_newsAttempted && !needsOlder && now - g_newsLastAttempt < SENTRY_NEWS_REFRESH_MS)
      return;

   g_newsAttempted   = true;
   g_newsLastAttempt = now;
   if(News_Load(from))
     {
      g_newsUsable = true;
      g_newsFrom   = from;
     }
   // On failure a previous successful cache is kept as is.
  }

//+------------------------------------------------------------------+
//| True if an event falls in [openTime - minutes, closeTime + minutes]. |
//| `cursor` is a moving pointer owned by the caller (one per window |
//| size): amortised O(1) when bars are visited in time order; it    |
//| repositions itself by binary search if time goes backwards or    |
//| the cache was reloaded.                                          |
//+------------------------------------------------------------------+
bool News_EventWithin(const datetime openTime, const datetime closeTime, const int minutes, int &cursor)
  {
   if(!News_IsAvailable() || g_newsCount == 0)
      return false;
   const long windowStart = (long)openTime - (long)minutes * 60;
   const long windowEnd   = (long)closeTime + (long)minutes * 60;
   if(cursor < 0 || cursor > g_newsCount || (cursor > 0 && g_newsTimes[cursor - 1] >= windowStart))
      cursor = News_LowerBoundLong(g_newsTimes, g_newsCount, windowStart);
   while(cursor < g_newsCount && g_newsTimes[cursor] < windowStart)
      cursor++;
   return (cursor < g_newsCount && g_newsTimes[cursor] <= windowEnd);
  }

#endif // SENTRY_NEWS_MQH
//+------------------------------------------------------------------+
