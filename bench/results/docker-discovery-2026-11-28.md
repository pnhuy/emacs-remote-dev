# Docker discovery and first-connect benchmark

Recorded 2026-11-28T09:47:56Z on Linux 7.3.6-3-cachyos x86_64, Emacs 31.1,
Docker 29.10.1, image `python:3.11-slim`.

| Measurement | Value |
|---|---|
| Containers | 50 |
| `docker ps` (median of 5) | 63 ms |
| Emacs discovery, cold | 65.5 ms |
| Emacs discovery, cached (TTL) | 0.0 ms |
| First connect, cold (median of 3) | 270.3 ms |
| Reconnect, warm helper | 222.4 ms |

Cold connect installs and hash-verifies the helper; warm reuses it.
Target: discovery of 50 containers in <= 3 s.
