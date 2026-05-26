# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

Two MQL5 Expert Advisors (EAs) for MetaTrader 5 (MT5). No build system, no tests — the compiler is MetaEditor (ships with MT5).

## How to compile and deploy

1. Copy `.mq5` files into the MT5 terminal's `MQL5\Experts\` folder (find it via MT5 → **File → Open Data Folder**).
2. Open the file in MetaEditor → press **F7** to compile. Errors appear in the Build tab.
3. In MT5: refresh Navigator → drag the EA onto a chart → enable **Algo Trading** in Common tab and in the toolbar.

There is no automated test runner. Verification is done on a demo account by observing trades in the Terminal → Trade tab and log output in the Experts tab.

## Architecture

### HotkeyTrader.mq5 — the main EA

The entire EA is a single polling loop. `EventSetMillisecondTimer(10)` drives `OnTimer()` every 10 ms; `OnTick()` is intentionally empty.

**Key detection** uses `GetAsyncKeyState` (imported from `user32.dll`) so hotkeys fire globally, even when MT5 is not focused. All key state is read once at the top of `OnTimer` into local bools (`buyNow`, `sellNow`, `altNow`, etc.), then evaluated in priority order:

```
Alt+Buy → Flatten (highest priority, returns early)
  └─ retries via g_flattenTicks for 50 ms after key release
Alt+Sell → Half
Alt+Enter → Break Even
Alt+Insert → SL input popup
Ctrl+Insert → Trade filter popup
Ctrl+Shift → Trading toggle popup
guard: if(!g_tradingEnabled) return
Buy alone → DoBuy
Sell alone → DoSell
```

**Edge detection** — every action uses a `g_*Down` bool so it fires only once per keypress, not once per 10 ms tick. Exception: flatten retries are intentional (g_flattenTicks).

**Order dispatch** — buy/sell/flatten/half all use `OrderSendAsync` (fire-and-forget, no blocking). Break-even and set-SL use synchronous `OrderSend` because they modify existing positions and order matters. `SymbolFilling()` auto-selects IOC/FOK/Return based on `SYMBOL_FILLING_MODE`.

**Trade exclusion** — `g_excludedTickets[]` holds ticket numbers that are skipped by all bulk operations (Flatten, Half, BE, Set SL). Populated by the trade filter popup. `IsExcluded(ticket)` checks this array.

**PowerShell popup pattern** — three popups (SL input, trade toggle, trade filter) follow the same pattern:
1. EA writes a `.ps1` script to `MT5 Common Files\Files\` using `FileWrite`.
2. EA launches it hidden via `ShellExecuteW` (from `shell32.dll`).
3. PowerShell shows a WinForms dialog (`TopMost=$true`).
4. User input is written to a result `.txt` file in the same folder.
5. EA polls `FileIsExist()` in `OnTimer` and reads the result file.

**Trade filter popup specifically** uses two result files:
- `ht_filter_result.txt` — written by Apply or OK; EA reads and updates `g_excludedTickets`, keeps `g_filterOpen=true`.
- `ht_filter_done.txt` — written by FormClosed handler; EA sets `g_filterOpen=false` and stops the live data feed.

While `g_filterOpen` is true, the EA writes `ht_positions_data.csv` every 500 ms (50 × 10 ms ticks) so the PowerShell ListView can update Price and P&L columns in real time without losing checkbox state.

**Auto-disable** — trading disables automatically after 30 minutes of no activity (`g_lastTradeTime`). Re-enable via Ctrl+Shift popup.

### KeyDetector.mq5 — utility EA

Scans all 256 VK codes via `GetAsyncKeyState` on a 10 ms timer and prints the hex/decimal code of any key pressed to the Experts tab. Used once to identify VK codes for physical keys, then discarded. Not needed at runtime.

## Input parameters (HotkeyTrader)

| Parameter | Default | Notes |
|---|---|---|
| `InpSymbol` | `XAUUSD` | Symbol for all operations |
| `InpLots` | `0.01` | Lot size per order |
| `InpBuyKey` | `0x2E` | VK code for Buy key (CE / Delete) |
| `InpSellKey` | `0x78` | VK code for Sell key (+/- maps to F9 VK) |
| `InpBEOffsetPts` | `10` | Points above/below entry for Break Even SL |
| `InpSlippagePoints` | `20` | Max slippage |
| `InpMagic` | `20260408` | Magic number |

## IPC file names (all in MT5 Common Files\Files\)

| File | Direction | Purpose |
|---|---|---|
| `ht_sl_input.ps1` / `ht_sl_result.txt` | EA→PS / PS→EA | SL price input |
| `ht_toggle_input.ps1` / `ht_toggle_result.txt` | EA→PS / PS→EA | Trading enable toggle |
| `ht_filter_input.ps1` | EA→PS | Trade filter form script |
| `ht_filter_result.txt` | PS→EA | Comma-separated protected ticket numbers |
| `ht_filter_done.txt` | PS→EA | Empty sentinel: window closed |
| `ht_positions_data.csv` | EA→PS | Live position data (ticket,dir,vol,open,price,pnl) |
