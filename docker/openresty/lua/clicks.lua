-- Click buffer, one per nginx worker. A redirect appends to a plain Lua table
-- (no shared-memory lock), and each worker writes its own clicks to Postgres
-- through api.internal_record_clicks:
--   * as soon as BATCH clicks are waiting, and at least every flush interval;
--   * by swapping the buffer for an empty one, so draining never walks a
--     shared structure item by item;
--   * one flush at a time per worker; a failed batch is retried with the same
--     id, and Postgres ignores an id it already recorded (no double counting
--     when the first attempt timed out but committed).
-- A redirect never waits for the database.
local cjson = require "cjson.safe"

local _M = {}
local BATCH = 5000      -- clicks per POST

local buffer, buffered = {}, 0
local carry             -- { items, from, n }: clicks left over from a failed flush, sent first
local max_buffered      -- clicks this worker may hold: CLICK_BUFFER split across workers
local dropped = 0       -- since the last report
local pending           -- { id = ..., body = ... }: the batch that failed, retried first
local flushing = false
local scheduled = false  -- an immediate flush is already queued
local batch_seq = 0

-- Keep printable ASCII only, capped at the column limit. Headers are client
-- input: one invalid UTF-8 byte would make Postgres reject the whole batch.
local function clean(s, max)
    if not s then return nil end
    return (s:gsub("[^\32-\126]", "")):sub(1, max)
end

-- Minimal HTTP/1.0 POST over a cosocket (ngx.location.capture is not available in
-- timers). Returns the status code and the response body, or nil and an error.
local function post(path, body)
    local sock = ngx.socket.tcp()
    sock:settimeout(5000)
    local ok, err = sock:connect("postgrest", 3000)
    if not ok then return nil, err end
    local sent, serr = sock:send(table.concat({
        "POST ", path, " HTTP/1.0\r\n",  -- 1.0: no chunked response to decode
        "Host: postgrest\r\n",
        "Content-Type: application/json\r\n",
        "Content-Length: ", #body, "\r\n",
        "Connection: close\r\n\r\n",
        body,
    }))
    if not sent then sock:close(); return nil, serr end
    local response, rerr = sock:receive("*a")  -- Connection: close, so this reads to the end
    sock:close()
    if not response then return nil, rerr end
    return tonumber(response:match("^HTTP/%d%.%d (%d+)")), response:match("\r\n\r\n(.*)$")
end

-- Sends one batch. Returns true when it is done with (written, or rejected as
-- bad data), false when it should be retried.
local function send(batch)
    local status, err = post("/rpc/internal_record_clicks", batch.body)
    if status == 200 then
        return true
    end
    if status and status < 500 then
        -- The batch itself is bad; retrying it would block the queue forever.
        ngx.log(ngx.ERR, "click batch ", batch.id, " rejected (", status, "), dropping it")
        return true
    end
    ngx.log(ngx.ERR, "click batch ", batch.id, " failed (", status or err, "), will retry")
    return false
end

local function carried()
    return carry and carry.n - carry.from + 1 or 0
end

-- Sends items[from..n] in batches. On a failure, keeps the failed batch as
-- pending and the rest as carry (no copying), and returns false.
local function send_all(items, from, n)
    for first = from, n, BATCH do
        local last = math.min(first + BATCH - 1, n)
        batch_seq = batch_seq + 1
        local id = ngx.worker.pid() .. "-" .. ngx.time() .. "-" .. batch_seq
        local batch = {
            id = id,
            body = '{"p_batch":"' .. id .. '","p_clicks":[' .. table.concat(items, ",", first, last) .. ']}',
        }
        if not send(batch) then
            pending = batch
            carry = last < n and { items = items, from = last + 1, n = n } or nil
            return false
        end
    end
    return true
end

local function flush()
    if pending then
        if not send(pending) then return end
        pending = nil
    end
    if carry then
        local c = carry
        carry = nil
        if not send_all(c.items, c.from, c.n) then return end
    end
    while buffered > 0 do
        local items, n = buffer, buffered
        buffer, buffered = {}, 0  -- swap: redirects keep appending to the new table
        if not send_all(items, 1, n) then return end
    end
end

local function run()
    if flushing then return end
    flushing = true
    local ok, err = pcall(flush)
    flushing = false
    if not ok then ngx.log(ngx.ERR, "click flush error: ", err) end
end

-- One log line per worker per interval for everything dropped since the last one.
local function tick()
    if dropped > 0 then
        ngx.log(ngx.WARN, "dropped ", dropped, " clicks since the last flush: the click buffer is full")
        dropped = 0
    end
    run()
end

function _M.push(code, referrer, user_agent, ip)
    if buffered + carried() >= max_buffered then
        dropped = dropped + 1  -- Postgres down or too slow
        return
    end
    buffered = buffered + 1
    buffer[buffered] = cjson.encode({
        code = code, ts = ngx.now(), ip = ip,
        referrer = clean(referrer, 2048), user_agent = clean(user_agent, 512),
    })
    if buffered >= BATCH and not flushing and not scheduled then
        scheduled = true  -- a full batch goes now, not at the next tick
        ngx.timer.at(0, function() scheduled = false; run() end)
    end
end

-- Partition upkeep for the clicks table (api.internal_maintain_clicks): create the
-- coming days, drop days past retention. Logged, since it deletes data.
local function maintain(premature, retention_days)
    if premature then return end
    local status, body = post("/rpc/internal_maintain_clicks",
                              '{"p_retention_days":' .. retention_days .. '}')
    if status == 200 then
        ngx.log(ngx.NOTICE, "click partitions maintained (retention ", retention_days, " days): ", body)
    else
        ngx.log(ngx.ERR, "click partition maintenance failed (", status or body, "), retrying in an hour")
    end
end

function _M.start(interval, total_buffer, retention_days)
    -- Size by total, not per worker: memory stays bounded however many workers run.
    max_buffered = math.max(1, math.ceil(total_buffer / ngx.worker.count()))
    -- On shutdown the timer fires once more with premature = true; flush then too.
    ngx.timer.every(interval, tick)
    if ngx.worker.id() == 0 then
        ngx.timer.at(0, maintain, retention_days)
        ngx.timer.every(3600, maintain, retention_days)
    end
end

return _M
