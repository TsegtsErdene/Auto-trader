# Security Policy

## Reporting a vulnerability

Please avoid opening a public issue for a vulnerability that could cause unintended order execution, bypass a safety control, expose sensitive local files, or otherwise create a meaningful security risk.

Instead, use GitHub's private vulnerability reporting feature if it is enabled for this repository. If private reporting is unavailable, contact the maintainer privately through the contact method listed on the maintainer's GitHub profile.

Include:

- affected version or commit
- reproduction steps
- expected and actual behavior
- realistic impact
- a proposed fix, if you have one

Do **not** include broker passwords, account numbers, API keys, access tokens, private logs, or other secrets.

## Supported versions

Security fixes are targeted at the latest version on the default branch unless a release explicitly states otherwise.

## Trading-safety issues

Unexpected order placement, incorrect symbol resolution, unsafe stop modification, confirmation bypasses, and failures of arm/disarm protections should be treated as high-priority bugs even when they are not conventional software-security vulnerabilities.
