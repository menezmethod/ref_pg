-- code -> URL cache with stale-while-revalidate.
--   * Fresh entry: answered from memory.
--   * Expired entry: one request per code refreshes it (a lock in
--     ngx.shared.link_locks); every other request keeps getting the old URL.
--   * Postgres cannot answer: the old URL keeps being served, and the refresh
--     is retried every RETRY_SECONDS.
--   * Unknown codes are cached in their own dict (link_misses), so a scan of
--     random codes cannot evict real links.
--   * At most LOOKUP_CONCURRENCY lookups (split across workers) wait on
--     Postgres at once. Past that, a refresh serves the old URL and a cold miss
--     gets 503 at once, instead of queueing until every request is slow.
--     Little's law: wait = lookups in flight / lookups per second, so the cap
--     sets the worst-case wait on a node of known capacity.
-- A takedown (is_active = false) therefore reaches clients after the entry
-- expires and one refresh succeeds.
local cjson = require "cjson.safe"

local _M = {}
local links = ngx.shared.links
local misses = ngx.shared.link_misses
local locks = ngx.shared.link_locks

local RETRY_SECONDS = 5  -- after a failed refresh, serve the old URL this long before retrying
local LOCK_SECONDS = 4   -- longer than the /_lookup timeouts in nginx.conf
local WAIT_STEP = 0.005  -- how often a cold miss checks whether the lookup it waits on finished

_M.BUSY = {}  -- returned when the lookup was shed; the caller answers 503

local in_flight = 0  -- this worker's lookups waiting on Postgres
local max_in_flight

-- Returns the URL, "" for an unknown code, nil when Postgres could not answer,
-- or _M.BUSY when too many lookups are already in flight.
local function lookup(code)
    if in_flight >= max_in_flight then
        return _M.BUSY
    end
    in_flight = in_flight + 1
    local res = ngx.location.capture("/_lookup", {
        method = ngx.HTTP_POST,
        body = cjson.encode({ p_code = code }),
    })
    in_flight = in_flight - 1
    if res.status ~= 200 then
        ngx.log(ngx.ERR, "internal_lookup_link failed: ", res.status, " ", res.body)
        return nil
    end
    -- PostgREST returns a JSON string for a hit and null for a miss.
    local url = cjson.decode(res.body)
    return type(url) == "string" and url or ""
end

local function cached(code)
    local url = links:get(code)
    if url then return url end
    if misses:get(code) then return "" end
end

local function store(code, url, ttl, negative_ttl)
    if url == "" then
        links:delete(code)  -- taken down or deleted
        if negative_ttl > 0 then misses:set(code, true, negative_ttl) end
    elseif ttl > 0 then  -- 0 means "never expire" to ngx.shared
        links:set(code, url, ttl)
    end
end

-- Same contract as lookup(), served from the caches when possible.
function _M.resolve(code, ttl, negative_ttl)
    if ttl == 0 then
        return lookup(code)  -- cache off
    end

    local url, _, stale = links:get_stale(code)
    if url ~= nil and not stale then
        return url
    end
    if url == nil and misses:get(code) then
        return ""
    end

    if not locks:add(code, true, LOCK_SECONDS) then
        -- Another request is already refreshing this code.
        if url ~= nil then
            return url  -- serve the old URL meanwhile
        end
        -- Cold miss: wait for that lookup instead of sending a duplicate.
        for _ = 1, LOCK_SECONDS / WAIT_STEP do
            ngx.sleep(WAIT_STEP)
            local fresh = cached(code)
            if fresh ~= nil then
                return fresh
            end
            if not locks:get(code) then
                break  -- it finished without caching anything (failed, or caching is off for misses)
            end
        end
        return lookup(code)
    end

    local fresh = lookup(code)
    if fresh == _M.BUSY or fresh == nil then
        if url ~= nil then
            links:set(code, url, RETRY_SECONDS)  -- keep serving the old URL; retry later
            fresh = url
        end
    else
        store(code, fresh, ttl, negative_ttl)
    end
    locks:delete(code)
    return fresh
end

function _M.start(total_lookups)
    max_in_flight = math.max(1, math.floor(total_lookups / ngx.worker.count()))
end

return _M
