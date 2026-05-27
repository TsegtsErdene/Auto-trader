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

**Key detection** uses `GetAsyncKeyState` (imported from `user32.dll`) so hotkeys fire globally, even when MT5 is not focused. All key state is read once at the top of `OnTimer` into local bools, then each action fires on its own key:

```
Numpad 1 → DoBuy            (enter long)
Numpad 2 → DoSell           (enter short)
Numpad 0 → DoBreakEven(0)   (SL to entry on all positions)
Numpad 3 → DoBreakEven(20)  (SL locks +20 pips of profit)
Numpad 5 → DoTrailingStop   (one-shot: SL to 10 pips from current price)
```

The keys are the numeric-keypad VK codes (`VK_NUMPAD0`-`9` = 0x60-0x69), which is what the user's "Fn + keypad number" presses produce. The Fn key itself is processed in keyboard firmware and is invisible to `GetAsyncKeyState`, so only the resulting numpad code is detectable — and only when **NumLock is ON** (NumLock OFF makes the keypad send navigation VKs instead). All five keys are input parameters, so they can be re-pointed from the EA dialog without recompiling.

The EA is always armed — there is no enable/disable gate. Pressing the buy/sell keys sends a market order immediately.

**Edge detection** — every action uses a `g_*Down` bool so it fires only once per keypress, not once per 10 ms tick.

**Pips vs points** — `InpPointsPerPip` (default 10) converts pips to price: `pip = InpPointsPerPip × SYMBOL_POINT`. On a 2-digit gold quote that makes 1 pip = 0.10. `PipPrice()` and `MinStopDist()` (broker `SYMBOL_TRADE_STOPS_LEVEL`) centralize the math.

**Order dispatch** — buy/sell use `OrderSendAsync` (fire-and-forget). Break-even and trailing use synchronous `OrderSend` with `TRADE_ACTION_SLTP` because they modify existing positions. `SymbolFilling()` auto-selects IOC/FOK/Return based on `SYMBOL_FILLING_MODE`.

**Stop-move safety** — `DoBreakEven` and `DoTrailingStop` only ever *tighten* the stop (never widen risk) and skip any position where the target stop is closer to market than the broker's minimum stop distance, so a position whose price hasn't moved far enough into profit is left untouched. Both apply to every open position on `InpSymbol`.

### KeyDetector.mq5 — utility EA

Scans all 256 VK codes via `GetAsyncKeyState` on a 10 ms timer and prints the hex/decimal code of any key pressed to the Experts tab. Used once to identify VK codes for physical keys, then discarded. Not needed at runtime.

## Input parameters (HotkeyTrader)

| Parameter | Default | Notes |
|---|---|---|
| `InpSymbol` | `XAUUSD` | Symbol for all operations |
| `InpLots` | `0.01` | Lot size per order |
| `InpLongKey` | `0x61` | VK code for Long/Buy key (Numpad 1) |
| `InpShortKey` | `0x62` | VK code for Short/Sell key (Numpad 2) |
| `InpBEKey` | `0x60` | VK code for Break Even key (Numpad 0) |
| `InpBE20Key` | `0x63` | VK code for 20-pip Break Even key (Numpad 3) |
| `InpTrailKey` | `0x65` | VK code for Trailing SL key (Numpad 5) |
| `InpPointsPerPip` | `10` | Points per pip (gold: 10 → 1 pip = 0.10) |
| `InpBE20Pips` | `20` | Profit locked by 20-pip Break Even (pips) |
| `InpTrailPips` | `10` | Trailing SL distance from price (pips) |
| `InpSlippagePoints` | `20` | Max slippage |
| `InpMagic` | `20260408` | Magic number |
