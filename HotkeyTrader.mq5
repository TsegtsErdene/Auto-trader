//+------------------------------------------------------------------+
//|  HotkeyTrader.mq5                                                |
//|  Global-hotkey market-order EA for MetaTrader 5                  |
//|                                                                  |
//|    F1   → Market Buy  (enter long)                               |
//|    F2   → Market Sell (enter short)                              |
//|    F10  → Break Even      – SL to entry on all positions         |
//|    F3   → 20-pip Break Even – SL locks +20 pips of profit        |
//|    F5   → Trailing SL (one-shot) – SL to 10 pips from price      |
//|                                                                  |
//|  Works globally even when MT5 is minimized.                      |
//+------------------------------------------------------------------+

#property copyright "HotkeyTrader"
#property version   "4.00"
#property strict

//--- WinAPI imports
#import "user32.dll"
   int GetAsyncKeyState(int vKey);
#import

//--- Input parameters
input string InpSymbol         = "XAUUSD"; // Trading symbol
input double InpLots           = 0.01;     // Lot size per order
input int    InpLongKey        = 0x70;     // Long  / Buy  key VK (F1)
input int    InpShortKey       = 0x71;     // Short / Sell key VK (F2)
input int    InpBEKey          = 0x79;     // Break Even key VK (F10 = Fn+0)
input int    InpBE20Key        = 0x72;     // 20-pip Break Even key VK (F3)
input int    InpTrailKey       = 0x74;     // Trailing SL key VK (F5)
input int    InpPointsPerPip   = 10;       // Points per pip (gold: 10 → 1 pip = 0.10)
input int    InpBE20Pips       = 20;       // Profit locked by 20-pip Break Even (pips)
input int    InpTrailPips      = 10;       // Trailing SL distance from price (pips)
input ulong  InpMagic          = 20260408; // EA magic number
input uint   InpSlippagePoints = 20;       // Max slippage in points

//--- Globals (edge-detection state — one fire per physical keypress)
bool g_longDown  = false;
bool g_shortDown = false;
bool g_beDown    = false;
bool g_be20Down  = false;
bool g_trailDown = false;

//+------------------------------------------------------------------+
//| Helper – is a virtual key currently held down                    |
//+------------------------------------------------------------------+
bool KeyDown(int vk)
{
   return (GetAsyncKeyState(vk) & 0x8000) != 0;
}

//+------------------------------------------------------------------+
//| Helper – filling mode for a symbol                               |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING SymbolFilling(const string sym)
{
   uint filling = (uint)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   if((filling & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| Helper – price value of one pip on InpSymbol                     |
//+------------------------------------------------------------------+
double PipPrice()
{
   return InpPointsPerPip * SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
}

//+------------------------------------------------------------------+
//| Helper – broker minimum stop distance in price terms             |
//+------------------------------------------------------------------+
double MinStopDist()
{
   long lvl = SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   return (double)lvl * SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   EventSetMillisecondTimer(10);
   UpdateLabel();
   PrintFormat("[HotkeyTrader] Ready | %s | Lots=%.2f | "
               "Long=0x%02X Short=0x%02X  BE=0x%02X  20pBE=0x%02X  Trail=0x%02X | "
               "1 pip = %d points",
               InpSymbol, InpLots, InpLongKey, InpShortKey,
               InpBEKey, InpBE20Key, InpTrailKey, InpPointsPerPip);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
   Print("[HotkeyTrader] Stopped.");
}

void OnTick() {}

//+------------------------------------------------------------------+
//| OnTimer – global hotkey polling loop (runs every 10 ms)          |
//+------------------------------------------------------------------+
void OnTimer()
{
   bool longNow  = KeyDown(InpLongKey);
   bool shortNow = KeyDown(InpShortKey);
   bool beNow    = KeyDown(InpBEKey);
   bool be20Now  = KeyDown(InpBE20Key);
   bool trailNow = KeyDown(InpTrailKey);

   //--- F1 → enter long (edge-triggered)
   if(longNow && !g_longDown)
      DoBuy();
   g_longDown = longNow;

   //--- F2 → enter short (edge-triggered)
   if(shortNow && !g_shortDown)
      DoSell();
   g_shortDown = shortNow;

   //--- F10 → break even: SL to entry (edge-triggered)
   if(beNow && !g_beDown)
      DoBreakEven(0);
   g_beDown = beNow;

   //--- F3 → 20-pip break even: SL locks +20 pips (edge-triggered)
   if(be20Now && !g_be20Down)
      DoBreakEven(InpBE20Pips);
   g_be20Down = be20Now;

   //--- F5 → trailing SL one-shot: SL to 10 pips from price (edge-triggered)
   if(trailNow && !g_trailDown)
      DoTrailingStop();
   g_trailDown = trailNow;
}

//+------------------------------------------------------------------+
//| Refresh on-chart info label                                      |
//+------------------------------------------------------------------+
void UpdateLabel()
{
   Comment(StringFormat(
      "  HotkeyTrader v4\n"
      "  ─────────────────────────────────────\n"
      "  Symbol      : %s\n"
      "  Lots        : %.2f\n"
      "  Long  (Buy) : VK 0x%02X\n"
      "  Short (Sell): VK 0x%02X\n"
      "  Break Even  : VK 0x%02X\n"
      "  20-pip BE   : VK 0x%02X  (+%d pips)\n"
      "  Trailing SL : VK 0x%02X  (%d pips from price)\n"
      "  1 pip       = %d points",
      InpSymbol, InpLots, InpLongKey, InpShortKey, InpBEKey,
      InpBE20Key, InpBE20Pips, InpTrailKey, InpTrailPips, InpPointsPerPip));
}

//+------------------------------------------------------------------+
//| Market buy                                                       |
//+------------------------------------------------------------------+
void DoBuy()
{
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = InpSymbol;
   req.volume       = InpLots;
   req.type         = ORDER_TYPE_BUY;
   req.price        = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   req.deviation    = InpSlippagePoints;
   req.magic        = InpMagic;
   req.type_filling = SymbolFilling(InpSymbol);

   if(!OrderSendAsync(req, res))
      PrintFormat("[HotkeyTrader] Buy FAILED retcode=%u", res.retcode);
   else
      PrintFormat("[HotkeyTrader] LONG sent reqid=%u", res.request_id);
}

//+------------------------------------------------------------------+
//| Market sell                                                      |
//+------------------------------------------------------------------+
void DoSell()
{
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = InpSymbol;
   req.volume       = InpLots;
   req.type         = ORDER_TYPE_SELL;
   req.price        = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   req.deviation    = InpSlippagePoints;
   req.magic        = InpMagic;
   req.type_filling = SymbolFilling(InpSymbol);

   if(!OrderSendAsync(req, res))
      PrintFormat("[HotkeyTrader] Sell FAILED retcode=%u", res.retcode);
   else
      PrintFormat("[HotkeyTrader] SHORT sent reqid=%u", res.request_id);
}

//+------------------------------------------------------------------+
//| Move SL of all open positions to break even (+lockPips profit)   |
//|   lockPips = 0  → SL at entry                                    |
//|   lockPips = 20 → SL 20 pips into profit                         |
//| Only tightens the stop, and only if price is far enough in       |
//| profit for the broker to accept it.                              |
//+------------------------------------------------------------------+
void DoBreakEven(double lockPips)
{
   double pip      = PipPrice();
   double stopDist = MinStopDist();
   int    digits   = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);
   double bid      = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   double ask      = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);

   int moved = 0, skipped = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol) continue;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);

      double target = (ptype == POSITION_TYPE_BUY) ? entry + lockPips * pip
                                                   : entry - lockPips * pip;
      target = NormalizeDouble(target, digits);

      if(ptype == POSITION_TYPE_BUY)
      {
         if(target >= bid - stopDist)        { skipped++; continue; } // not enough profit yet
         if(curSL > 0 && curSL >= target)    { skipped++; continue; } // never move SL backward
      }
      else
      {
         if(target <= ask + stopDist)        { skipped++; continue; }
         if(curSL > 0 && curSL <= target)    { skipped++; continue; }
      }

      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action   = TRADE_ACTION_SLTP;
      req.symbol   = InpSymbol;
      req.position = ticket;
      req.sl       = target;
      req.tp       = tp;

      if(OrderSend(req, res)) moved++;
      else PrintFormat("[HotkeyTrader] BE FAILED ticket=%I64u retcode=%u", ticket, res.retcode);
   }

   PrintFormat("[HotkeyTrader] %s: %d moved, %d skipped",
               (lockPips > 0 ? "20-pip BE" : "Break Even"), moved, skipped);
}

//+------------------------------------------------------------------+
//| Trailing SL (one-shot): move SL to InpTrailPips from current     |
//| price on every open position. Only ever tightens the stop.       |
//+------------------------------------------------------------------+
void DoTrailingStop()
{
   double pip      = PipPrice();
   double stopDist = MinStopDist();
   int    digits   = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);
   double bid      = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   double ask      = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);

   int moved = 0, skipped = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol) continue;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double curSL = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);

      double newSL;
      if(ptype == POSITION_TYPE_BUY)
      {
         newSL = NormalizeDouble(bid - InpTrailPips * pip, digits);
         if(newSL >= bid - stopDist)        { skipped++; continue; } // too close to market
         if(curSL > 0 && newSL <= curSL)    { skipped++; continue; } // only trail up
      }
      else
      {
         newSL = NormalizeDouble(ask + InpTrailPips * pip, digits);
         if(newSL <= ask + stopDist)        { skipped++; continue; }
         if(curSL > 0 && newSL >= curSL)    { skipped++; continue; } // only trail down
      }

      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action   = TRADE_ACTION_SLTP;
      req.symbol   = InpSymbol;
      req.position = ticket;
      req.sl       = newSL;
      req.tp       = tp;

      if(OrderSend(req, res)) moved++;
      else PrintFormat("[HotkeyTrader] Trail FAILED ticket=%I64u retcode=%u", ticket, res.retcode);
   }

   PrintFormat("[HotkeyTrader] Trailing SL: %d moved, %d skipped", moved, skipped);
}
//+------------------------------------------------------------------+
