-- wrk script for tests/chaos_bench.sh.
--   wrk ... -s chaos.lua <url> -- <hot prefix> <hot count> <hot share> [<rate> <connections>]
-- A <hot share> fraction of requests goes to <hot prefix>1..<hot count>; the
-- rest goes to unique random codes that do not exist (a 404 scan). With <rate>,
-- each connection waits between requests so the total stays near <rate>/s.
-- Prints one RESULT line with status counts and latency percentiles in microseconds.
local threads = {}
local next_id = 0

function setup(thread)
    next_id = next_id + 1
    thread:set("id", next_id)
    table.insert(threads, thread)
end

function init(args)
    prefix, hot_count, hot_share = args[1], tonumber(args[2]), tonumber(args[3])
    local rate, conns = tonumber(args[4] or 0), tonumber(args[5] or 1)
    pause_ms = rate > 0 and conns * 1000 / rate or 0
    ok302, nf404, other, scans = 0, 0, 0, 0
    math.randomseed(id * 7919 + os.time())
end

function request()
    if math.random() < hot_share then
        return wrk.format("GET", "/r/" .. prefix .. math.random(1, hot_count))
    end
    scans = scans + 1
    return wrk.format("GET", "/r/scan" .. id .. "x" .. scans .. "x" .. math.random(1, 999999))
end

function delay()
    return pause_ms
end

function response(status)
    if status == 302 then ok302 = ok302 + 1
    elseif status == 404 then nf404 = nf404 + 1
    else other = other + 1 end
end

function done(summary, latency, requests)
    local a, b, c, d = 0, 0, 0, 0
    for _, t in ipairs(threads) do
        a, b, c, d = a + t:get("ok302"), b + t:get("nf404"), c + t:get("other"), d + t:get("scans")
    end
    io.write(string.format(
        "RESULT ok302=%d nf404=%d other=%d scans=%d rps=%d p50_us=%d p99_us=%d p999_us=%d max_us=%d\n",
        a, b, c, d, math.floor(summary.requests * 1000000 / summary.duration),
        latency:percentile(50), latency:percentile(99), latency:percentile(99.9), latency.max))
end
