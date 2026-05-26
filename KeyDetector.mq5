//+------------------------------------------------------------------+
//|  KeyDetector.mq5                                                 |
//|  Scans ALL 256 VK codes via GetAsyncKeyState every 10 ms.        |
//|  Works globally — press any key anywhere, code appears in        |
//|  Experts tab AND on the chart. MT5 focus not required.           |
//+------------------------------------------------------------------+

#property copyright "HotkeyTrader"
#property version   "2.00"
#property strict

#import "user32.dll"
   int GetAsyncKeyState(int vKey);
#import

bool g_prev[256];

int OnInit()
{
   ArrayInitialize(g_prev, false);
   EventSetMillisecondTimer(10);
   Print("=== KeyDetector ready — press ANY key (MT5 focus not needed) ===");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
}

void OnTick() {}

void OnTimer()
{
   for(int vk = 1; vk < 256; vk++)
   {
      bool down = (GetAsyncKeyState(vk) & 0x8000) != 0;

      if(down && !g_prev[vk])   // rising edge
      {
         PrintFormat("Key pressed → VK hex: 0x%02X  |  decimal: %d", vk, vk);
         Comment(StringFormat(
            "  Last key pressed:\n"
            "  Hex     : 0x%02X\n"
            "  Decimal : %d\n\n"
            "  Use this value in HotkeyTrader inputs.", vk, vk));
      }

      g_prev[vk] = down;
   }
}
//+------------------------------------------------------------------+
