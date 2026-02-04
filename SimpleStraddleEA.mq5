#property copyright ""
#property link      ""
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

enum BufferMode
  {
   BUFFER_POINTS = 0,
   BUFFER_ATR_MULT = 1
  };

input ENUM_TIMEFRAMES signal_tf = PERIOD_H1;
input BufferMode buffer_mode = BUFFER_POINTS;
input double buffer_points = 10.0;
input double atr_buffer_mult = 1.0;
input int atr_period = 14;
input double risk_percent = 1.0;
input double rr = 1.5;
input int expiry_bars = 3;
input int max_spread_points = 30;
input long magic_number = 123456;
input int slippage_points = 5;
input bool news_blackout_enabled = false;
input int blackout_minutes_before = 30;
input int blackout_minutes_after = 30;
input datetime manual_blackout_start = 0;
input datetime manual_blackout_end = 0;

CTrade trade;

datetime last_bar_time = 0;

string TimeframeToString(ENUM_TIMEFRAMES tf)
  {
   return EnumToString(tf);
  }

double GetBufferPoints()
  {
   if(buffer_mode == BUFFER_POINTS)
      return buffer_points * _Point;

   double atr = iATR(_Symbol, signal_tf, atr_period, 1);
   if(atr <= 0.0)
      return -1.0;
   return atr * atr_buffer_mult;
  }

bool HasOpenPositionOrOrder()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) == magic_number)
         return true;
     }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) == magic_number)
         return true;
     }

   return false;
  }

bool IsSpreadOk()
  {
   if(max_spread_points <= 0)
      return true;

   int spread_points = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return spread_points <= max_spread_points;
  }

bool IsManualBlackout()
  {
   if(manual_blackout_start == 0 || manual_blackout_end == 0)
      return false;

   datetime now = TimeCurrent();
   return (now >= manual_blackout_start && now <= manual_blackout_end);
  }

bool IsEconomicCalendarBlackout()
  {
   datetime now = TimeCurrent();
   datetime from = now - blackout_minutes_before * 60;
   datetime to = now + blackout_minutes_after * 60;

   MqlCalendarValue values[];
   int count = CalendarValueHistory(values, from, to);
   if(count <= 0)
      return false;

   for(int i = 0; i < count; i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev))
         continue;
      if(ev.importance == CALENDAR_IMPORTANCE_HIGH)
         return true;
     }

   return false;
  }

bool IsNewsBlackout()
  {
   if(!news_blackout_enabled)
      return false;

   if(IsManualBlackout())
      return true;

   return IsEconomicCalendarBlackout();
  }

double NormalizeVolume(double volume)
  {
   double min_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0)
      return min_vol;

   double normalized = MathFloor(volume / step) * step;
   if(normalized < min_vol)
      normalized = min_vol;
   if(normalized > max_vol)
      normalized = max_vol;
   return normalized;
  }

double CalculateRiskLots(double entry, double sl)
  {
   double risk_amount = AccountInfoDouble(ACCOUNT_BALANCE) * (risk_percent / 100.0);
   double stop_distance = MathAbs(entry - sl);
   if(stop_distance <= 0.0)
      return 0.0;

   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_value <= 0.0 || tick_size <= 0.0)
      return 0.0;

   double risk_per_lot = (stop_distance / tick_size) * tick_value;
   if(risk_per_lot <= 0.0)
      return 0.0;

   double raw_volume = risk_amount / risk_per_lot;
   return NormalizeVolume(raw_volume);
  }

void CancelPendingOrdersByType(ENUM_ORDER_TYPE order_type)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != magic_number)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == order_type)
        {
         ulong ticket = (ulong)OrderGetInteger(ORDER_TICKET);
         trade.OrderDelete(ticket);
        }
     }
  }

void PlaceStraddle()
  {
   double buffer = GetBufferPoints();
   if(buffer <= 0.0)
     {
      Print("[SimpleStraddleEA] Skipped: invalid buffer (ATR not ready).");
      return;
     }

   double prev_high = iHigh(_Symbol, signal_tf, 1);
   double prev_low = iLow(_Symbol, signal_tf, 1);
   if(prev_high <= 0.0 || prev_low <= 0.0)
     {
      Print("[SimpleStraddleEA] Skipped: invalid previous candle data.");
      return;
     }

   double buy_stop = prev_high + buffer;
   double sell_stop = prev_low - buffer;
   double buy_sl = prev_low - buffer;
   double sell_sl = prev_high + buffer;

   double buy_tp = buy_stop + (buy_stop - buy_sl) * rr;
   double sell_tp = sell_stop - (sell_sl - sell_stop) * rr;

   double buy_lots = CalculateRiskLots(buy_stop, buy_sl);
   double sell_lots = CalculateRiskLots(sell_stop, sell_sl);
   double lots = MathMin(buy_lots, sell_lots);

   if(lots <= 0.0)
     {
      Print("[SimpleStraddleEA] Skipped: invalid lot size.");
      return;
     }

   trade.SetExpertMagicNumber(magic_number);
   trade.SetDeviationInPoints(slippage_points);

   datetime expiry = 0;
   ENUM_ORDER_TYPE_TIME time_type = ORDER_TIME_GTC;
   if(expiry_bars > 0)
     {
      int seconds = PeriodSeconds(signal_tf);
      if(seconds <= 0)
         seconds = 60;
      expiry = TimeCurrent() + (expiry_bars * seconds);
      time_type = ORDER_TIME_SPECIFIED;
     }

   bool buy_ok = trade.BuyStop(lots, buy_stop, _Symbol, buy_sl, buy_tp, time_type, expiry, "SimpleStraddleEA");
   bool sell_ok = trade.SellStop(lots, sell_stop, _Symbol, sell_sl, sell_tp, time_type, expiry, "SimpleStraddleEA");

   if(buy_ok && sell_ok)
      Print("[SimpleStraddleEA] Orders placed: BuyStop at ", DoubleToString(buy_stop, _Digits), ", SellStop at ", DoubleToString(sell_stop, _Digits));
   else
      Print("[SimpleStraddleEA] Order placement failed. Buy=", buy_ok, " Sell=", sell_ok, " LastError=", GetLastError());
  }

int OnInit()
  {
   trade.SetExpertMagicNumber(magic_number);
   return INIT_SUCCEEDED;
  }

void OnTick()
  {
   datetime bar_time = iTime(_Symbol, signal_tf, 1);
   if(bar_time == 0)
      return;

   if(bar_time == last_bar_time)
      return;

   last_bar_time = bar_time;
   Print("[SimpleStraddleEA] New bar detected on ", TimeframeToString(signal_tf), " at ", TimeToString(bar_time));

   if(HasOpenPositionOrOrder())
     {
      Print("[SimpleStraddleEA] Skipped: existing position or pending order.");
      return;
     }

   if(!IsSpreadOk())
     {
      Print("[SimpleStraddleEA] Skipped: spread too high.");
      return;
     }

   if(IsNewsBlackout())
     {
      Print("[SimpleStraddleEA] Skipped: news blackout window.");
      return;
     }

   PlaceStraddle();
  }

void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& request, const MqlTradeResult& result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(trans.deal_entry != DEAL_ENTRY_IN)
      return;
   if(trans.symbol != _Symbol)
      return;

   if((long)trans.magic != magic_number)
      return;

   if(trans.deal_type == DEAL_TYPE_BUY)
     {
      CancelPendingOrdersByType(ORDER_TYPE_SELL_STOP);
      Print("[SimpleStraddleEA] OCO: canceled Sell Stop pending orders.");
     }
   else if(trans.deal_type == DEAL_TYPE_SELL)
     {
      CancelPendingOrdersByType(ORDER_TYPE_BUY_STOP);
      Print("[SimpleStraddleEA] OCO: canceled Buy Stop pending orders.");
     }
  }
