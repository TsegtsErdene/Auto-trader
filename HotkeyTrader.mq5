//+------------------------------------------------------------------+
//|  HotkeyTrader.mq5                                                |
//|  Global-hotkey market-order EA for MetaTrader 5                  |
//|                                                                  |
//|    CE          → Market Buy  (one per press)                     |
//|    +/-         → Market Sell (one per press)                     |
//|    Alt + CE    → Flatten – close ALL positions                   |
//|    Alt + +/-   → Half – close 50% of each open position          |
//|                                                                  |
//|  Works globally even when MT5 is minimized.                      |
//+------------------------------------------------------------------+

#property copyright "HotkeyTrader"
#property version   "3.00"
#property strict

//--- WinAPI imports
#import "user32.dll"
   int  GetAsyncKeyState(int vKey);
   long FindWindowW(string lpClassName, string lpWindowName);
   bool PostMessageW(long hWnd, int Msg, int wParam, long lParam);
#import
#import "shell32.dll"
   long ShellExecuteW(long hwnd, string op, string file, string params, string dir, int show);
#import

#define WM_CLOSE  0x0010
#define VK_ALT    0x12
#define VK_ENTER  0x0D
#define VK_INSERT        0x2D
#define FILTER_DATA_FILE "ht_positions_data.csv"
#define VK_CTRL   0x11
#define VK_SHIFT  0x10

//--- Input parameters
input string InpSymbol         = "XAUUSD"; // Trading symbol
input double InpLots           = 0.01;     // Lot size per order
input int    InpBuyKey         = 0x2E;     // CE  key VK (Delete = 0x2E)
input int    InpSellKey        = 0x78;     // +/- key VK (F9    = 0x78)
input string InpOrderWndTitle  = "Order";  // MT5 Order dialog title
input int    InpBEOffsetPts    = 10;       // Break Even SL offset in points (above entry for buy, below for sell)
input ulong  InpMagic          = 20260408; // EA magic number
input uint   InpSlippagePoints = 20;       // Max slippage in points

//--- Globals
bool g_buyDown       = false;
bool g_sellDown      = false;
bool g_altBuyDown    = false;   // Alt+CE    edge state
bool g_altSellDown   = false;   // Alt+/-    edge state
bool g_altEnterDown  = false;   // Alt+Enter edge state
bool  g_altInsertDown   = false;   // Alt+Insert  edge state
bool  g_ctrlInsertDown  = false;   // Ctrl+Insert edge state
bool  g_ctrlShiftDown   = false;   // Ctrl+Shift   edge state
bool  g_slWaiting      = false;   // waiting for SL input result file
bool  g_toggleWaiting  = false;   // waiting for trading toggle result file
bool  g_filterOpen     = false;   // true while filter window is open
int   g_filterTick     = 0;       // throttle counter for data file writes
ulong g_excludedTickets[];        // tickets excluded from bulk operations
bool     g_tradingEnabled  = false;  // trading is DISABLED by default
datetime g_lastTradeTime   = 0;      // last time a trade was sent
int  g_flattenTicks  = 0;       // retry flatten N ticks after Alt+CE released

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
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   EventSetMillisecondTimer(10);
   UpdateLabel();
   PrintFormat("[HotkeyTrader] Ready | %s | Lots=%.2f | "
               "Buy=0x%02X  Sell=0x%02X  Flatten=Alt+Buy  Half=Alt+Sell | "
               "Trading=%s  (Ctrl+Shift to toggle)",
               InpSymbol, InpLots, InpBuyKey, InpSellKey,
               g_tradingEnabled ? "ENABLED" : "DISABLED");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   FileDelete(FILTER_DATA_FILE, FILE_COMMON);
   Comment("");
   Print("[HotkeyTrader] Stopped.");
}

void OnTick() {}

//+------------------------------------------------------------------+
//| OnTimer – global hotkey polling loop (runs every 10 ms)          |
//+------------------------------------------------------------------+
void OnTimer()
{
   //--- Poll for trading toggle result written by PowerShell
   if(g_toggleWaiting && FileIsExist("ht_toggle_result.txt", FILE_COMMON))
   {
      int fh = FileOpen("ht_toggle_result.txt", FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
      string text = "";
      if(fh != INVALID_HANDLE) { text = FileReadString(fh); FileClose(fh); }
      FileDelete("ht_toggle_result.txt", FILE_COMMON);
      g_toggleWaiting  = false;
      g_tradingEnabled = (text == "1");
      if(g_tradingEnabled) g_lastTradeTime = TimeCurrent();  // reset the 30-min timer
      UpdateLabel();
      PrintFormat("[HotkeyTrader] Trading %s", g_tradingEnabled ? "ENABLED" : "DISABLED");
   }

   //--- Auto-disable after 30 minutes of no trading
   if(g_tradingEnabled && g_lastTradeTime > 0 &&
      (TimeCurrent() - g_lastTradeTime) >= 30 * 60)
   {
      g_tradingEnabled = false;
      UpdateLabel();
      Print("[HotkeyTrader] Trading auto-disabled: 30 minutes without a trade");
   }

   //--- Write live position data for the filter popup (every 500 ms)
   if(g_filterOpen)
   {
      g_filterTick++;
      if(g_filterTick >= 50) { g_filterTick = 0; WritePositionsDataFile(); }
   }

   //--- Apply: update exclusions whenever result file appears (Apply or OK)
   if(g_filterOpen && FileIsExist("ht_filter_result.txt", FILE_COMMON))
   {
      int fh = FileOpen("ht_filter_result.txt", FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
      string text = "";
      if(fh != INVALID_HANDLE) { text = FileReadString(fh); FileClose(fh); }
      FileDelete("ht_filter_result.txt", FILE_COMMON);

      ArrayResize(g_excludedTickets, 0);
      if(StringLen(text) > 0)
      {
         string parts[];
         int n = StringSplit(text, ',', parts);
         ArrayResize(g_excludedTickets, n);
         for(int i = 0; i < n; i++)
            g_excludedTickets[i] = (ulong)StringToInteger(parts[i]);
      }
      PrintFormat("[HotkeyTrader] Filter applied: %d ticket(s) protected",
                  ArraySize(g_excludedTickets));
   }

   //--- Done: window closed → stop live data feed
   if(g_filterOpen && FileIsExist("ht_filter_done.txt", FILE_COMMON))
   {
      FileDelete("ht_filter_done.txt", FILE_COMMON);
      FileDelete(FILTER_DATA_FILE, FILE_COMMON);
      g_filterOpen = false;
   }

   //--- Poll for SL input result written by PowerShell
   if(g_slWaiting && FileIsExist("ht_sl_result.txt", FILE_COMMON))
   {
      int fh = FileOpen("ht_sl_result.txt", FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
      string text = "";
      if(fh != INVALID_HANDLE) { text = FileReadString(fh); FileClose(fh); }
      FileDelete("ht_sl_result.txt", FILE_COMMON);
      g_slWaiting = false;

      double slPrice = StringToDouble(text);
      if(slPrice > 0)
         ApplySLToAll(slPrice);
      else
         Print("[HotkeyTrader] Set SL: cancelled or invalid input");
   }

   bool altNow    = (GetAsyncKeyState(VK_ALT)     & 0x8000) != 0;
   bool ctrlNow   = (GetAsyncKeyState(VK_CTRL)   & 0x8000) != 0;
   bool shiftNow  = (GetAsyncKeyState(VK_SHIFT)  & 0x8000) != 0;
   bool insertNow = (GetAsyncKeyState(VK_INSERT) & 0x8000) != 0;
   bool enterNow  = (GetAsyncKeyState(VK_ENTER)  & 0x8000) != 0;
   bool buyNow    = (GetAsyncKeyState(InpBuyKey)  & 0x8000) != 0;
   bool sellNow   = (GetAsyncKeyState(InpSellKey) & 0x8000) != 0;

   //--- Alt + CE → Flatten all (retries for 50 ms after release)
   if(altNow && buyNow)
   {
      DoFlatten();
      g_altBuyDown   = true;
      g_flattenTicks = 5;
      g_buyDown      = buyNow;   // prevent buy firing after Alt releases
      return;
   }
   if(g_altBuyDown && !buyNow)
      g_altBuyDown = false;

   //--- Flatten retry ticks (catches positions that filled just before the key press)
   if(g_flattenTicks > 0)
   {
      DoFlatten();
      g_flattenTicks--;
      g_buyDown  = buyNow;
      g_sellDown = sellNow;
      return;
   }

   //--- Alt + +/- → close 50% of each position (edge-triggered)
   if(altNow && sellNow)
   {
      CloseOrderDialog();
      if(!g_altSellDown)
         DoHalf();
      g_altSellDown = true;
      g_sellDown    = sellNow;   // prevent sell firing after Alt releases
      return;
   }
   g_altSellDown = false;

   //--- Alt + Enter → Break Even all positions (edge-triggered)
   if(altNow && enterNow)
   {
      if(!g_altEnterDown)
         DoBreakEven();
      g_altEnterDown = true;
      return;
   }
   g_altEnterDown = false;

   //--- Alt + Insert → show SL price input field (edge-triggered)
   if(altNow && insertNow)
   {
      if(!g_altInsertDown)
         ShowSLInput();
      g_altInsertDown = true;
      return;
   }
   g_altInsertDown = false;

   //--- Ctrl + Insert → show trade filter popup (edge-triggered)
   if(ctrlNow && insertNow && !altNow && !shiftNow)
   {
      if(!g_ctrlInsertDown)
         ShowTradeFilter();
      g_ctrlInsertDown = true;
      return;
   }
   g_ctrlInsertDown = false;

   //--- Ctrl + Shift → show trading enable/disable popup (edge-triggered)
   if(ctrlNow && shiftNow)
   {
      if(!g_ctrlShiftDown)
         ShowTradingToggle();
      g_ctrlShiftDown = true;
      return;
   }
   g_ctrlShiftDown = false;

   //--- Block all trading actions when disabled
   if(!g_tradingEnabled) return;

   //--- CE alone → Buy (edge-triggered)
   if(buyNow && !altNow && !g_buyDown)
      DoBuy();
   g_buyDown = buyNow;

   //--- +/- alone → Sell (edge-triggered) + close MT5 Order dialog
   if(sellNow && !altNow)
   {
      CloseOrderDialog();
      if(!g_sellDown)
         DoSell();
   }
   g_sellDown = sellNow;
}

//+------------------------------------------------------------------+
//| Close the MT5 Order dialog if open                               |
//+------------------------------------------------------------------+
void CloseOrderDialog()
{
   long hWnd = FindWindowW(NULL, InpOrderWndTitle);
   if(hWnd != 0)
      PostMessageW(hWnd, WM_CLOSE, 0, 0);
}

//+------------------------------------------------------------------+
//| Refresh on-chart info label                                      |
//+------------------------------------------------------------------+
void UpdateLabel()
{
   string status = g_tradingEnabled ? "✔ ENABLED" : "✘ DISABLED";
   Comment(StringFormat(
      "  HotkeyTrader v3          [ %s ]  (Ctrl+Shift to change)\n"
      "  ─────────────────────────────────────\n"
      "  Symbol    : %s\n"
      "  Lots      : %.2f\n"
      "  Buy       : VK 0x%02X\n"
      "  Sell      : VK 0x%02X\n"
      "  Flatten   : Alt + Buy\n"
      "  Half      : Alt + Sell\n"
      "  Break Even: Alt + Enter\n"
      "  Set SL    : Alt + Insert\n"
      "  Filter    : Ctrl + Insert",
      status, InpSymbol, InpLots, InpBuyKey, InpSellKey));
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
   {
      g_lastTradeTime = TimeCurrent();
      PrintFormat("[HotkeyTrader] BUY sent reqid=%u", res.request_id);
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
   req.volume       = InpLots;
   req.type         = ORDER_TYPE_SELL;
   req.price        = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   req.deviation    = InpSlippagePoints;
   req.magic        = InpMagic;
   req.type_filling = SymbolFilling(InpSymbol);

   if(!OrderSendAsync(req, res))
      PrintFormat("[HotkeyTrader] Sell FAILED retcode=%u", res.retcode);
   else
   {
      g_lastTradeTime = TimeCurrent();
      PrintFormat("[HotkeyTrader] SELL sent reqid=%u", res.request_id);
   }
}

//+------------------------------------------------------------------+
//| Close all positions on InpSymbol (async, all at once)            |
//+------------------------------------------------------------------+
void DoFlatten()
{
   if(PositionsTotal() == 0) return;

   ENUM_ORDER_TYPE_FILLING filling = SymbolFilling(InpSymbol);
   int sent = 0;

   ulong tickets[];
   int total = PositionsTotal();
   ArrayResize(tickets, total);
   int count = 0;
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol) continue;
      if(IsExcluded(ticket)) continue;
      tickets[count++] = ticket;
   }

   for(int i = 0; i < count; i++)
   {
      if(!PositionSelectByTicket(tickets[i])) continue;

      double volume = PositionGetDouble(POSITION_VOLUME);
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
      req.position     = tickets[i];
      req.magic        = InpMagic;
      req.type_filling = filling;

      if(OrderSendAsync(req, res)) sent++;
      else PrintFormat("[HotkeyTrader] Flatten FAILED ticket=%I64u retcode=%u",
                       tickets[i], res.retcode);
   }

   if(count > 0)
   {
      if(sent > 0) g_lastTradeTime = TimeCurrent();
      PrintFormat("[HotkeyTrader] FLATTEN: %d close(s) sent", sent);
   }
}

//+------------------------------------------------------------------+
//| Move SL of all open positions to entry price (Break Even)        |
//+------------------------------------------------------------------+
void DoBreakEven()
{
   int moved = 0;
   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol) continue;
      if(IsExcluded(ticket)) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double point     = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
      double offset    = InpBEOffsetPts * point;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double bePrice = (ptype == POSITION_TYPE_BUY) ? openPrice + offset
                                                     : openPrice - offset;

      // Skip if SL is already at or better than the BE target
      bool alreadyBE = (ptype == POSITION_TYPE_BUY  && currentSL >= bePrice) ||
                       (ptype == POSITION_TYPE_SELL && currentSL <= bePrice && currentSL > 0);
      if(alreadyBE) continue;

      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action   = TRADE_ACTION_SLTP;
      req.symbol   = InpSymbol;
      req.position = ticket;
      req.sl       = bePrice;
      req.tp       = currentTP;

      if(OrderSend(req, res))
         moved++;
      else
         PrintFormat("[HotkeyTrader] BE FAILED ticket=%I64u retcode=%u", ticket, res.retcode);
   }

   if(moved == 0)
      Print("[HotkeyTrader] BE: no positions needed adjusting");
   else
      PrintFormat("[HotkeyTrader] BE: moved %d position(s) to break even", moved);
}

//+------------------------------------------------------------------+
//| Check if a ticket is excluded from bulk operations               |
//+------------------------------------------------------------------+
bool IsExcluded(ulong ticket)
{
   for(int i = 0; i < ArraySize(g_excludedTickets); i++)
      if(g_excludedTickets[i] == ticket) return true;
   return false;
}

//+------------------------------------------------------------------+
//| Write live position data to CSV for PowerShell filter popup      |
//+------------------------------------------------------------------+
void WritePositionsDataFile()
{
   int fh = FileOpen(FILTER_DATA_FILE, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(fh == INVALID_HANDLE) return;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol) continue;

      double vol    = PositionGetDouble(POSITION_VOLUME);
      double open   = PositionGetDouble(POSITION_PRICE_OPEN);
      double profit = PositionGetDouble(POSITION_PROFIT);
      string dir    = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      double price  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                      ? SymbolInfoDouble(InpSymbol, SYMBOL_BID)
                      : SymbolInfoDouble(InpSymbol, SYMBOL_ASK);

      FileWrite(fh, StringFormat("%I64u,%s,%.2f,%.2f,%.2f,%.2f",
                                 ticket, dir, vol, open, price, profit));
   }
   FileClose(fh);
}

//+------------------------------------------------------------------+
//| Show trade filter popup – check trades to include in bulk ops    |
//+------------------------------------------------------------------+
void ShowTradeFilter()
{
   string commonFiles = TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "\\Files\\";
   string ps1Path     = commonFiles + "ht_filter_input.ps1";
   string resultPath  = commonFiles + "ht_filter_result.txt";
   string donePath    = commonFiles + "ht_filter_done.txt";
   string dataPath    = commonFiles + FILTER_DATA_FILE;

   FileDelete("ht_filter_result.txt", FILE_COMMON);

   // Snapshot positions for initial display
   int count = 0;
   string itemLines = "";
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol) continue;

      double vol    = PositionGetDouble(POSITION_VOLUME);
      double open   = PositionGetDouble(POSITION_PRICE_OPEN);
      double profit = PositionGetDouble(POSITION_PROFIT);
      string dir    = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      double price  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                      ? SymbolInfoDouble(InpSymbol, SYMBOL_BID)
                      : SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
      string chk    = IsExcluded(ticket) ? "$true" : "$false";

      itemLines += StringFormat(
         "$it = New-Object System.Windows.Forms.ListViewItem('%I64u')\n"
         "$it.SubItems.Add('%s') | Out-Null\n"
         "$it.SubItems.Add('%.2f') | Out-Null\n"
         "$it.SubItems.Add('%.2f') | Out-Null\n"
         "$it.SubItems.Add('%.2f') | Out-Null\n"
         "$it.SubItems.Add('%.2f') | Out-Null\n"
         "$it.Checked = %s\n"
         "$lv.Items.Add($it) | Out-Null\n",
         ticket, dir, vol, open, price, profit, chk);
      count++;
   }

   if(count == 0)
   {
      Print("[HotkeyTrader] Filter: no open positions on ", InpSymbol);
      return;
   }

   // Write initial data file so timer has data immediately
   g_filterOpen = true;
   g_filterTick = 0;
   WritePositionsDataFile();

   int formH = 100 + MathMax(count, 3) * 20 + 72;

   int fh = FileOpen("ht_filter_input.ps1", FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(fh == INVALID_HANDLE) { Print("[HotkeyTrader] Cannot write filter PS1"); return; }

   FileWrite(fh, "Add-Type -AssemblyName System.Windows.Forms");
   FileWrite(fh, "Add-Type -AssemblyName System.Drawing");
   FileWrite(fh, "$dataPath = '" + dataPath + "'");
   FileWrite(fh, "$form = New-Object System.Windows.Forms.Form");
   FileWrite(fh, "$form.Text = 'Trade Filter - " + InpSymbol + "'");
   FileWrite(fh, "$form.Size = New-Object System.Drawing.Size(540," + IntegerToString(formH) + ")");
   FileWrite(fh, "$form.StartPosition = 'CenterScreen'");
   FileWrite(fh, "$form.TopMost = $true");
   FileWrite(fh, "$form.FormBorderStyle = 'FixedDialog'");
   FileWrite(fh, "$form.MaximizeBox = $false");
   FileWrite(fh, "$form.MinimizeBox = $false");
   FileWrite(fh, "$lbl = New-Object System.Windows.Forms.Label");
   FileWrite(fh, "$lbl.Text = 'Checked = PROTECTED from Flatten / Half / BE / Set SL'");
   FileWrite(fh, "$lbl.Location = New-Object System.Drawing.Point(10,8)");
   FileWrite(fh, "$lbl.Size = New-Object System.Drawing.Size(510,18)");
   FileWrite(fh, "$lv = New-Object System.Windows.Forms.ListView");
   FileWrite(fh, "$lv.View = [System.Windows.Forms.View]::Details");
   FileWrite(fh, "$lv.CheckBoxes = $true");
   FileWrite(fh, "$lv.FullRowSelect = $true");
   FileWrite(fh, "$lv.GridLines = $true");
   FileWrite(fh, "$lv.Location = New-Object System.Drawing.Point(10,30)");
   FileWrite(fh, "$lv.Size = New-Object System.Drawing.Size(510," + IntegerToString(MathMax(count,3)*20+4) + ")");
   FileWrite(fh, "$lv.Columns.Add('Ticket',  100) | Out-Null");
   FileWrite(fh, "$lv.Columns.Add('Dir',      40) | Out-Null");
   FileWrite(fh, "$lv.Columns.Add('Vol',      45) | Out-Null");
   FileWrite(fh, "$lv.Columns.Add('Open',     80) | Out-Null");
   FileWrite(fh, "$lv.Columns.Add('Price',    80) | Out-Null");
   FileWrite(fh, "$lv.Columns.Add('P&L',      80) | Out-Null");
   FileWrite(fh, itemLines);
   // Total P&L label (initial value computed from items already added)
   FileWrite(fh, "$lblTotal = New-Object System.Windows.Forms.Label");
   FileWrite(fh, "$lblTotal.Location = New-Object System.Drawing.Point(10," + IntegerToString(MathMax(count,3)*20+38) + ")");
   FileWrite(fh, "$lblTotal.Size = New-Object System.Drawing.Size(510,20)");
   FileWrite(fh, "$lblTotal.Font = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)");
   FileWrite(fh, "{ $t=0; foreach($i in $lv.Items){$v=0; if([double]::TryParse($i.SubItems[5].Text,[ref]$v)){$t+=$v}}; $lblTotal.Text='Total P&L:  '+$t.ToString('F2') } | % Invoke");
   // Paths passed into the PS1 script
   FileWrite(fh, "$donePath = '" + donePath + "'");
   // Helper function – collect checked tickets and write result file
   FileWrite(fh, "function Write-FilterResult {");
   FileWrite(fh, "  $excl = @()");
   FileWrite(fh, "  foreach ($item in $lv.Items) { if ($item.Checked) { $excl += $item.Text } }");
   FileWrite(fh, "  [System.IO.File]::WriteAllText('" + resultPath + "', ($excl -join ','))");
   FileWrite(fh, "}");
   // Apply button – writes result, keeps window open
   FileWrite(fh, "$btnApply = New-Object System.Windows.Forms.Button");
   FileWrite(fh, "$btnApply.Text = 'Apply'");
   FileWrite(fh, "$btnApply.Location = New-Object System.Drawing.Point(120," + IntegerToString(MathMax(count,3)*20+62) + ")");
   FileWrite(fh, "$btnApply.Size = New-Object System.Drawing.Size(80,26)");
   FileWrite(fh, "$btnApply.Add_Click({ Write-FilterResult })");
   // OK button – writes result then closes window
   FileWrite(fh, "$btnOK = New-Object System.Windows.Forms.Button");
   FileWrite(fh, "$btnOK.Text = 'OK'");
   FileWrite(fh, "$btnOK.Location = New-Object System.Drawing.Point(310," + IntegerToString(MathMax(count,3)*20+62) + ")");
   FileWrite(fh, "$btnOK.Size = New-Object System.Drawing.Size(80,26)");
   FileWrite(fh, "$btnOK.Add_Click({ Write-FilterResult; $form.Close() })");
   FileWrite(fh, "$form.Controls.AddRange(@($lbl,$lv,$lblTotal,$btnApply,$btnOK))");
   FileWrite(fh, "$form.AcceptButton = $btnOK");
   // Real-time update timer (500 ms)
   FileWrite(fh, "$timer = New-Object System.Windows.Forms.Timer");
   FileWrite(fh, "$timer.Interval = 500");
   FileWrite(fh, "$timer.Add_Tick({");
   FileWrite(fh, "  if (Test-Path $dataPath) {");
   FileWrite(fh, "    try {");
   FileWrite(fh, "      $lines = [System.IO.File]::ReadAllLines($dataPath)");
   FileWrite(fh, "      foreach ($line in $lines) {");
   FileWrite(fh, "        $p = $line.Split(',')");
   FileWrite(fh, "        if ($p.Count -lt 6) { continue }");
   FileWrite(fh, "        foreach ($item in $lv.Items) {");
   FileWrite(fh, "          if ($item.Text -eq $p[0]) {");
   FileWrite(fh, "            $item.SubItems[4].Text = $p[4]");
   FileWrite(fh, "            $item.SubItems[5].Text = $p[5]");
   FileWrite(fh, "            break");
   FileWrite(fh, "          }");
   FileWrite(fh, "        }");
   FileWrite(fh, "      }");
   FileWrite(fh, "    $t=0; foreach($i in $lv.Items){$v=0; if([double]::TryParse($i.SubItems[5].Text,[ref]$v)){$t+=$v}}");
   FileWrite(fh, "    $lblTotal.Text = 'Total P&L:  '+$t.ToString('F2')");
   FileWrite(fh, "    } catch {}");
   FileWrite(fh, "  }");
   FileWrite(fh, "})");
   FileWrite(fh, "$timer.Start()");
   // FormClosed: stop timer + signal EA the window is gone
   FileWrite(fh, "$form.Add_FormClosed({");
   FileWrite(fh, "  $timer.Stop()");
   FileWrite(fh, "  [System.IO.File]::WriteAllText($donePath, '')");
   FileWrite(fh, "})");
   FileWrite(fh, "$form.ShowDialog() | Out-Null");
   FileClose(fh);

   ShellExecuteW(0, "open", "powershell.exe",
                 "-WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + ps1Path + "\"",
                 "", 0);

   Print("[HotkeyTrader] Trade filter dialog opened (real-time updates every 500ms)");
}

//+------------------------------------------------------------------+
//| Show trading enable/disable popup (Ctrl+Shift)                   |
//+------------------------------------------------------------------+
void ShowTradingToggle()
{
   string commonFiles = TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "\\Files\\";
   string ps1Path     = commonFiles + "ht_toggle_input.ps1";
   string resultPath  = commonFiles + "ht_toggle_result.txt";

   FileDelete("ht_toggle_result.txt", FILE_COMMON);

   string checkedStr = g_tradingEnabled ? "$true" : "$false";

   int fh = FileOpen("ht_toggle_input.ps1", FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(fh == INVALID_HANDLE) { Print("[HotkeyTrader] Cannot write toggle PS1"); return; }
   FileWrite(fh, "Add-Type -AssemblyName System.Windows.Forms");
   FileWrite(fh, "Add-Type -AssemblyName System.Drawing");
   FileWrite(fh, "$form = New-Object System.Windows.Forms.Form");
   FileWrite(fh, "$form.Text = 'HotkeyTrader'");
   FileWrite(fh, "$form.Size = New-Object System.Drawing.Size(260, 130)");
   FileWrite(fh, "$form.StartPosition = 'CenterScreen'");
   FileWrite(fh, "$form.TopMost = $true");
   FileWrite(fh, "$form.FormBorderStyle = 'FixedDialog'");
   FileWrite(fh, "$form.MaximizeBox = $false");
   FileWrite(fh, "$form.MinimizeBox = $false");
   FileWrite(fh, "$chk = New-Object System.Windows.Forms.CheckBox");
   FileWrite(fh, "$chk.Text = 'Enable Trading (" + InpSymbol + ")'");
   FileWrite(fh, "$chk.Location = New-Object System.Drawing.Point(20,20)");
   FileWrite(fh, "$chk.Size = New-Object System.Drawing.Size(210,24)");
   FileWrite(fh, "$chk.Checked = " + checkedStr);
   FileWrite(fh, "$btn = New-Object System.Windows.Forms.Button");
   FileWrite(fh, "$btn.Text = 'OK'");
   FileWrite(fh, "$btn.Location = New-Object System.Drawing.Point(80,55)");
   FileWrite(fh, "$btn.DialogResult = 'OK'");
   FileWrite(fh, "$form.Controls.AddRange(@($chk,$btn))");
   FileWrite(fh, "$form.AcceptButton = $btn");
   FileWrite(fh, "$r = $form.ShowDialog()");
   FileWrite(fh, "if ($r -eq 'OK') { [System.IO.File]::WriteAllText('" + resultPath + "', $(if($chk.Checked){'1'}else{'0'})) }");
   FileClose(fh);

   ShellExecuteW(0, "open", "powershell.exe",
                 "-WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + ps1Path + "\"",
                 "", 0);

   g_toggleWaiting = true;
}

//+------------------------------------------------------------------+
//| Launch a floating Windows InputBox via PowerShell (hidden)       |
//| Result is written to a temp file and picked up in OnTimer.       |
//+------------------------------------------------------------------+
void ShowSLInput()
{
   string commonFiles = TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "\\Files\\";
   string ps1Path     = commonFiles + "ht_sl_input.ps1";
   string resultPath  = commonFiles + "ht_sl_result.txt";

   // Clean up stale result
   FileDelete("ht_sl_result.txt", FILE_COMMON);

   // Write the PowerShell script (WinForms dialog with TopMost = true)
   int fh = FileOpen("ht_sl_input.ps1", FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(fh == INVALID_HANDLE) { Print("[HotkeyTrader] Cannot write PS1 script"); return; }
   FileWrite(fh, "Add-Type -AssemblyName System.Windows.Forms");
   FileWrite(fh, "Add-Type -AssemblyName System.Drawing");
   FileWrite(fh, "$form = New-Object System.Windows.Forms.Form");
   FileWrite(fh, "$form.Text = 'Set Stop Loss'");
   FileWrite(fh, "$form.Size = New-Object System.Drawing.Size(280, 130)");
   FileWrite(fh, "$form.StartPosition = 'CenterScreen'");
   FileWrite(fh, "$form.TopMost = $true");
   FileWrite(fh, "$form.FormBorderStyle = 'FixedDialog'");
   FileWrite(fh, "$form.MaximizeBox = $false");
   FileWrite(fh, "$form.MinimizeBox = $false");
   FileWrite(fh, "$lbl = New-Object System.Windows.Forms.Label");
   FileWrite(fh, "$lbl.Text = 'SL price for " + InpSymbol + ":'");
   FileWrite(fh, "$lbl.Location = New-Object System.Drawing.Point(10,12)");
   FileWrite(fh, "$lbl.Size = New-Object System.Drawing.Size(255,18)");
   FileWrite(fh, "$txt = New-Object System.Windows.Forms.TextBox");
   FileWrite(fh, "$txt.Location = New-Object System.Drawing.Point(10,34)");
   FileWrite(fh, "$txt.Size = New-Object System.Drawing.Size(250,22)");
   FileWrite(fh, "$btn = New-Object System.Windows.Forms.Button");
   FileWrite(fh, "$btn.Text = 'OK'");
   FileWrite(fh, "$btn.Location = New-Object System.Drawing.Point(95,62)");
   FileWrite(fh, "$btn.DialogResult = [System.Windows.Forms.DialogResult]::OK");
   FileWrite(fh, "$form.Controls.AddRange(@($lbl,$txt,$btn))");
   FileWrite(fh, "$form.AcceptButton = $btn");
   FileWrite(fh, "$r = $form.ShowDialog()");
   FileWrite(fh, "if ($r -eq 'OK' -and $txt.Text -ne '') { [System.IO.File]::WriteAllText('" + resultPath + "', $txt.Text) }");
   FileClose(fh);

   // Run PowerShell hidden — the InputBox GUI still pops up
   ShellExecuteW(0, "open", "powershell.exe",
                 "-WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + ps1Path + "\"",
                 "", 0);

   g_slWaiting = true;
   Print("[HotkeyTrader] SL input dialog opened — enter price and click OK");
}

//+------------------------------------------------------------------+
//| Modify SL of all open positions to a specific price              |
//+------------------------------------------------------------------+
void ApplySLToAll(double slPrice)
{
   int modified = 0;
   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol) continue;
      if(IsExcluded(ticket)) continue;

      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action   = TRADE_ACTION_SLTP;
      req.symbol   = InpSymbol;
      req.position = ticket;
      req.sl       = slPrice;
      req.tp       = PositionGetDouble(POSITION_TP);

      if(OrderSend(req, res))
         modified++;
      else
         PrintFormat("[HotkeyTrader] Set SL FAILED ticket=%I64u retcode=%u", ticket, res.retcode);
   }

   PrintFormat("[HotkeyTrader] Set SL %.5f → %d position(s) modified", slPrice, modified);
}

//+------------------------------------------------------------------+
//| Close half of the open positions on InpSymbol (async)           |
//| e.g. 4 positions → close 2; 3 positions → close 1               |
//+------------------------------------------------------------------+
void DoHalf()
{
   // Snapshot all matching tickets
   ulong tickets[];
   int total = PositionsTotal();
   ArrayResize(tickets, total);
   int count = 0;
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol) continue;
      if(IsExcluded(ticket)) continue;
      tickets[count++] = ticket;
   }

   if(count == 0)
   {
      Print("[HotkeyTrader] Half: no open positions on ", InpSymbol);
      return;
   }

   int closeCount = count / 2;   // floor: 4→2, 3→1, 1→0
   if(closeCount == 0)
   {
      Print("[HotkeyTrader] Half: only 1 position open, nothing to halve");
      return;
   }

   ENUM_ORDER_TYPE_FILLING filling = SymbolFilling(InpSymbol);
   int sent = 0;

   for(int i = 0; i < closeCount; i++)
   {
      if(!PositionSelectByTicket(tickets[i])) continue;

      double             volume = PositionGetDouble(POSITION_VOLUME);
      ENUM_POSITION_TYPE ptype  = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

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
      req.position     = tickets[i];
      req.magic        = InpMagic;
      req.type_filling = filling;

      if(OrderSendAsync(req, res)) sent++;
      else PrintFormat("[HotkeyTrader] Half FAILED ticket=%I64u retcode=%u",
                       tickets[i], res.retcode);
   }

   if(sent > 0) g_lastTradeTime = TimeCurrent();
   PrintFormat("[HotkeyTrader] HALF: closed %d of %d positions", sent, count);
}
//+------------------------------------------------------------------+
