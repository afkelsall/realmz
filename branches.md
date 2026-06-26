# Branch notes

Local branches excluded from PR/merge-status audits:

- `render-perf-investigation` -- research branch, not intended for upstream. Documents
  render pipeline performance measurements and experiments.
- `integration` -- local-only disposable branch, recreated by rebuild-integration.sh.
- `list` -- tracking branch mirroring origin/main, not a feature branch.
- `asan-windows-debug` -- local-only helper for crash diagnosis, listed in integration.txt
  so it is merged into every integration build. It drops the NOT WIN32 guard on the asan
  flags so the cross-compiled Windows Debug exe is AddressSanitizer-instrumented. Not for
  upstream; kept out of PRs.
