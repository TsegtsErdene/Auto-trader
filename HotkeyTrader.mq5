//+------------------------------------------------------------------+
//|  HotkeyTrader.mq5                                                |
//|  Global-hotkey market-order EA for MetaTrader 5                  |
//|                                                                  |
//|    Numpad 1 → Market Buy  (enter long)                           |
//|    Numpad 2 → Market Sell (enter short)                          |
//|    Numpad 0 → Break Even        – SL to entry on all positions   |
//|    Numpad 3 → 20-pip Break Even – SL locks +20 pips of profit    |
//|    Numpad 5 → Trailing SL (one-shot) – SL to 10 pips from price  |
//|    Numpad 6 → Lot size – pops a box to type the lot manually     |
//|                                                                  |
//|  Works globally even when MT5 is minimized. NumLock must be ON   |
//|  so the keypad sends Numpad VK codes (0x60-0x69).                |
//+------------------------------------------------------------------+

#property copyright "HotkeyTrader"
#property version   "4.00"
#property strict

//--- WinAPI imports
#import "user32.dll"
   int GetAsyncKeyState(int vKey);
#import
#import "shell32.dll"
   int ShellExecuteW(int hwnd, string oper, string file, string params, string dir, int show);
#import

//--- IPC file names (in MT5 Common Files\Files\)
#define LOT_SCRIPT_FILE "ht_lot_input.ps1"
#define LOT_RESULT_FILE "ht_lot_result.txt"

//--- Input parameters
input string InpSymbol         = "XAUUSD"; // Trading symbol
input double InpLots           = 0.01;     // Starting lot size per order
input int    InpLongKey        = 0x61;     // Long  / Buy  key VK (Numpad 1)
input int    InpShortKey       = 0x62;     // Short / Sell key VK (Numpad 2)
input int    InpBEKey          = 0x60;     // Break Even key VK (Numpad 0)
input int    InpBE20Key        = 0x63;     // 20-pip Break Even key VK (Numpad 3)
input int    InpTrailKey       = 0x65;     // Trailing SL key VK (Numpad 5)
input int    InpLotKey         = 0x66;     // Lot-size input key VK (Numpad 6)
input int    InpPointsPerPip   = 10;       // Points per pip (gold: 10 → 1 pip = 0.10)
input int    InpBE20Pips       = 20;       // Profit locked by 20-pip Break Even (pips)
input int    InpTrailPips      = 10;       // Trailing SL distance from price (pips)
input ulong  InpMagic          = 20260408; // EA magic number
input uint   InpSlippagePoints = 20;       // Max slippage in points

//--- Globals (edge-detection state — one fire per physical keypress)
bool   g_longDown     = false;
bool   g_shortDown    = false;
bool   g_beDown       = false;
bool   g_be20Down     = false;
bool   g_trailDown    = false;
bool   g_lotDown      = false;

//--- Active lot size (starts at InpLots, changed via the Numpad 6 popup)
double g_lots         = 0.0;
//--- True while the lot-input popup is open (suppresses all hotkeys)
bool   g_lotPopupOpen = false;

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
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   g_lots = NormalizeLot(InpLots);
   FileDelete(LOT_RESULT_FILE, FILE_COMMON); // clear any stale popup result
   EventSetMillisecondTimer(10);
   UpdateLabel();
   PrintFormat("[HotkeyTrader] Ready | %s | Lots=%s | "
               "Long=0x%02X Short=0x%02X  BE=0x%02X  20pBE=0x%02X  Trail=0x%02X  Lot=0x%02X | "
               "1 pip = %d points",
               InpSymbol, DoubleToString(g_lots, VolumeDigits()), InpLongKey, InpShortKey,
               InpBEKey, InpBE20Key, InpTrailKey, InpLotKey, InpPointsPerPip);
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
   //--- While the lot popup is open, absorb every key state without acting.
   //    The numpad digits the user types into the box are still visible to
   //    GetAsyncKeyState globally, so acting on them here would fire trades.
   if(g_lotPopupOpen)
   {
      g_longDown  = KeyDown(InpLongKey);
      g_shortDown = KeyDown(InpShortKey);
      g_beDown    = KeyDown(InpBEKey);
      g_be20Down  = KeyDown(InpBE20Key);
      g_trailDown = KeyDown(InpTrailKey);
      g_lotDown   = KeyDown(InpLotKey);
      CheckLotResult();
      return;
   }

   bool longNow  = KeyDown(InpLongKey);
   bool shortNow = KeyDown(InpShortKey);
   bool beNow    = KeyDown(InpBEKey);
   bool be20Now  = KeyDown(InpBE20Key);
   bool trailNow = KeyDown(InpTrailKey);
   bool lotNow   = KeyDown(InpLotKey);

   //--- Numpad 1 → enter long (edge-triggered)
   if(longNow && !g_longDown)
      DoBuy();
   g_longDown = longNow;

   //--- Numpad 2 → enter short (edge-triggered)
   if(shortNow && !g_shortDown)
      DoSell();
   g_shortDown = shortNow;

   //--- Numpad 0 → break even: SL to entry (edge-triggered)
   if(beNow && !g_beDown)
      DoBreakEven(0);
   g_beDown = beNow;

   //--- Numpad 3 → 20-pip break even: SL locks +20 pips (edge-triggered)
   if(be20Now && !g_be20Down)
      DoBreakEven(InpBE20Pips);
   g_be20Down = be20Now;

   //--- Numpad 5 → trailing SL one-shot: SL to 10 pips from price (edge-triggered)
   if(trailNow && !g_trailDown)
      DoTrailingStop();
   g_trailDown = trailNow;

   //--- Numpad 6 → open manual lot-size popup (edge-triggered)
   if(lotNow && !g_lotDown)
      ShowLotInput();
   g_lotDown = lotNow;
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
      "  Lots        : %s\n"
      "  Long  (Buy) : VK 0x%02X\n"
      "  Short (Sell): VK 0x%02X\n"
      "  Break Even  : VK 0x%02X\n"
      "  20-pip BE   : VK 0x%02X  (+%d pips)\n"
      "  Trailing SL : VK 0x%02X  (%d pips from price)\n"
      "  Set Lots    : VK 0x%02X  (type manually)\n"
      "  1 pip       = %d points",
      InpSymbol, DoubleToString(g_lots, VolumeDigits()), InpLongKey, InpShortKey, InpBEKey,
      InpBE20Key, InpBE20Pips, InpTrailKey, InpTrailPips, InpLotKey, InpPointsPerPip));
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
   req.volume       = g_lots;
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
//| Open the manual lot-size popup.                                  |
//| Writes a WinForms PowerShell script to the Common Files\Files    |
//| folder and launches it hidden. The script shows a top-most input |
//| box pre-filled with the current lot and writes the typed value   |
//| to LOT_RESULT_FILE. CheckLotResult() picks it up.                |
//+------------------------------------------------------------------+
void ShowLotInput()
{
   string common  = TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "\\Files\\";
   string ps1Full = common + LOT_SCRIPT_FILE;
   string resFull = common + LOT_RESULT_FILE;
   string current = DoubleToString(g_lots, VolumeDigits());

   FileDelete(LOT_RESULT_FILE, FILE_COMMON); // drop any stale result

   int h = FileOpen(LOT_SCRIPT_FILE, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
   {
      PrintFormat("[HotkeyTrader] Lot popup: cannot write script (err=%d)", GetLastError());
      return;
   }

   FileWrite(h, "Add-Type -AssemblyName System.Windows.Forms");
   FileWrite(h, "Add-Type -AssemblyName System.Drawing");
   FileWrite(h, "$f = New-Object System.Windows.Forms.Form");
   FileWrite(h, "$f.Text = 'Lot Size'");
   FileWrite(h, "$f.Size = New-Object System.Drawing.Size(260,150)");
   FileWrite(h, "$f.StartPosition = 'CenterScreen'");
   FileWrite(h, "$f.TopMost = $true");
   FileWrite(h, "$f.FormBorderStyle = 'FixedDialog'");
   FileWrite(h, "$f.MaximizeBox = $false");
   FileWrite(h, "$f.MinimizeBox = $false");
   FileWrite(h, "$l = New-Object System.Windows.Forms.Label");
   FileWrite(h, "$l.Text = 'Enter lot size:'");
   FileWrite(h, "$l.AutoSize = $true");
   FileWrite(h, "$l.Location = New-Object System.Drawing.Point(12,15)");
   FileWrite(h, "$f.Controls.Add($l)");
   FileWrite(h, "$t = New-Object System.Windows.Forms.TextBox");
   FileWrite(h, "$t.Location = New-Object System.Drawing.Point(12,38)");
   FileWrite(h, "$t.Size = New-Object System.Drawing.Size(228,22)");
   FileWrite(h, "$t.Text = '" + current + "'");
   FileWrite(h, "$f.Controls.Add($t)");
   FileWrite(h, "$ok = New-Object System.Windows.Forms.Button");
   FileWrite(h, "$ok.Text = 'OK'");
   FileWrite(h, "$ok.Location = New-Object System.Drawing.Point(84,75)");
   FileWrite(h, "$ok.DialogResult = [System.Windows.Forms.DialogResult]::OK");
   FileWrite(h, "$f.Controls.Add($ok)");
   FileWrite(h, "$f.AcceptButton = $ok");
   FileWrite(h, "$c = New-Object System.Windows.Forms.Button");
   FileWrite(h, "$c.Text = 'Cancel'");
   FileWrite(h, "$c.Location = New-Object System.Drawing.Point(165,75)");
   FileWrite(h, "$c.DialogResult = [System.Windows.Forms.DialogResult]::Cancel");
   FileWrite(h, "$f.Controls.Add($c)");
   FileWrite(h, "$f.CancelButton = $c");
   FileWrite(h, "$f.Add_Shown({$f.Activate(); $t.Focus(); $t.SelectAll()})");
   FileWrite(h, "$r = $f.ShowDialog()");
   FileWrite(h, "if ($r -eq [System.Windows.Forms.DialogResult]::OK) {");
   FileWrite(h, "  Set-Content -Path '" + resFull + "' -Value $t.Text -Encoding ASCII");
   FileWrite(h, "} else {");
   FileWrite(h, "  Set-Content -Path '" + resFull + "' -Value '' -Encoding ASCII");
   FileWrite(h, "}");
   FileClose(h);

   string params = "-ExecutionPolicy Bypass -WindowStyle Hidden -NoProfile -File \"" + ps1Full + "\"";
   int rc = ShellExecuteW(0, "open", "powershell.exe", params, "", 0);
   if(rc <= 32)
   {
      PrintFormat("[HotkeyTrader] Lot popup: launch failed rc=%d", rc);
      return;
   }
   g_lotPopupOpen = true;
   Print("[HotkeyTrader] Lot input popup opened");
}

//+------------------------------------------------------------------+
//| Poll for the lot popup's result file; apply it when it appears.  |
//+------------------------------------------------------------------+
void CheckLotResult()
{
   if(!FileIsExist(LOT_RESULT_FILE, FILE_COMMON))
      return;

   int h = FileOpen(LOT_RESULT_FILE, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
      return; // still being written/locked by PowerShell — retry next tick

   string txt = "";
   if(!FileIsEnding(h)) txt = FileReadString(h);
   FileClose(h);

   FileDelete(LOT_RESULT_FILE, FILE_COMMON);
   FileDelete(LOT_SCRIPT_FILE, FILE_COMMON);
   g_lotPopupOpen = false;

   StringTrimLeft(txt);
   StringTrimRight(txt);

   double v = StringToDouble(txt);
   if(v > 0.0)
   {
      g_lots = NormalizeLot(v);
      PrintFormat("[HotkeyTrader] Lot size set to %s", DoubleToString(g_lots, VolumeDigits()));
      UpdateLabel();
   }
   else
   {
      PrintFormat("[HotkeyTrader] Lot input cancelled; kept %s",
                  DoubleToString(g_lots, VolumeDigits()));
   }
}
//+------------------------------------------------------------------+
