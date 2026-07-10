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
