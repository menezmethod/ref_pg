-- code -> URL cache with stale-while-revalidate.
--   * Fresh entry: answered from memory.
--   * Expired entry: one request per code refreshes it (a lock in
--     ngx.shared.link_locks); every other request keeps getting the old URL.
--   * Postgres cannot answer: the old URL keeps being served, and the refresh
--     is retried every RETRY_SECONDS.
-- A takedown (is_active = false) therefore reaches clients after the entry
-- expires and one refresh succeeds.
local cjson = require "cjson.safe"

local _M = {}
local links = ngx.shared.links
local locks = ngx.shared.link_locks

local RETRY_SECONDS = 5  -- after a failed refresh, serve the old URL this long before retrying
local LOCK_SECONDS = 4   -- longer than the /_lookup timeouts in nginx.conf
local WAIT_STEP = 0.005  -- how often a cold miss checks whether the lookup it waits on finished

-- Returns the URL, "" for an unknown code, or nil when Postgres could not answer.
local function lookup(code)
    local res = ngx.location.capture("/_lookup", {
        method = ngx.HTTP_POST,
        body = cjson.encode({ p_code = code }),
    })
    if res.status ~= 200 then
        ngx.log(ngx.ERR, "internal_lookup_link failed: ", res.status, " ", res.body)
        return nil
    end
    -- PostgREST returns a JSON string for a hit and null for a miss.
    local url = cjson.decode(res.body)
    return type(url) == "string" and url or ""
end

-- Same contract as lookup(), served from the cache when possible.
function _M.resolve(code, ttl, negative_ttl)
    if ttl == 0 then
        return lookup(code)  -- cache off
    end

    local url, _, stale = links:get_stale(code)
    if url ~= nil and not stale then
        return url
    end

    if not locks:add(code, true, LOCK_SECONDS) then
        -- Another request is already refreshing this code.
        if url ~= nil then
            return url  -- serve the old URL meanwhile
        end
        -- Cold miss: wait for that lookup instead of sending a duplicate.
        for _ = 1, LOCK_SECONDS / WAIT_STEP do
            ngx.sleep(WAIT_STEP)
            local fresh = links:get(code)
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
    if fresh then
        local t = fresh == "" and negative_ttl or ttl
        if t > 0 then links:set(code, fresh, t) end  -- 0 means "never expire" to ngx.shared
    elseif url ~= nil then
        links:set(code, url, RETRY_SECONDS)  -- Postgres is down: keep serving the old URL
        fresh = url
    end
    locks:delete(code)
    return fresh
end

return _M
