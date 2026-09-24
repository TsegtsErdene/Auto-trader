# HotkeyTrader for MetaTrader 5

HotkeyTrader is a focused MetaTrader 5 Expert Advisor for **manual traders who want faster keyboard-driven execution and position management**.

It does **not** generate trading signals or make strategy decisions for you. It gives you configurable numpad hotkeys for entering trades, moving stops, taking partials, protecting selected positions, and flattening positions quickly.

> Windows only. The EA uses Windows APIs and PowerShell for global hotkeys and small input dialogs.

## Highlights

- Global numpad hotkeys for long / short entries
- Arm / disarm protection for new entries
- Break-even and profit-lock stop management
- One-tap partial close
- One-shot trailing stop adjustment
- Protected positions that bulk actions skip
- Two-step confirmation before flattening positions
- Configurable symbol, lot size, hotkeys, pip size, slippage and timeouts
- Diagnostics panel and detailed Experts-tab logging
- No external trading service or signal dependency

## Files

- `HotkeyTrader.mq5` — main Expert Advisor
- `KeyDetector.mq5` — helper EA for discovering Windows virtual-key codes
- `docs/README.mn.md` — detailed Mongolian user guide
- `CONTRIBUTING.md` — how to contribute
- `SECURITY.md` — security reporting guidance

## Requirements

- MetaTrader 5 on Windows
- MetaEditor
- DLL imports enabled for the EA
- PowerShell available for the optional popup dialogs
- NumLock enabled

## Quick start

1. Copy `HotkeyTrader.mq5` and `KeyDetector.mq5` into your MT5 `MQL5/Experts/` folder.
2. Open the files in MetaEditor and compile with **F7**.
3. In MT5, refresh the Navigator and attach `HotkeyTrader` to a chart.
4. Enable **Algo Trading** and **Allow DLL imports**.
5. Configure `InpSymbol`, lot size and pip settings for your broker.
6. Test every hotkey on a **demo account** before considering live use.

## Default hotkeys

| Key | Action |
|---|---|
| Numpad `.` | Arm / disarm new entries |
| Numpad `1` | Market buy |
| Numpad `2` | Market sell |
| Numpad `0` | Move SL to break even |
| Numpad `3` | Lock configured profit in SL |
| Numpad `4` | Close half |
| Numpad `5` | Move SL to configured trailing distance |
| Numpad `6` | Set lot size |
| Numpad `7` | Set SL price |
| Numpad `8` | Protect selected positions from bulk actions |
| Numpad `9` | Flatten non-protected positions, with confirmation |

All keys are configurable in the EA inputs.

## Safety notes

Trading software can cause financial loss. HotkeyTrader sends and modifies real orders when attached to a live account.

- Test on a demo account first.
- Keep the EA **DISARMED** when you are not actively trading.
- Confirm that `InpSymbol` resolves to the intended broker symbol.
- Verify `InpPointsPerPip` for each symbol before using stop-management hotkeys.
- Be aware that management actions can affect positions on the configured symbol regardless of how those positions were opened.
- Review the source before use and do not assume defaults are appropriate for your broker or account.

This project is provided for software and workflow purposes, not financial advice.

## Contributing

Issues and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before contributing.

Good contribution areas include:

- broker compatibility
- safer execution and validation
- testability and reproducible bug reports
- accessibility and keyboard configuration
- documentation
- localization

## Security

Please do not publish sensitive account information, broker credentials, API keys, screenshots containing account IDs, or live trading details in issues. See [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).

## Documentation

- [Монгол гарын авлага](docs/README.mn.md)

## Project status

Actively maintained as a small open-source utility. The current goal is to make manual MT5 execution safer, clearer, and easier to customize across brokers.

