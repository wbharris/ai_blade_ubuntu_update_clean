# Security policy

## Supported versions

Only the latest GitHub Release of `ai_blade_ubuntu_update_clean` is supported.
Older tags are not patched.

## Reporting a vulnerability

Please **do not** open a public issue for an unfixed vulnerability.

Report privately with a [GitHub security advisory](https://github.com/wbharris/ai_blade_ubuntu_update_clean/security/advisories/new). That includes:

- Bugs in `update-clean.sh` or related operational scripts
- GitHub Actions, release-pipeline, or supply-chain issues
- Anything that could let untrusted input run as root

Include the affected version (or commit), what you did, and what happened.

You should get an acknowledgement within 7 days. Fixes go out in a new release when they are ready.

## CI and CodeQL

CodeQL for GitHub Actions is enabled in the repository security settings (default setup, Actions language). There is no checked-in `.github/workflows/codeql.yml`; that is intentional so scans are not duplicated.

Pull-request CI is unprivileged. Root dry-run and mocked blade simulations run only on pushes to `main`.
