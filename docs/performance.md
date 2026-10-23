# Performance: belts, chests and claws

How data moves through ref_pg, where it waits, and where workers fight over the same resource. The numbers come from `tests/chaos_bench.sh` on the limited stack (`docker-compose.limits.yml`: OpenResty 1 vCPU / 256 MB with 1 worker, PostgREST 0.5 vCPU / 256 MB, Postgres 1 vCPU / 512 MB). Load comes from `wrk` inside the Docker network on an Apple M4 Max. Capacities were measured by filling each structure in a throwaway container.

The tool throughout is Little's law, L = λ × W: items waiting = arrival rate × time each one waits. A bounded buffer holds L items, so it survives a downstream stall of L / λ seconds. A cap on requests in flight bounds the wait at cap / throughput.

## 1. The factory map

### Belts: where data moves and gets multiplied

| Path | Per request | Throughput limit on the small node |
|---|---|---|
| Redirect, cache hit | 1 shared-dict read, 1 `cjson.encode` (~150 B) into the worker's click buffer. No database. | One OpenResty CPU: ~210,000 req/s |
| Redirect, cache miss | 1 subrequest → PostgREST → 1 index lookup on `links.code` | PostgREST at 0.5 vCPU: ~130 lookups/s |
| Click flush | 5,000 clicks → 1 POST of ~0.75–1.25 MB JSON → PostgREST parses it → 1 `INSERT … SELECT` of 5,000 rows → 1 statement trigger with 3 grouped upserts into rollups | ~90,000–130,000 clicks/s (each click is serialized as JSON twice) |
| Link creation | `authenticate()` (1 index lookup, 1 `UPDATE last_used_at`) → 1 `INSERT … ON CONFLICT` | Not a hot path |
| Analytics, before | `link_stats` aggregated every click of the tenant | Grew with clicks: 10× clicks took 11× longer |
| Analytics, after | Reads `link_totals` (1 row per link) plus up to 24 hourly rows per link | Grows with links and days, not clicks |

### Chests: every buffer, and how long it lasts

| Chest | Bound | Full at 1,000 req/s | Full at 50,000 req/s | When full |
|---|---|---|---|---|
| Click buffer (after): Lua table per worker | `CLICK_BUFFER` = 200,000 clicks in total (~50 MB) | 200 s of stall | 4 s of stall | New clicks dropped; one aggregate log line per worker per second |
| Click queue (before): shared dict | 64 MB ≈ 130,000 browser-sized clicks | 130 s | 2.6 s | Same, dropped and counted |
| Link cache `links` | 32 MB ≈ 130,000 links | Not time-based. LRU evicts the coldest links | — | A cold link costs one lookup |
| Miss cache `link_misses` (after) | 8 MB ≈ 65,000 unknown codes, 10 s each | Handles ~6,500 new unknown codes/s | — | LRU among misses only |
| Refresh locks `link_locks` | 1 MB, one entry per code under refresh, ≤ 4 s | — | — | — |
| PostgREST pool | 10 connections, shared by lookups and click batches | — | — | Requests queue inside PostgREST |
| Lookups in flight (after) | `LOOKUP_CONCURRENCY` = 10 in total, 4 on the small node | — | — | Cold miss gets 503 + `Retry-After: 1`; a refresh keeps the old URL |
| `clicks` table | Disk, partitioned by UTC day; days older than `CLICK_RETENTION_DAYS` (90) dropped hourly. About 130 B per row with indexes | 11 GB/day, about 1 TB at 90 days | 560 GB/day, 50 TB at 90 days: lower the retention | Oldest whole day dropped; link stats unchanged (rollups) |
| `link_clicks_hourly` | Pruned after 48 h (`clicks_24h` reads the last 24) | — | — | — |
| `click_batches` | 1 row per batch (one per second per worker, or per 5,000 clicks), pruned after 1 h | ~3,600 rows | ~36,000 rows | — |

**Sushi belts found (bad traffic sharing a lane with good):**
1. **Unknown codes shared the link cache with real links.** A scan filled it with 404 entries and LRU evicted real links. Measured: a 25 s scan evicted **all 6,000** links that had just been cached. Fixed: a separate `link_misses` dict.
2. **Unknown-code lookups shared PostgREST with everything else.** Each one was a synchronous lookup with no limit. On half a CPU, a 10% scan queued so many that p99 for all traffic hit **1.6 s**, and the queued lookups starved click flushes of PostgREST connections. Fixed: a cap on lookups in flight that sheds overflow with 503.

### Claws: locks and single-worker bottlenecks

| Claw | Before | After |
|---|---|---|
| Click queue shared dict | 2 lock operations per click: `rpush` from every worker, `lpop` by worker 0 | Gone. Each worker appends to its own Lua table and drains it by swapping in an empty table |
| Single flusher | Worker 0 flushed for everyone; overlapping timer runs were fixed earlier with a flag | Each worker flushes its own clicks, one flush at a time, immediately when 5,000 are waiting |
| Cache stampede on expiry | One refresh per code (lock in `link_locks`), the rest served the old URL | Unchanged: 127 lookups where the limit is 240 for 20 keys × 2 s cache × 20 s |
| Upstream lookups | Unbounded, queued in PostgREST | Capped. Little's law: 4 in flight ÷ ~130/s ≈ 31 ms worst-case wait |
| PL/pgSQL subtransactions | One per generated code (`EXCEPTION WHEN unique_violation`) | None for code generation (`ON CONFLICT DO NOTHING`); one per click batch for the rare foreign-key race |
| Rollup row locks | — | Concurrent batches upsert the same hot rows. `ORDER BY` makes them lock in the same order, so they wait instead of deadlocking |
| `FOR KEY SHARE` on every batch | — | Tried and removed: it cost ~12% of insert throughput to guard against a rare race. Retrying on the foreign-key error costs nothing until it happens |
| Partition upkeep | — | New days are built standalone and attached (SHARE UPDATE EXCLUSIVE: inserts never wait). Dropping a day takes ACCESS EXCLUSIVE on `clicks` for milliseconds, with a 2 s `lock_timeout`. A skipped day is retried next hour |
| `api_keys.last_used_at` | One row update per API write; one busy key serializes writes on that row | Unchanged. Link creation is low-volume |

## 2. The hardware envelope

`docker-compose.limits.yml` caps each container. It also sets `WORKER_PROCESSES=1`: nginx's `auto` counts the host's 16 cores, not the container's 1-CPU quota, so 16 workers would time-slice one CPU. `LOOKUP_CONCURRENCY=4` is sized from the measured ~130 lookups/s.

## 3. What `tests/chaos_bench.sh` asserts

| Phase | Physical reality | Invariant |
|---|---|---|
| 1. Cold wakeup | Fresh OpenResty (empty caches), 5 s idle, 1 request | First request ≤ 250 ms |
| 2a. Stampede + scan | 20,000 req/s for 20 s: 90% on 20 links with a 2 s cache, 10% unique unknown codes | Hot-key lookups ≤ 1 per key per expiry (+2); p99 ≤ 50 ms; clicks recorded = 302s served |
| 2b. Sushi belt | 6,000 links fill 74% of a 1 MB cache, then 25 s of unique unknown codes | ≤ 5% of those links fetched again |
| 3a. Downstream stall | Postgres container paused 3 s during 15 s at 20,000 req/s | p99 ≤ 50 ms; clicks recorded = 302s served (none lost, none doubled) |
| 3c. Overload | Unpaced load, past ingest capacity | Recorded + counted drops = 302s served: overload is visible, never silent |
| 3b. Poison record | A link deleted while its clicks wait in the buffer | Every other click in the same batches is recorded |
| 4. Analytics scaling | One tenant at 100,000 then 1,000,000 clicks | 10× clicks ≤ 3× the query time (or +10 ms) |
| 5. Retention under load | Drop every day older than 7 (24 partitions, ~1.1M rows) during 15 s at 20,000 req/s | All 24 dropped, none skipped on a lock timeout; no raw rows older than 7 days; rollup totals unchanged; p99 ≤ 50 ms; clicks recorded = 302s served |

`wrk` counts completed responses, so up to 64 requests in flight at the end are served but not counted: "recorded = served" allows +64.

## 4. Results

Same test, same limited node, before and after the changes in this commit.

| Phase | Before | After |
|---|---|---|
| 1. Cold request after idle | 15 ms | 16 ms |
| 2a. p99 under expiry + 10% scan | **1,600 ms** (fail) | **1.7 ms** |
| 2a. Hot-key lookups (limit 240) | 134 | 127 |
| 2a. Clicks recorded vs 302s served | exact | exact |
| 2b. Links fetched again after a scan | **6,000 of 6,000** (fail) | **0** |
| 3a. 3 s Postgres stall at 20k/s: p99 / clicks lost | 2 ms / 0 | 2 ms / 0 |
| 3c. Overload accounting | exact | exact |
| 3c. Clicks written per second at saturation | 131,511 | 89,000–111,000 across runs |
| 3b. Clicks lost to a deleted link's batch | 0 | 0 |
| 4. `link_stats`, 100k → 1M clicks | **122 → 1,418 ms** (fail) | **1 → 3 ms** |
| 4. `top_referrers`, 100k → 1M clicks | **160 → 1,618 ms** (fail) | **31 → 48 ms** |
| 5. Drop 24 days of raw clicks under load | not possible (no partitions) | **12 ms**, 0 clicks lost, p99 1.6 ms |

On all 16 cores with no limits, per-worker flushing raised the click-write ceiling from about 110,000–150,000/s (one flusher, worker 0) to **306,000/s**, at 529,005 req/s and a 2.1 ms p99. Accounting stayed exact: 6,127,276 recorded + 4,507,169 dropped and counted = 10,634,403 redirects served (+42 in flight).

### The trade-off: lower ingest ceiling at saturation on one CPU

At full saturation the click-write ceiling fell from about 131k/s to 89–111k/s. Two causes, both measured:

- **The rollup trigger costs about 13%** of insert time (238 vs 211 ms per 40,000 clicks in Postgres). That's the price of analytics that don't scan clicks.
- **The redirect path got cheaper and served more** on the same single CPU (196k → 212–221k req/s), leaving less of that CPU for flushing.

Partitioning adds only a few percent: the insert function takes 292–311 ms per 40,000 clicks in Postgres, against 315 ms before (about 130,000 clicks/s). End to end, the saturation ceiling on one CPU varies a lot from run to run (73,000–111,000 clicks/s across runs), because redirects and flushing share that CPU.

Below saturation nothing is lost, and above it every dropped click is counted. To raise the ceiling: more OpenResty CPUs (each worker flushes its own buffer in parallel) and more PostgREST CPU (it parses every batch).

## Findings along the way

- **A benchmark from the host measures the port forward.** From macOS through OrbStack, p99 was 185 ms at about 80,000 req/s. From inside the Docker network it was 1.0 ms at 350,000 req/s. `bench.sh` and the chaos test now run `wrk` in a container on the stack's network.
- **Docker caps container logs** (here 5 × 20 MB). At 300,000 req/s the access log rotates out in seconds, taking the drop reports with it. Benchmarks run with `ACCESS_LOG=off`.
- **`ngx.timer.every` overlaps runs when one is slow.** Each overlapping click flush held a batch outside the buffer, so the buffer limit wasn't enforced during an outage. Each worker now runs one flush at a time.
- **Size buffers with Little's law.** The first version of per-worker buffers held 20,000 clicks and lost 11,398 in a 3 s stall at 20,000/s (it needed ≥ 60,000). The buffer is now set as a total, 200,000 by default: about 10 s of stall at 20,000 clicks/s.

## Limits

- **Retention works in whole UTC days.** `link_referrers_daily` is kept forever, since `top_referrers` is all-time. It grows with links × days × distinct referrers.
- **One busy API key serializes writes** on its `last_used_at` row.
- **The ingest ceiling is set by CPU:** one OpenResty worker and half a PostgREST CPU on the small node.
