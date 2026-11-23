# rdev benchmarks (FR-037, SC-013)

    bench/run.sh HOST OUT.csv [rtt0 rtt50 rtt150 loss1 slow1mbit]   # delay-proxy shaper
    bench/run.sh --netem OUT.csv [profile ...]                      # tc netem, Linux only
    python3 bench/compare.py BASELINE.csv NEW.csv                   # flag >20% regressions
    python3 bench/compare.py --vs-tramp OUT.csv                     # rdev/TRAMP ratios
    emacs -Q --batch -L . -l bench/tramp-compare.el         # quick side-by-side

Shapers. `delay-proxy` (bench/delay-proxy.py) is an ssh ProxyCommand adding RTT/2 each
way, an optional bandwidth cap, and loss modelled as retransmission-timeout stalls
(TCP never loses bytes), so it is coarser than netem.  `netem` (bench/netem.sh) runs
the whole benchmark plus a throwaway sshd inside `unshare -rn` with `tc qdisc netem`
on the namespace loopback; it needs Linux, tc and user namespaces.  Each CSV row
records the shaper that produced it.  `rtt0` under delay-proxy is the real network to
the host plus the proxy hop, not zero latency.

Operations: stat (cached/cold), exists, open, save (atomic write), readdir (cold/warm),
readdir-attrs, tree-walk, proc-start, shell-echo, proc-async, rdev-only project-files and
search, connect (+bootstrap), eglot-startup (recorded as skipped when no language
server exists on the target).  `ui_blocked_ms` is the longest stretch an Emacs timer
could not fire; `emacs_rss_kb` is the Emacs process RSS (agent RSS is not measured).
Cold = client caches flushed before each call; TRAMP gets the same treatment.

Results are medians over N iterations (RDEV_BENCH_ITER, default 20; connect and
tree/project/search ops use N/4).  Baselines in bench/results/ are recorded before any
performance change (T107); an optimization (T108) must add a before/after CSV.

## Baseline findings (2026-11-22, devbox, 10 iterations)

Files: `results/baseline-2026-11-22.csv` (proxy shaper, 5 profiles, 183 rows, 0 rdev failures,
4 TRAMP failure rows at rtt150) and `results/netem-rdev-only-2026-11-22.csv` (real `tc netem`,
rtt50 and loss1, 5 iterations, rdev only).

- rdev beats TRAMP on connect (0.4-0.5x), save (0.06-0.10x), async process start (0.06-0.08x).
- Optimization candidates for T108: warm `readdir` is not cached (1 RTT vs TRAMP cache 0.4 ms);
  `readdir-attrs-cold` costs about 3 RTT and is 1.5-3x slower than TRAMP at rtt150/slow1mbit;
  `tree-walk-cold` is 2.6x slower than TRAMP at rtt150; `proc-async` costs about 5 RTT.
- Netem notes: runs in `unshare -nm --map-root-user --map-auto` with bind-mounted
  passwd/shadow/privsep dirs and an unprivileged `bench` login (the agent refuses uid 0).
  TRAMP under netem fails to connect, so TRAMP-vs-rdev comparison there is not available;
  use the proxy profiles for it.
- Not measured in this baseline: Eglot startup, agent RSS (measured later, see below).

## T108 optimization: batch "." / ".." in directory-files-and-attributes (2026-11-22)

Bottleneck (from the baseline): `readdir-attrs-cold` took ~3 RTT because "." and ".." were
stat'ed one round trip each.  Fix: one `fs/statMany` for both (rdev.el,
`directory-files-and-attributes`).  Before/after medians (rdev, delay-proxy, 10 iterations;
CSV `results/t108-readdir-attrs-2026-11-22.csv`):

| op | rtt50 before -> after | rtt150 before -> after |
|---|---|---|
| readdir-attrs-cold | 219 -> 203 ms | 528 -> 345 ms (3 -> 2 RTT) |
| tree-walk-cold | 275 -> 173 ms | 715 -> 339 ms |

`compare.py` also flags 18 "regressions"; 14 are TRAMP rows (network noise between runs on
a shared host, not our code) and rdev's only flag is `stat-cold` rtt50 p95 (84.6 -> 111 ms,
10 samples, median unchanged).  Remaining candidates (warm readdir cache, proc-async ~5 RTT)
are not addressed: they need a cache-invalidation design, so they stay out of this change.

## Slow-link regression found and fixed: compressed readdir (2026-11-23, devbox)

Profiles `loss1` and `slow1mbit` against TRAMP (8 iterations,
`results/loss1-slow1mbit-before-2026-11-23.csv`) showed rdev behind TRAMP at 1 Mbit/s:
`completion-1000-cold` 3110 vs 934 ms (3.3x), `readdir-attrs-cold` 1.5x, `tree-walk-cold`
1.6x. Cause: about 400 bytes of attribute JSON per entry (~400 KB for 1000 entries). Fix:
optional zlib-compressed `fs/readdir` (capability `fs.readdirZ`, see `protocol.md`).
After (`results/slow1mbit-readdirZ-2026-11-23.csv`): completion 191 ms (0.19x TRAMP),
readdir-attrs-cold 145 ms (0.32x), tree-walk-cold 159 ms (0.33x). At `loss1` rdev was already
faster than TRAMP on everything except `readdir-warm` (not cached; known candidate).

## Eglot startup and agent memory (2026-11-23, devbox)

- Eglot startup (pylsp, find-file + initialize handshake, rtt50, 2 iterations): rdev 1.78 s
  median. TRAMP did not come up in this setup (Eglot timed out after 60 s in both iterations,
  recorded as 2 failures), so there is no TRAMP figure. CSV: `results/eglot-startup-2026-11-23.csv`.
- Agent RSS during the 500 MiB chunked round trip (`test/e2e/large-file.el`): peak 39.9 MiB
  (asserted below 500 MiB). Emacs-side growth was 1 MiB after warm-up.
