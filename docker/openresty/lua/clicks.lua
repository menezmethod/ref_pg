-- Click buffer: redirects push clicks onto a shared-memory queue, and worker 0
-- writes them to Postgres in one batch per interval through
-- api.internal_record_clicks. A redirect never waits for the database.
local cjson = require "cjson.safe"

local _M = {}
local queue = ngx.shared.click_queue
local BATCH = 5000

-- Keep printable ASCII only, capped at the column limit. Headers are client
-- input: one invalid UTF-8 byte would make Postgres reject the whole batch.
local function clean(s, max)
    if not s then return nil end
    return (s:gsub("[^\32-\126]", "")):sub(1, max)
end

function _M.push(code, referrer, user_agent, ip)
    local ok = queue:rpush("q", cjson.encode({
        code = code, ts = ngx.now(), ip = ip,
        referrer = clean(referrer, 2048), user_agent = clean(user_agent, 512),
    }))
    if not ok then
        -- Queue full (Postgres down or too slow). Count instead of logging each
        -- one: at full traffic that would be tens of thousands of lines a second.
        queue:incr("dropped", 1, 0)
    end
end

-- Minimal HTTP/1.1 POST over a cosocket (ngx.location.capture is not available in
-- timers). Returns the status code, or nil and an error.
local function post(path, body)
    local sock = ngx.socket.tcp()
    sock:settimeout(5000)
    local ok, err = sock:connect("postgrest", 3000)
    if not ok then return nil, err end
    sock:send(table.concat({
        "POST ", path, " HTTP/1.1\r\n",
        "Host: postgrest\r\n",
        "Content-Type: application/json\r\n",
        "Content-Length: ", #body, "\r\n",
        "Connection: close\r\n\r\n",
        body,
    }))
    local line, rerr = sock:receive("*l")
    sock:close()
    if not line then return nil, rerr end
    return tonumber(line:match("^HTTP/%d%.%d (%d+)"))
end

-- One log line per flush interval for everything dropped since the last one.
local function report_drops()
    local n = queue:get("dropped") or 0
    if n > 0 then
        queue:incr("dropped", -n)
        ngx.log(ngx.WARN, "dropped ", n, " clicks since the last flush: the click queue is full")
    end
end

local function flush()
    while true do
        local items = {}
        for _ = 1, BATCH do
            local item = queue:lpop("q")
            if not item then break end
            items[#items + 1] = item
        end
        if #items == 0 then return end

        local status, err = post("/rpc/internal_record_clicks",
            '{"p_clicks":[' .. table.concat(items, ",") .. ']}')
        if status ~= 200 then
            -- Retry only what can succeed later (Postgres or PostgREST down). A 4xx
            -- means the batch itself is bad; retrying it would block the queue forever.
            if status and status < 500 then
                ngx.log(ngx.ERR, "click flush rejected (", status, "), dropping ", #items)
            else
                local lost = 0
                for _, item in ipairs(items) do
                    if not queue:rpush("q", item) then lost = lost + 1 end
                end
                if lost > 0 then queue:incr("dropped", lost, 0) end
                ngx.log(ngx.ERR, "click flush failed (", status or err, "), re-queued ",
                        #items - lost, ", lost ", lost, " (queue full)")
            end
            return
        end
        if #items < BATCH then return end
    end
end

-- ngx.timer.every starts a new run each interval even while the last one is
-- stuck on a slow Postgres. Overlapping flushes would each hold up to BATCH
-- clicks outside the queue, so the queue would never fill and its size limit
-- would mean nothing. Only worker 0 flushes, so a local flag is enough.
local flushing = false
local function tick()
    report_drops()
    if flushing then return end
    flushing = true
    local ok, err = pcall(flush)
    flushing = false
    if not ok then ngx.log(ngx.ERR, "click flush error: ", err) end
end

function _M.start(interval)
    -- Create the counter while there is room, so incr never needs to allocate.
    queue:add("dropped", 0)
    if ngx.worker.id() ~= 0 then return end
    -- On shutdown the timer fires once more with premature = true; flush then too.
    ngx.timer.every(interval, tick)
end

return _M
