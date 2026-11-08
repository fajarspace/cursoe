# Security

Cursoe controls input on your devices, so security reports are taken seriously.

## Reporting a vulnerability

Please **do not** open a public issue. Use GitHub's private vulnerability reporting instead: open the repository's
**Security** tab and choose **Report a vulnerability**. Include the affected version, the steps to reproduce, and the
impact you expect.

## Scope

Areas of particular interest:
- the pairing and authentication handshake, and the encrypted channel (see [docs/architecture.md](docs/architecture.md#protocol));
- anything that lets another device on the network send input without pairing;
- the Android accessibility service and input method doing more than relaying the paired Mac's input.

The known limitation that an *active* attacker on the same network during pairing could try to guess the 6-digit
PIN is documented in [docs/troubleshooting.md](docs/troubleshooting.md#known-limitations).
