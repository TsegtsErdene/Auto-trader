# Contributing to HotkeyTrader

Thanks for considering a contribution.

## Before you start

1. Search existing issues and pull requests.
2. For substantial behavior changes, open an issue first and describe the problem and proposed approach.
3. Never include broker credentials, account numbers, API keys, personal trading records, or other secrets.

## Development workflow

1. Fork the repository.
2. Create a focused branch from the default branch.
3. Make one logical change per pull request where practical.
4. Compile the modified MQL5 files in MetaEditor with zero errors.
5. Test behavior on a MetaTrader 5 demo account.
6. Update documentation when behavior or inputs change.
7. Open a pull request with a clear description and test evidence.

## Pull request checklist

- [ ] The change has a clear user or maintenance benefit.
- [ ] `.mq5` files compile successfully in MetaEditor.
- [ ] Trading behavior was tested on a demo account.
- [ ] Existing safety checks were not weakened without explicit justification.
- [ ] New inputs or hotkeys are documented.
- [ ] No secrets or personal trading data are included.
- [ ] The PR is reasonably scoped.

## Bug reports

Useful bug reports include:

- MT5 build number
- Windows version
- broker symbol name, without account-identifying information
- relevant EA input values
- exact reproduction steps
- Experts-tab log lines with sensitive values removed
- expected versus actual behavior

## Code style

Prefer readable MQL5 over clever abstractions. Safety-critical trading actions should have explicit validation and useful log output.

## Scope

Good contributions include broker compatibility, safety checks, order handling, UI/UX, diagnostics, documentation, localization and maintainability.

Strategy signals, profit claims and broker-specific promotional features are outside the core scope unless they are clearly separated from the execution utility.

## License

By submitting a contribution, you agree that your contribution will be licensed under the repository's MIT License.
