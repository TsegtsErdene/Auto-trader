//+------------------------------------------------------------------+
//|  HotkeyTrader.mq5                                                |
//|  Global-hotkey trading panel for MetaTrader 5 — numpad edition   |
//|                                                                  |
//|    Numpad 1 → Market Buy        (enter long)                     |
//|    Numpad 2 → Market Sell       (enter short)                    |
//|    Numpad 0 → Break Even        – SL to entry                    |
//|    Numpad 3 → 20-pip Break Even – SL locks +20 pips of profit    |
//|    Numpad 4 → Half              – close half of each position    |
//|    Numpad 5 → Trailing SL       – SL to 10 pips from price       |
//|    Numpad 6 → Lot size          – popup to type the lot          |
//|    Numpad 7 → Set SL            – popup to type one SL price     |
//|    Numpad 8 → Protect           – pick positions bulk ops skip   |
//|    Numpad 9 → Flatten           – close everything (press twice) |
//|    Numpad . → Arm / Disarm      – gate on NEW entries only       |
//|                                                                  |
//|  Exits always work; only Buy/Sell need the EA to be armed.       |
//|  Works globally even when MT5 is minimized. NumLock must be ON   |
//|  so the keypad sends Numpad VK codes (0x60-0x6F).                |
//+------------------------------------------------------------------+

#property copyright "HotkeyTrader"
#property version   "5.00"
#property strict

//--- WinAPI imports
#import "user32.dll"
   int GetAsyncKeyState(int vKey);
#import
#import "shell32.dll"
   int ShellExecuteW(int hwnd, string oper, string file, string params, string dir, int show);
#import

//--- IPC file names (in MT5 Common Files\Files\)
#define LOT_SCRIPT_FILE     "ht_lot_input.ps1"
#define LOT_RESULT_FILE     "ht_lot_result.txt"
#define SL_SCRIPT_FILE      "ht_sl_input.ps1"
#define SL_RESULT_FILE      "ht_sl_result.txt"
#define PROT_SCRIPT_FILE    "ht_protect_input.ps1"
#define PROT_RESULT_FILE    "ht_protect_result.txt"

//--- Which popup is currently open (all hotkeys are absorbed while one is)
#define POPUP_NONE    0
#define POPUP_LOT     1
#define POPUP_SL      2
#define POPUP_PROTECT 3

//--- Input parameters
input string InpSymbol          = "XAUUSD"; // Trading symbol
input double InpLots            = 0.01;     // Starting lot size per order
input int    InpLongKey         = 0x61;     // Long  / Buy  key VK (Numpad 1)
input int    InpShortKey        = 0x62;     // Short / Sell key VK (Numpad 2)
input int    InpBEKey           = 0x60;     // Break Even key VK (Numpad 0)
input int    InpBE20Key         = 0x63;     // 20-pip Break Even key VK (Numpad 3)
input int    InpHalfKey         = 0x64;     // Half-close key VK (Numpad 4)
input int    InpTrailKey        = 0x65;     // Trailing SL key VK (Numpad 5)
input int    InpLotKey          = 0x66;     // Lot-size popup key VK (Numpad 6)
input int    InpSLKey           = 0x67;     // Set-SL popup key VK (Numpad 7)
input int    InpProtectKey      = 0x68;     // Protect-positions popup key VK (Numpad 8)
input int    InpFlattenKey      = 0x69;     // Flatten (close all) key VK (Numpad 9)
input int    InpArmKey          = 0x6E;     // Arm / disarm key VK (Numpad .)
input int    InpPointsPerPip    = 10;       // Points per pip (gold: 10 -> 1 pip = 0.10)
input int    InpBE20Pips        = 20;       // Profit locked by 20-pip Break Even (pips)
input int    InpTrailPips       = 10;       // Trailing SL distance from price (pips)
input bool   InpStartArmed      = false;    // Start armed (false = entries blocked until Numpad .)
input int    InpAutoDisarmMin   = 30;       // Auto-disarm after N idle minutes (0 = never)
input int    InpFlattenConfirmSec = 3;      // Flatten needs a 2nd press within N sec (0 = no confirm)
input int    InpPopupTimeoutSec = 120;      // Give up on a popup after N sec (0 = wait forever)
input ulong  InpMagic           = 20260408; // EA magic number
input uint   InpSlippagePoints  = 20;       // Max slippage in points

//--- Globals (edge-detection state — one fire per physical keypress)
bool   g_longDown    = false;
bool   g_shortDown   = false;
bool   g_beDown      = false;
bool   g_be20Down    = false;
bool   g_halfDown    = false;
bool   g_trailDown   = false;
bool   g_lotDown     = false;
bool   g_slDown      = false;
bool   g_protDown    = false;
bool   g_flatDown    = false;
bool   g_armDown     = false;

//--- Active lot size (starts at InpLots, changed via the lot popup)
double   g_lots       = 0.0;
//--- Which popup is open; while != POPUP_NONE every hotkey is absorbed
int      g_popup      = POPUP_NONE;
//--- Entry gate: false blocks Buy/Sell (exits and stop moves still work)
bool     g_armed      = false;
//--- Last time an order was sent or the EA was armed (for auto-disarm)
datetime g_lastAction = 0;
//--- Tickets the bulk actions must leave alone
ulong    g_protected[];
//--- Deadline (ms) for the second Flatten press; 0 = not waiting
ulong    g_flattenUntil = 0;
//--- When the open popup was launched (ms), for the watchdog below
ulong    g_popupSince   = 0;

//+------------------------------------------------------------------+
//| Helper – is a virtual key currently held down                    |
//+------------------------------------------------------------------+
bool KeyDown(int vk)
{
   return (GetAsyncKeyState(vk) & 0x8000) != 0;
}

//+------------------------------------------------------------------+
//| Helper – printable name of a numpad VK code                      |
//+------------------------------------------------------------------+
string KeyName(int vk)
{
   if(vk >= 0x60 && vk <= 0x69) return StringFormat("Num %d", vk - 0x60);
   switch(vk)
   {
      case 0x6A: return "Num *";
      case 0x6B: return "Num +";
      case 0x6D: return "Num -";
      case 0x6E: return "Num .";
      case 0x6F: return "Num /";
   }
   return StringFormat("VK 0x%02X", vk);
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
//| Helper – decimal places implied by the symbol's volume step      |
//+------------------------------------------------------------------+
int VolumeDigits()
{
   double step = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) return 2;
   int d = 0;
   while(step < 1.0 && d < 8) { step *= 10.0; d++; }
   return d;
}

//+------------------------------------------------------------------+
//| Helper – snap a lot value to the broker's step / min / max       |
//+------------------------------------------------------------------+
double NormalizeLot(double v)
{
   double step = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP);
   double minV = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MIN);
   double maxV = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0) step = 0.01;
   v = MathRound(v / step) * step;
   if(v < minV)             v = minV;
   if(maxV > 0 && v > maxV) v = maxV;
   return NormalizeDouble(v, VolumeDigits());
}

//+------------------------------------------------------------------+
//| Helper – is this ticket protected from bulk actions              |
//+------------------------------------------------------------------+
bool IsProtected(ulong ticket)
{
   for(int i = 0; i < ArraySize(g_protected); i++)
      if(g_protected[i] == ticket) return true;
   return false;
}

//+------------------------------------------------------------------+
//| Helper – MT5 Common Files\Files\ path                            |
//+------------------------------------------------------------------+
string CommonFilesPath()
{
   return TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "\\Files\\";
}

//+------------------------------------------------------------------+
//| Helper – escape a value for a PowerShell single-quoted string    |
//+------------------------------------------------------------------+
string PsQuote(const string s)
{
   string out = s;
   StringReplace(out, "'", "''");
   return out;
}

//+------------------------------------------------------------------+
//| Helper – collect every live ticket a bulk action may touch       |
//| (skips other symbols and protected tickets)                      |
//+------------------------------------------------------------------+
int CollectTickets(ulong &tickets[])
{
   int total = PositionsTotal();
   ArrayResize(tickets, total);
   int count = 0;
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol) continue;
      if(IsProtected(ticket)) continue;
      tickets[count++] = ticket;
   }
   ArrayResize(tickets, count);
   return count;
}

//+------------------------------------------------------------------+
//| Arm / disarm the entry gate                                      |
//+------------------------------------------------------------------+
void SetArmed(bool on, const string reason)
{
   g_armed = on;
   if(on) g_lastAction = TimeLocal();
   PrintFormat("[HotkeyTrader] Entries %s%s", on ? "ARMED" : "DISARMED", reason);
   UpdateLabel();
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!SymbolSelect(InpSymbol, true))
      PrintFormat("[HotkeyTrader] WARNING: %s is not in Market Watch", InpSymbol);

   g_lots  = NormalizeLot(InpLots);
   g_armed = InpStartArmed;
   if(g_armed) g_lastAction = TimeLocal();
   ArrayResize(g_protected, 0);

   //--- clear any stale popup results from a previous run
   FileDelete(LOT_RESULT_FILE,  FILE_COMMON);
   FileDelete(SL_RESULT_FILE,   FILE_COMMON);
   FileDelete(PROT_RESULT_FILE, FILE_COMMON);

   EventSetMillisecondTimer(10);
   UpdateLabel();
   PrintFormat("[HotkeyTrader] Ready | %s | Lots=%s | Entries %s | "
               "Buy=%s Sell=%s BE=%s BE+%d=%s Half=%s Trail=%s Lot=%s SL=%s Protect=%s Flatten=%s Arm=%s | "
               "1 pip = %d points",
               InpSymbol, DoubleToString(g_lots, VolumeDigits()),
               g_armed ? "ARMED" : "DISARMED",
               KeyName(InpLongKey), KeyName(InpShortKey), KeyName(InpBEKey),
               InpBE20Pips, KeyName(InpBE20Key), KeyName(InpHalfKey), KeyName(InpTrailKey),
               KeyName(InpLotKey), KeyName(InpSLKey), KeyName(InpProtectKey),
               KeyName(InpFlattenKey), KeyName(InpArmKey), InpPointsPerPip);
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
   //--- While a popup is open, absorb every key state without acting.
   //    The numpad digits the user types into the box are still visible to
   //    GetAsyncKeyState globally, so acting on them here would fire trades.
   if(g_popup != POPUP_NONE)
   {
      g_longDown  = KeyDown(InpLongKey);
      g_shortDown = KeyDown(InpShortKey);
      g_beDown    = KeyDown(InpBEKey);
      g_be20Down  = KeyDown(InpBE20Key);
      g_halfDown  = KeyDown(InpHalfKey);
      g_trailDown = KeyDown(InpTrailKey);
      g_lotDown   = KeyDown(InpLotKey);
      g_slDown    = KeyDown(InpSLKey);
      g_protDown  = KeyDown(InpProtectKey);
      g_flatDown  = KeyDown(InpFlattenKey);
      g_armDown   = KeyDown(InpArmKey);
      CheckPopupResult();

      //--- Watchdog: a popup whose PowerShell died would otherwise keep
      //    every hotkey absorbed forever, including Flatten.
      if(g_popup != POPUP_NONE && InpPopupTimeoutSec > 0 &&
         GetTickCount64() - g_popupSince > (ulong)InpPopupTimeoutSec * 1000)
         AbortPopup();

      return;
   }

   //--- Flatten confirmation window expired
   if(g_flattenUntil > 0 && GetTickCount64() > g_flattenUntil)
   {
      g_flattenUntil = 0;
      Print("[HotkeyTrader] Flatten confirmation expired");
      UpdateLabel();
   }

   //--- Auto-disarm after N idle minutes
   if(g_armed && InpAutoDisarmMin > 0 && g_lastAction > 0 &&
      (TimeLocal() - g_lastAction) >= InpAutoDisarmMin * 60)
      SetArmed(false, StringFormat(": %d minutes without a trade", InpAutoDisarmMin));

   bool longNow  = KeyDown(InpLongKey);
   bool shortNow = KeyDown(InpShortKey);
   bool beNow    = KeyDown(InpBEKey);
   bool be20Now  = KeyDown(InpBE20Key);
   bool halfNow  = KeyDown(InpHalfKey);
   bool trailNow = KeyDown(InpTrailKey);
   bool lotNow   = KeyDown(InpLotKey);
   bool slNow    = KeyDown(InpSLKey);
   bool protNow  = KeyDown(InpProtectKey);
   bool flatNow  = KeyDown(InpFlattenKey);
   bool armNow   = KeyDown(InpArmKey);

   //--- Numpad . → toggle the entry gate (edge-triggered)
   if(armNow && !g_armDown)
      SetArmed(!g_armed, " by hotkey");
   g_armDown = armNow;

   //--- Numpad 1 → enter long (edge-triggered, gated)
   if(longNow && !g_longDown)
   {
      if(g_armed) DoBuy();
      else        Print("[HotkeyTrader] Buy ignored — entries are DISARMED (press ", KeyName(InpArmKey), ")");
   }
   g_longDown = longNow;

   //--- Numpad 2 → enter short (edge-triggered, gated)
   if(shortNow && !g_shortDown)
   {
      if(g_armed) DoSell();
      else        Print("[HotkeyTrader] Sell ignored — entries are DISARMED (press ", KeyName(InpArmKey), ")");
   }
   g_shortDown = shortNow;

   //--- Numpad 0 → break even: SL to entry (edge-triggered)
   if(beNow && !g_beDown)
      DoBreakEven(0);
   g_beDown = beNow;

   //--- Numpad 3 → 20-pip break even: SL locks +20 pips (edge-triggered)
   if(be20Now && !g_be20Down)
      DoBreakEven(InpBE20Pips);
   g_be20Down = be20Now;

   //--- Numpad 4 → close half of every position (edge-triggered)
   if(halfNow && !g_halfDown)
      DoHalf();
   g_halfDown = halfNow;

   //--- Numpad 5 → trailing SL one-shot (edge-triggered)
   if(trailNow && !g_trailDown)
      DoTrailingStop();
   g_trailDown = trailNow;

   //--- Numpad 6 → open manual lot-size popup (edge-triggered)
   if(lotNow && !g_lotDown)
      ShowLotInput();
   g_lotDown = lotNow;

   //--- Numpad 7 → open SL price popup (edge-triggered)
   if(slNow && !g_slDown)
      ShowSLInput();
   g_slDown = slNow;

   //--- Numpad 8 → open protect-positions popup (edge-triggered)
   if(protNow && !g_protDown)
      ShowProtectInput();
   g_protDown = protNow;

   //--- Numpad 9 → flatten everything; first press only arms it (edge-triggered)
   if(flatNow && !g_flatDown)
   {
      if(InpFlattenConfirmSec > 0 && g_flattenUntil == 0)
      {
         g_flattenUntil = GetTickCount64() + (ulong)InpFlattenConfirmSec * 1000;
         PrintFormat("[HotkeyTrader] FLATTEN armed — press %s again within %d s to close everything",
                     KeyName(InpFlattenKey), InpFlattenConfirmSec);
         UpdateLabel();
      }
      else
      {
         g_flattenUntil = 0;
         DoFlatten();
         UpdateLabel();
      }
   }
   g_flatDown = flatNow;
}

//+------------------------------------------------------------------+
//| Refresh on-chart info label                                      |
//+------------------------------------------------------------------+
void UpdateLabel()
{
   string state = g_armed ? "ARMED" : "DISARMED";
   if(g_flattenUntil > 0) state += "   >>> FLATTEN: press again to confirm <<<";

   Comment(StringFormat(
      "  HotkeyTrader v5     [ %s ]\n"
      "  ─────────────────────────────────────\n"
      "  Symbol : %-10s  Lots : %s\n"
      "  1 pip  = %d points   Protected : %d position(s)\n"
      "  ─────────────────────────────────────\n"
      "  %-7s Buy            %-7s Sell\n"
      "  %-7s Break Even     %-7s BE +%d pips\n"
      "  %-7s Half close     %-7s Trail %d pips\n"
      "  %-7s Set lots       %-7s Set SL price\n"
      "  %-7s Protect        %-7s Flatten (2x)\n"
      "  %-7s Arm / Disarm   (blocks Buy/Sell only)",
      state, InpSymbol, DoubleToString(g_lots, VolumeDigits()),
      InpPointsPerPip, ArraySize(g_protected),
      KeyName(InpLongKey), KeyName(InpShortKey),
      KeyName(InpBEKey), KeyName(InpBE20Key), InpBE20Pips,
      KeyName(InpHalfKey), KeyName(InpTrailKey), InpTrailPips,
      KeyName(InpLotKey), KeyName(InpSLKey),
      KeyName(InpProtectKey), KeyName(InpFlattenKey),
      KeyName(InpArmKey)));
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
   req.volume       = g_lots;
   req.type         = ORDER_TYPE_BUY;
   req.price        = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   req.deviation    = InpSlippagePoints;
   req.magic        = InpMagic;
   req.type_filling = SymbolFilling(InpSymbol);

   if(!OrderSendAsync(req, res))
      PrintFormat("[HotkeyTrader] Buy FAILED retcode=%u", res.retcode);
   else
   {
      g_lastAction = TimeLocal();
      PrintFormat("[HotkeyTrader] LONG sent reqid=%u", res.request_id);
   }
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
   req.volume       = g_lots;
   req.type         = ORDER_TYPE_SELL;
   req.price        = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   req.deviation    = InpSlippagePoints;
   req.magic        = InpMagic;
   req.type_filling = SymbolFilling(InpSymbol);

   if(!OrderSendAsync(req, res))
      PrintFormat("[HotkeyTrader] Sell FAILED retcode=%u", res.retcode);
   else
   {
      g_lastAction = TimeLocal();
      PrintFormat("[HotkeyTrader] SHORT sent reqid=%u", res.request_id);
   }
}

//+------------------------------------------------------------------+
//| Move SL of all open positions to break even (+lockPips profit)   |
//|   lockPips = 0  → SL at entry                                    |
//|   lockPips = 20 → SL 20 pips into profit                         |
//| Only tightens the stop, and only if price is far enough in       |
//| profit for the broker to accept it. Protected tickets are left   |
//| untouched.                                                       |
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
      if(IsProtected(ticket)) { skipped++; continue; }

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
      if(IsProtected(ticket)) { skipped++; continue; }

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
//| Close one position (or part of it) at market                     |
//+------------------------------------------------------------------+
bool ClosePart(ulong ticket, double volume)
{
   if(!PositionSelectByTicket(ticket)) return false;

   ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = InpSymbol;
   req.volume       = volume;
   req.type         = (ptype == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price        = (ptype == POSITION_TYPE_BUY)
                      ? SymbolInfoDouble(InpSymbol, SYMBOL_BID)
                      : SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   req.deviation    = InpSlippagePoints;
   req.position     = ticket;
   req.magic        = InpMagic;
   req.type_filling = SymbolFilling(InpSymbol);

   if(OrderSendAsync(req, res)) return true;

   PrintFormat("[HotkeyTrader] Close FAILED ticket=%I64u vol=%s retcode=%u",
               ticket, DoubleToString(volume, VolumeDigits()), res.retcode);
   return false;
}

//+------------------------------------------------------------------+
//| Flatten – close every position on InpSymbol except protected     |
//+------------------------------------------------------------------+
void DoFlatten()
{
   ulong tickets[];
   int count = CollectTickets(tickets);
   if(count == 0)
   {
      Print("[HotkeyTrader] Flatten: nothing to close on ", InpSymbol);
      return;
   }

   int sent = 0;
   for(int i = 0; i < count; i++)
   {
      if(!PositionSelectByTicket(tickets[i])) continue;
      if(ClosePart(tickets[i], PositionGetDouble(POSITION_VOLUME))) sent++;
   }

   if(sent > 0) g_lastAction = TimeLocal();
   PrintFormat("[HotkeyTrader] FLATTEN: %d of %d close(s) sent", sent, count);
}

//+------------------------------------------------------------------+
//| Half – close half the VOLUME of each position on InpSymbol.      |
//| A position is skipped when half of it, or the remainder, would   |
//| fall below the broker's minimum lot.                             |
//+------------------------------------------------------------------+
void DoHalf()
{
   ulong tickets[];
   int count = CollectTickets(tickets);
   if(count == 0)
   {
      Print("[HotkeyTrader] Half: nothing to close on ", InpSymbol);
      return;
   }

   double step = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP);
   double minV = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MIN);
   if(step <= 0.0) step = 0.01;
   int digits = VolumeDigits();

   int sent = 0, skipped = 0;
   for(int i = 0; i < count; i++)
   {
      if(!PositionSelectByTicket(tickets[i])) continue;

      double vol  = PositionGetDouble(POSITION_VOLUME);
      double half = NormalizeDouble(MathFloor((vol / 2.0) / step) * step, digits);

      if(half < minV || NormalizeDouble(vol - half, digits) < minV) { skipped++; continue; }
      if(ClosePart(tickets[i], half)) sent++;
   }

   if(sent > 0) g_lastAction = TimeLocal();
   PrintFormat("[HotkeyTrader] HALF: %d halved, %d too small to split", sent, skipped);
}

//+------------------------------------------------------------------+
//| Apply one SL price to every position on InpSymbol.               |
//| Rejects a price on the wrong side of the market or inside the    |
//| broker's minimum stop distance, so nothing is sent blindly.      |
//+------------------------------------------------------------------+
void ApplySLToAll(double slPrice)
{
   double stopDist = MinStopDist();
   int    digits   = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);
   double bid      = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   double ask      = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   double sl       = NormalizeDouble(slPrice, digits);

   int moved = 0, skipped = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol) continue;
      if(IsProtected(ticket)) { skipped++; continue; }

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(ptype == POSITION_TYPE_BUY  && sl >= bid - stopDist) { skipped++; continue; }
      if(ptype == POSITION_TYPE_SELL && sl <= ask + stopDist) { skipped++; continue; }

      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action   = TRADE_ACTION_SLTP;
      req.symbol   = InpSymbol;
      req.position = ticket;
      req.sl       = sl;
      req.tp       = PositionGetDouble(POSITION_TP);

      if(OrderSend(req, res)) moved++;
      else PrintFormat("[HotkeyTrader] Set SL FAILED ticket=%I64u retcode=%u", ticket, res.retcode);
   }

   PrintFormat("[HotkeyTrader] Set SL %s: %d moved, %d skipped",
               DoubleToString(sl, digits), moved, skipped);
}

//+------------------------------------------------------------------+
//| Launch a PowerShell script hidden; returns false if it failed    |
//+------------------------------------------------------------------+
bool LaunchScript(const string scriptFile)
{
   string full   = CommonFilesPath() + scriptFile;
   string params = "-ExecutionPolicy Bypass -WindowStyle Hidden -NoProfile -File \"" + full + "\"";
   int rc = ShellExecuteW(0, "open", "powershell.exe", params, "", 0);
   if(rc <= 32)
   {
      PrintFormat("[HotkeyTrader] Popup launch failed rc=%d (%s)", rc, scriptFile);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Write a one-field WinForms input dialog script.                  |
//| OK writes the typed text to resultFile, Cancel writes an empty   |
//| line — either way the EA is released from the popup state.       |
//+------------------------------------------------------------------+
bool WriteInputDialog(const string scriptFile, const string resultFile,
                      const string title, const string prompt, const string preset)
{
   int h = FileOpen(scriptFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
   {
      PrintFormat("[HotkeyTrader] Cannot write %s (err=%d)", scriptFile, GetLastError());
      return false;
   }

   string resFull = CommonFilesPath() + resultFile;

   FileWrite(h, "Add-Type -AssemblyName System.Windows.Forms");
   FileWrite(h, "Add-Type -AssemblyName System.Drawing");
   FileWrite(h, "$f = New-Object System.Windows.Forms.Form");
   FileWrite(h, "$f.Text = '" + PsQuote(title) + "'");
   FileWrite(h, "$f.Size = New-Object System.Drawing.Size(280,150)");
   FileWrite(h, "$f.StartPosition = 'CenterScreen'");
   FileWrite(h, "$f.TopMost = $true");
   FileWrite(h, "$f.FormBorderStyle = 'FixedDialog'");
   FileWrite(h, "$f.MaximizeBox = $false");
   FileWrite(h, "$f.MinimizeBox = $false");
   FileWrite(h, "$l = New-Object System.Windows.Forms.Label");
   FileWrite(h, "$l.Text = '" + PsQuote(prompt) + "'");
   FileWrite(h, "$l.AutoSize = $true");
   FileWrite(h, "$l.Location = New-Object System.Drawing.Point(12,15)");
   FileWrite(h, "$f.Controls.Add($l)");
   FileWrite(h, "$t = New-Object System.Windows.Forms.TextBox");
   FileWrite(h, "$t.Location = New-Object System.Drawing.Point(12,38)");
   FileWrite(h, "$t.Size = New-Object System.Drawing.Size(248,22)");
   FileWrite(h, "$t.Text = '" + PsQuote(preset) + "'");
   FileWrite(h, "$f.Controls.Add($t)");
   FileWrite(h, "$ok = New-Object System.Windows.Forms.Button");
   FileWrite(h, "$ok.Text = 'OK'");
   FileWrite(h, "$ok.Location = New-Object System.Drawing.Point(104,75)");
   FileWrite(h, "$ok.DialogResult = [System.Windows.Forms.DialogResult]::OK");
   FileWrite(h, "$f.Controls.Add($ok)");
   FileWrite(h, "$f.AcceptButton = $ok");
   FileWrite(h, "$c = New-Object System.Windows.Forms.Button");
   FileWrite(h, "$c.Text = 'Cancel'");
   FileWrite(h, "$c.Location = New-Object System.Drawing.Point(185,75)");
   FileWrite(h, "$c.DialogResult = [System.Windows.Forms.DialogResult]::Cancel");
   FileWrite(h, "$f.Controls.Add($c)");
   FileWrite(h, "$f.CancelButton = $c");
   FileWrite(h, "$f.Add_Shown({$f.Activate(); $t.Focus(); $t.SelectAll()})");
   FileWrite(h, "$r = $f.ShowDialog()");
   FileWrite(h, "if ($r -eq [System.Windows.Forms.DialogResult]::OK) {");
   FileWrite(h, "  Set-Content -Path '" + PsQuote(resFull) + "' -Value $t.Text -Encoding ASCII");
   FileWrite(h, "} else {");
   FileWrite(h, "  Set-Content -Path '" + PsQuote(resFull) + "' -Value '' -Encoding ASCII");
   FileWrite(h, "}");
   FileClose(h);
   return true;
}

//+------------------------------------------------------------------+
//| Numpad 6 – popup to type the active lot size                     |
//+------------------------------------------------------------------+
void ShowLotInput()
{
   FileDelete(LOT_RESULT_FILE, FILE_COMMON);

   if(!WriteInputDialog(LOT_SCRIPT_FILE, LOT_RESULT_FILE, "Lot Size", "Enter lot size:",
                        DoubleToString(g_lots, VolumeDigits())))
      return;
   if(!LaunchScript(LOT_SCRIPT_FILE)) return;

   OpenPopup(POPUP_LOT);
   Print("[HotkeyTrader] Lot input popup opened");
}

//+------------------------------------------------------------------+
//| Numpad 7 – popup to type one SL price for every position         |
//+------------------------------------------------------------------+
void ShowSLInput()
{
   FileDelete(SL_RESULT_FILE, FILE_COMMON);

   int    digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);
   double bid    = SymbolInfoDouble(InpSymbol, SYMBOL_BID);

   if(!WriteInputDialog(SL_SCRIPT_FILE, SL_RESULT_FILE, "Stop Loss",
                        "SL price for " + InpSymbol + ":", DoubleToString(bid, digits)))
      return;
   if(!LaunchScript(SL_SCRIPT_FILE)) return;

   OpenPopup(POPUP_SL);
   Print("[HotkeyTrader] SL input popup opened");
}

//+------------------------------------------------------------------+
//| Numpad 8 – popup listing open positions; the ones ticked are     |
//| protected, i.e. every bulk action skips them.                    |
//+------------------------------------------------------------------+
void ShowProtectInput()
{
   FileDelete(PROT_RESULT_FILE, FILE_COMMON);

   int    digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);
   double bid    = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   string resFull = CommonFilesPath() + PROT_RESULT_FILE;

   int h = FileOpen(PROT_SCRIPT_FILE, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
   {
      PrintFormat("[HotkeyTrader] Cannot write %s (err=%d)", PROT_SCRIPT_FILE, GetLastError());
      return;
   }

   FileWrite(h, "Add-Type -AssemblyName System.Windows.Forms");
   FileWrite(h, "Add-Type -AssemblyName System.Drawing");
   FileWrite(h, "$f = New-Object System.Windows.Forms.Form");
   FileWrite(h, "$f.Text = 'Protect positions'");
   FileWrite(h, "$f.Size = New-Object System.Drawing.Size(540,380)");
   FileWrite(h, "$f.StartPosition = 'CenterScreen'");
   FileWrite(h, "$f.TopMost = $true");
   FileWrite(h, "$l = New-Object System.Windows.Forms.Label");
   FileWrite(h, "$l.Text = 'Ticked positions are PROTECTED - Flatten, Half, BE and Trail skip them.'");
   FileWrite(h, "$l.AutoSize = $true");
   FileWrite(h, "$l.Location = New-Object System.Drawing.Point(12,12)");
   FileWrite(h, "$f.Controls.Add($l)");
   FileWrite(h, "$lv = New-Object System.Windows.Forms.ListView");
   FileWrite(h, "$lv.View = 'Details'");
   FileWrite(h, "$lv.CheckBoxes = $true");
   FileWrite(h, "$lv.FullRowSelect = $true");
   FileWrite(h, "$lv.GridLines = $true");
   FileWrite(h, "$lv.Location = New-Object System.Drawing.Point(12,38)");
   FileWrite(h, "$lv.Size = New-Object System.Drawing.Size(500,255)");
   FileWrite(h, "$lv.Columns.Add('Ticket',110) | Out-Null");
   FileWrite(h, "$lv.Columns.Add('Type',55) | Out-Null");
   FileWrite(h, "$lv.Columns.Add('Lots',60) | Out-Null");
   FileWrite(h, "$lv.Columns.Add('Entry',85) | Out-Null");
   FileWrite(h, "$lv.Columns.Add('Price',85) | Out-Null");
   FileWrite(h, "$lv.Columns.Add('P/L',80) | Out-Null");

   int listed = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol) continue;

      bool   isBuy  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double vol    = PositionGetDouble(POSITION_VOLUME);
      double open   = PositionGetDouble(POSITION_PRICE_OPEN);
      double profit = PositionGetDouble(POSITION_PROFIT);
      double price  = isBuy ? bid : ask;

      FileWrite(h, StringFormat("$it = New-Object System.Windows.Forms.ListViewItem('%I64u')", ticket));
      FileWrite(h, StringFormat("$it.SubItems.Add('%s') | Out-Null", isBuy ? "BUY" : "SELL"));
      FileWrite(h, StringFormat("$it.SubItems.Add('%s') | Out-Null", DoubleToString(vol, VolumeDigits())));
      FileWrite(h, StringFormat("$it.SubItems.Add('%s') | Out-Null", DoubleToString(open, digits)));
      FileWrite(h, StringFormat("$it.SubItems.Add('%s') | Out-Null", DoubleToString(price, digits)));
      FileWrite(h, StringFormat("$it.SubItems.Add('%s') | Out-Null", DoubleToString(profit, 2)));
      FileWrite(h, StringFormat("$it.Checked = $%s", IsProtected(ticket) ? "true" : "false"));
      FileWrite(h, "$lv.Items.Add($it) | Out-Null");
      listed++;
   }

   FileWrite(h, "$f.Controls.Add($lv)");
   FileWrite(h, "$ok = New-Object System.Windows.Forms.Button");
   FileWrite(h, "$ok.Text = 'OK'");
   FileWrite(h, "$ok.Location = New-Object System.Drawing.Point(355,305)");
   FileWrite(h, "$ok.DialogResult = [System.Windows.Forms.DialogResult]::OK");
   FileWrite(h, "$f.Controls.Add($ok)");
   FileWrite(h, "$f.AcceptButton = $ok");
   FileWrite(h, "$c = New-Object System.Windows.Forms.Button");
   FileWrite(h, "$c.Text = 'Cancel'");
   FileWrite(h, "$c.Location = New-Object System.Drawing.Point(437,305)");
   FileWrite(h, "$c.DialogResult = [System.Windows.Forms.DialogResult]::Cancel");
   FileWrite(h, "$f.Controls.Add($c)");
   FileWrite(h, "$f.CancelButton = $c");
   FileWrite(h, "$f.Add_Shown({$f.Activate()})");
   FileWrite(h, "$r = $f.ShowDialog()");
   FileWrite(h, "if ($r -eq [System.Windows.Forms.DialogResult]::OK) {");
   FileWrite(h, "  $sel = @()");
   FileWrite(h, "  foreach ($i in $lv.Items) { if ($i.Checked) { $sel += $i.Text } }");
   FileWrite(h, "  Set-Content -Path '" + PsQuote(resFull) + "' -Value ('OK:' + ($sel -join ',')) -Encoding ASCII");
   FileWrite(h, "} else {");
   FileWrite(h, "  Set-Content -Path '" + PsQuote(resFull) + "' -Value 'CANCEL' -Encoding ASCII");
   FileWrite(h, "}");
   FileClose(h);

   if(listed == 0)
   {
      FileDelete(PROT_SCRIPT_FILE, FILE_COMMON);
      Print("[HotkeyTrader] Protect: no open positions on ", InpSymbol);
      return;
   }

   if(!LaunchScript(PROT_SCRIPT_FILE)) return;

   OpenPopup(POPUP_PROTECT);
   PrintFormat("[HotkeyTrader] Protect popup opened (%d position(s))", listed);
}

//+------------------------------------------------------------------+
//| Read and consume a popup result file.                            |
//| Returns false while the file is missing or still locked by       |
//| PowerShell, so the caller simply retries on the next tick.       |
//+------------------------------------------------------------------+
bool ReadResultFile(const string file, string &out)
{
   if(!FileIsExist(file, FILE_COMMON)) return false;

   int h = FileOpen(file, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE) return false;

   out = "";
   if(!FileIsEnding(h)) out = FileReadString(h);
   FileClose(h);
   FileDelete(file, FILE_COMMON);

   StringTrimLeft(out);
   StringTrimRight(out);
   return true;
}

//+------------------------------------------------------------------+
//| Apply the lot popup's answer                                     |
//+------------------------------------------------------------------+
void ApplyLotResult(const string txt)
{
   double v = StringToDouble(txt);
   if(v > 0.0)
   {
      g_lots = NormalizeLot(v);
      PrintFormat("[HotkeyTrader] Lot size set to %s", DoubleToString(g_lots, VolumeDigits()));
   }
   else
      PrintFormat("[HotkeyTrader] Lot input cancelled; kept %s",
                  DoubleToString(g_lots, VolumeDigits()));
}

//+------------------------------------------------------------------+
//| Apply the protect popup's answer ("OK:1,2,3" or "CANCEL")        |
//+------------------------------------------------------------------+
void ApplyProtectResult(const string txt)
{
   if(StringFind(txt, "OK:") != 0)
   {
      PrintFormat("[HotkeyTrader] Protect cancelled; %d position(s) still protected",
                  ArraySize(g_protected));
      return;
   }

   string csv = StringSubstr(txt, 3);
   ArrayResize(g_protected, 0);

   if(StringLen(csv) > 0)
   {
      string parts[];
      int n = StringSplit(csv, ',', parts);
      for(int i = 0; i < n; i++)
      {
         StringTrimLeft(parts[i]);
         StringTrimRight(parts[i]);
         if(StringLen(parts[i]) == 0) continue;
         int k = ArraySize(g_protected);
         ArrayResize(g_protected, k + 1);
         g_protected[k] = (ulong)StringToInteger(parts[i]);
      }
   }

   PrintFormat("[HotkeyTrader] Protected: %d position(s)", ArraySize(g_protected));
}

//+------------------------------------------------------------------+
//| Enter the popup state (hotkeys absorbed until it answers)        |
//+------------------------------------------------------------------+
void OpenPopup(int kind)
{
   g_popup      = kind;
   g_popupSince = GetTickCount64();
}

//+------------------------------------------------------------------+
//| Give up on a popup that never answered and release the hotkeys   |
//+------------------------------------------------------------------+
void AbortPopup()
{
   switch(g_popup)
   {
      case POPUP_LOT:
         FileDelete(LOT_SCRIPT_FILE,  FILE_COMMON);
         FileDelete(LOT_RESULT_FILE,  FILE_COMMON);
         break;
      case POPUP_SL:
         FileDelete(SL_SCRIPT_FILE,   FILE_COMMON);
         FileDelete(SL_RESULT_FILE,   FILE_COMMON);
         break;
      case POPUP_PROTECT:
         FileDelete(PROT_SCRIPT_FILE, FILE_COMMON);
         FileDelete(PROT_RESULT_FILE, FILE_COMMON);
         break;
   }

   g_popup = POPUP_NONE;
   PrintFormat("[HotkeyTrader] Popup gave no answer in %d s — hotkeys released, "
               "nothing changed", InpPopupTimeoutSec);
   UpdateLabel();
}

//+------------------------------------------------------------------+
//| Poll for the open popup's result file and act on it              |
//+------------------------------------------------------------------+
void CheckPopupResult()
{
   string txt = "";

   switch(g_popup)
   {
      case POPUP_LOT:
         if(!ReadResultFile(LOT_RESULT_FILE, txt)) return;
         FileDelete(LOT_SCRIPT_FILE, FILE_COMMON);
         g_popup = POPUP_NONE;
         ApplyLotResult(txt);
         break;

      case POPUP_SL:
      {
         if(!ReadResultFile(SL_RESULT_FILE, txt)) return;
         FileDelete(SL_SCRIPT_FILE, FILE_COMMON);
         g_popup = POPUP_NONE;
         double sl = StringToDouble(txt);
         if(sl > 0.0) ApplySLToAll(sl);
         else         Print("[HotkeyTrader] Set SL cancelled");
         break;
      }

      case POPUP_PROTECT:
         if(!ReadResultFile(PROT_RESULT_FILE, txt)) return;
         FileDelete(PROT_SCRIPT_FILE, FILE_COMMON);
         g_popup = POPUP_NONE;
         ApplyProtectResult(txt);
         break;

      default:
         g_popup = POPUP_NONE;
         return;
   }

   UpdateLabel();
}
//+------------------------------------------------------------------+
