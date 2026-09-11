# Repository Instructions

## Upstream ownership

The BBR behavior in this repository is generated from `chnnic/SSH-Hardening/src/modules/bbr.sh`.

- Do not edit the block between `BEGIN SYNCED BBR MODULE` and `END SYNCED BBR MODULE` by hand.
- Make BBR behavior changes in `SSH-Hardening` first and commit them there.
- Run `scripts/sync-from-upstream.sh /path/to/SSH-Hardening` to regenerate `bbr-tune.sh`.
- Keep standalone-only code outside the generated block.
- Update README and tests when behavior or compatibility changes.
- Run syntax checks, ShellCheck, the sync check, and `tests/smoke.sh` before committing.
- Push `SSH-Hardening` and `BBR-tune` in the same work item when BBR behavior changes.

Never place access tokens or cloud credentials in repository files or command history.

## Offline delivery requirement

For every upstream script version update, the user also requires the matching
SSH-Hardening offline package to be built, validated, and published in GitHub
Releases, with README direct/proxy download links on that same version. Follow
the upstream AGENTS.md release checklist and wait for release verification before
reporting the paired update complete. A source push or BBR synchronization alone
does not complete that delivery. Do not invent a separate BBR-tune installer.
