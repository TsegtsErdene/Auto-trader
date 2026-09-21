# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

Two MQL5 Expert Advisors (EAs) for MetaTrader 5 (MT5). No build system, no tests — the compiler is MetaEditor (ships with MT5).

## How to compile and deploy

1. Copy `.mq5` files into the MT5 terminal's `MQL5\Experts\` folder (find it via MT5 → **File → Open Data Folder**).
2. Open the file in MetaEditor → press **F7** to compile. Errors appear in the Build tab.
3. In MT5: refresh Navigator → drag the EA onto a chart → enable **Algo Trading** in Common tab and in the toolbar, and **Allow DLL imports**.

There is no automated test runner. Verification is done on a demo account by observing trades in the Terminal → Trade tab and log output in the Experts tab.

## Architecture

### HotkeyTrader.mq5 — the main EA

The entire EA is a single polling loop. `EventSetMillisecondTimer(10)` drives `OnTimer()` every 10 ms; `OnTick()` is intentionally empty.

**Key detection** uses `GetAsyncKeyState` (imported from `user32.dll`) so hotkeys fire globally, even when MT5 is not focused. All key state is read once at the top of `OnTimer` into local bools, then each action fires on its own key:

```
Numpad 1 → DoBuy             (enter long, gated)
Numpad 2 → DoSell            (enter short, gated)
Numpad 0 → DoBreakEven(0)    (SL to entry)
Numpad 3 → DoBreakEven(20)   (SL locks +20 pips of profit)
Numpad 4 → DoHalf            (close half the volume of each position)
Numpad 5 → DoTrailingStop    (one-shot: SL to 10 pips from current price)
Numpad 6 → ShowLotInput      (popup to type the lot size)
Numpad 7 → ShowSLInput       (popup to type one SL price for all)
Numpad 8 → ShowProtectInput  (popup to pick positions bulk actions skip)
Numpad 9 → DoFlatten         (close everything; needs a second press)
Numpad . → SetArmed          (toggle the entry gate)
```

The keys are the numeric-keypad VK codes (`VK_NUMPAD0`-`9` = 0x60-0x69, `VK_DECIMAL` = 0x6E), which is what the user's "Fn + keypad number" presses produce. The Fn key itself is processed in keyboard firmware and is invisible to `GetAsyncKeyState`, so only the resulting numpad code is detectable — and only when **NumLock is ON** (NumLock OFF makes the keypad send navigation VKs instead). All eleven keys are input parameters, so they can be re-pointed from the EA dialog without recompiling. `KeyName()` renders a VK code back as `Num 4` / `Num .` for the log and the on-chart label.

**Entry gate** — `g_armed` blocks `DoBuy`/`DoSell` only. Every exit and stop-move action (break even, trail, half, flatten, set SL) works whether or not the EA is armed, so a position can always be managed out. The gate starts at `InpStartArmed` (default `false`), toggles on the arm key, and auto-disarms after `InpAutoDisarmMin` idle minutes measured from `g_lastAction` (set by every order the EA sends, and by arming). `TimeLocal()` is used, not `TimeCurrent()`, so the timer keeps running when no ticks arrive.

**Flatten confirmation** — the first press of the flatten key only sets `g_flattenUntil` (a `GetTickCount64()` deadline) and repaints the label; a second press within `InpFlattenConfirmSec` actually closes. The window expiring is logged. `InpFlattenConfirmSec = 0` disables the confirmation.

**Protected tickets** — `g_protected[]` holds tickets that `DoFlatten`, `DoHalf`, `DoBreakEven`, `DoTrailingStop` and `ApplySLToAll` skip (`IsProtected`). `CollectTickets()` is the shared snapshot helper for the two closing actions: it filters by `InpSymbol`, drops protected tickets, and returns the list *before* any close is sent (closing mutates `PositionsTotal()`).

**Symbol matching** — `ResolveSymbol()` turns `InpSymbol` into the broker's own spelling at startup (case and suffix differences: `xauusd`, `XAUUSD.m`) and everything downstream uses that `g_symbol`. Position filters go through `SameSymbol()`, which compares **without case sensitivity**: a terminal that reports `xauusd` for a position while listing `XAUUSD` in Market Watch would otherwise make every bulk action skip every position silently.

**Which build is running** — `OnInit` logs `__FILE__` and `__DATETIME__`, and the chart label carries the compile time. MT5 runs the compiled `.ex5`, and a terminal can hold several copies of the EA in different Navigator folders, so "I recompiled" and "the chart runs that build" are separate facts; the stamp makes the second one checkable.

**Self-diagnosis** — `TradeBlockReason()` names the reason the EA cannot trade (algo trading off, the EA's own checkbox, account restrictions, no quotes, symbol disabled or close-only). It runs at init, is re-checked once a second in `OnTimer`, is logged when it changes, and shows on the chart label. `RetcodeHint()` turns the retcodes this EA hits into plain language, and `OnTradeTransaction` reports requests the server refuses — an `OrderSendAsync` that returns `true` has only left the terminal, so without it a refused entry would log `sent` and look like nothing happened. The label also shows how many positions the EA can actually see on its symbol, which is what exposes a symbol mismatch.

**Active lot size** lives in `g_lots` (seeded from `InpLots`, snapped to broker step/min/max by `NormalizeLot`). Buy/sell use `g_lots`, not `InpLots`.

**Popups** — three WinForms dialogs are driven the same way: write a PowerShell script into `Common Files\Files\`, launch it hidden with `ShellExecuteW` (`shell32.dll`), set `g_popup`, then poll for a result file. `WriteInputDialog()` generates the two single-field dialogs (lot, SL); the protect dialog is a checkbox `ListView` built from a snapshot of the open positions. Every dialog writes a result on **Cancel** too (empty line, or `CANCEL`), so a cancelled dialog still releases the EA. If PowerShell dies without writing anything, `AbortPopup()` releases the hotkeys after `InpPopupTimeoutSec` — without that watchdog a killed dialog would silently disable every key, flatten included. **While `g_popup != POPUP_NONE`, `OnTimer` absorbs all key states and fires nothing** — otherwise the numpad digits the user types into the box (still visible to `GetAsyncKeyState` globally) would trigger trades.

**Edge detection** — every action uses a `g_*Down` bool so it fires only once per keypress, not once per 10 ms tick.

**Pips vs points** — `InpPointsPerPip` (default 10) converts pips to price: `pip = InpPointsPerPip × SYMBOL_POINT`. On a 2-digit gold quote that makes 1 pip = 0.10. `PipPrice()` and `MinStopDist()` (broker `SYMBOL_TRADE_STOPS_LEVEL`) centralize the math.

**Order dispatch** — entries and closes use `OrderSendAsync` (fire-and-forget); stop moves use synchronous `OrderSend` with `TRADE_ACTION_SLTP`. `ClosePart()` is the single close path for both flatten and half. `SymbolFilling()` picks whichever mode the symbol advertises in `SYMBOL_FILLING_MODE` (FOK first, then IOC); when it advertises none, market and exchange execution get IOC rather than RETURN, which such brokers refuse with retcode 10030.

**Stop-move safety** — `DoBreakEven` and `DoTrailingStop` only ever *tighten* the stop (never widen risk) and skip any position where the target stop is closer to market than the broker's minimum stop distance. `ApplySLToAll` applies the same distance check and additionally rejects a price on the wrong side of the market, so a typo cannot be sent blindly — and logs, per position, the price the broker would accept. The SL dialog deliberately opens empty (a preset at market price would be rejected for every position) and shows bid/ask in its prompt instead. `ParseTypedNumber()` reads both `.` and `,` decimal separators. `DoHalf` skips a position when half of it — or what would remain — falls below `SYMBOL_VOLUME_MIN`.

### KeyDetector.mq5 — utility EA

Scans all 256 VK codes via `GetAsyncKeyState` on a 10 ms timer and prints the hex/decimal code of any key pressed to the Experts tab. Used once to identify VK codes for physical keys, then discarded. Not needed at runtime.

## Input parameters (HotkeyTrader)

| Parameter | Default | Notes |
|---|---|---|
| `InpSymbol` | `XAUUSD` | Symbol for all operations |
| `InpLots` | `0.01` | Starting lot size (seeds `g_lots`; live value set via the lot key) |
| `InpLongKey` | `0x61` | VK code for Long/Buy key (Numpad 1) |
| `InpShortKey` | `0x62` | VK code for Short/Sell key (Numpad 2) |
| `InpBEKey` | `0x60` | VK code for Break Even key (Numpad 0) |
| `InpBE20Key` | `0x63` | VK code for 20-pip Break Even key (Numpad 3) |
| `InpHalfKey` | `0x64` | VK code for Half-close key (Numpad 4) |
| `InpTrailKey` | `0x65` | VK code for Trailing SL key (Numpad 5) |
| `InpLotKey` | `0x66` | VK code for lot-size popup key (Numpad 6) |
| `InpSLKey` | `0x67` | VK code for Set-SL popup key (Numpad 7) |
| `InpProtectKey` | `0x68` | VK code for protect-positions popup key (Numpad 8) |
| `InpFlattenKey` | `0x69` | VK code for Flatten key (Numpad 9) |
| `InpArmKey` | `0x6E` | VK code for Arm/Disarm key (Numpad .) |
| `InpPointsPerPip` | `10` | Points per pip (gold: 10 → 1 pip = 0.10) |
| `InpBE20Pips` | `20` | Profit locked by 20-pip Break Even (pips) |
| `InpTrailPips` | `10` | Trailing SL distance from price (pips) |
| `InpStartArmed` | `false` | Whether entries are allowed at load time |
| `InpAutoDisarmMin` | `30` | Idle minutes before the gate closes itself (0 = never) |
| `InpFlattenConfirmSec` | `3` | Seconds allowed for the second Flatten press (0 = no confirm) |
| `InpPopupTimeoutSec` | `120` | Seconds before an unanswered popup is abandoned (0 = wait forever) |
| `InpSlippagePoints` | `20` | Max slippage |
| `InpMagic` | `20260408` | Magic number |

## IPC file names (all in MT5 Common Files\Files\)

| File | Direction | Purpose |
|---|---|---|
| `ht_lot_input.ps1` | EA→PS | WinForms lot-input dialog script |
| `ht_lot_result.txt` | PS→EA | Typed lot size (empty if cancelled) |
| `ht_sl_input.ps1` | EA→PS | WinForms SL-price dialog script |
| `ht_sl_result.txt` | PS→EA | Typed SL price (empty if cancelled) |
| `ht_protect_input.ps1` | EA→PS | WinForms position checklist script |
| `ht_protect_result.txt` | PS→EA | `OK:<csv of protected tickets>` or `CANCEL` |
