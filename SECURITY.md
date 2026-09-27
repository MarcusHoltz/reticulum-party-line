# Security Policy

## Supported Versions

Only the latest release on the `main` branch receives security fixes.
Older versions are unsupported, so please update before reporting.

| Version | Supported |
|---------|-----------|
| latest (`main`) | ✅ |
| older tags | ❌ |

---

## Reporting a Vulnerability

**Do not open a public issue (on GitLab or GitHub) for security vulnerabilities.**

This project's canonical home is **GitLab**; the GitHub repository is a read-only mirror. Either private channel below reaches the maintainer. GitLab is preferred since that is where fixes are developed and released.

- **GitLab (preferred):** open a [confidential issue](https://gitlab.com/marcusholtz/tor-party-line/-/issues/new) and tick the **"This issue is confidential"** box so it stays visible only to project members, or contact the maintainer via [gitlab.com/marcusholtz](https://gitlab.com/marcusholtz).

Use the subject line `[tor-party-line] Security`.

Please include:

1. A clear description of the vulnerability and its potential impact
2. Steps to reproduce or a minimal proof-of-concept
3. Which component is affected (`partyline.sh`, `entrypoint.sh`, `Dockerfile`, etc.)
4. Your suggested severity (Critical / High / Medium / Low)

You will receive an acknowledgement within **72 hours** and a resolution timeline within **7 days**.

---

## Upstream

This project is forked from [TerminalPhone](https://gitlab.com/here_forawhile/terminalphone) by
[here_forawhile](https://gitlab.com/here_forawhile).
Security issues that exist in the upstream codebase should be reported there as well.

---

## Scope

Reports are welcome for issues in this codebase. Common areas of concern:

- Cryptographic weaknesses (cipher choices, key derivation, HMAC implementation)
- Shared-secret or `.onion` private-key exposure (files, logs, environment variables, `docker inspect`)
- Command injection or shell escaping bugs in `partyline.sh`
- Tor anonymity leaks (traffic routed outside the SOCKS proxy, DNS leaks, IP disclosure)
- Docker container escape or privilege escalation via the bind mounts or `security_opt` settings
- Insecure defaults that silently degrade the security model

### Out of scope

- Tor network-level attacks: report those to the [Tor Project](https://gitlab.torproject.org/tpo/core/tor/-/blob/main/doc/HACKING/CodingStandards.md#reporting-security-issues)
- Issues in third-party dependencies (`tor`, `openssl`, `socat`, `opusenc`): report those upstream
- Social-engineering attacks against users
- Theoretical attacks requiring physical access to an already-compromised host

---

## Known Limitations

The [security model](README.md#-reference) section of the README documents intentional trade-offs that are **not bugs**:

- **No forward secrecy:** compromise of the shared secret exposes all past calls made with it. Rotate secrets between sensitive conversations.
- **No AEAD:** `openssl enc` cannot stream AEAD ciphers, so AES-256-CBC with PBKDF2 (100k iterations) is used instead.
- **Overwrite-on-delete is ineffective on SSDs:** wear-leveling defeats file-level overwriting; use full-disk encryption (LUKS / FileVault).
- **Single-hop mode** reduces anonymity in exchange for speed and is off by default.

Please do not report these as vulnerabilities.

---

## Disclosure Policy

This project follows **coordinated disclosure**:

1. Reporter submits privately.
2. Maintainer confirms and reproduces the issue.
3. A fix is developed and tested.
4. A patched release is published.
5. A public advisory is issued, crediting the reporter (unless they prefer to remain anonymous).

The embargo period is normally **14 days** from confirmation, extended only if a fix requires significant work.
