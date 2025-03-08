-- Get the short code from the URL
local code = ngx.var.code
ngx.log(ngx.ERR, "Processing redirect for code: " .. code)

-- Make a request to the API to get the original URL
local res = ngx.location.capture("/internal-api", {
    method = ngx.HTTP_POST,
    body = '{"p_code": "' .. code .. '"}',
    args = { path = "rpc/get_original_url" },
    headers = {
        ["Content-Type"] = "application/json"
    }
})

if not res then
    ngx.log(ngx.ERR, "Failed to get original URL")
    ngx.status = 500
    ngx.say("Internal Server Error")
    return ngx.exit(500)
end

ngx.log(ngx.ERR, "API response status: " .. res.status)
if res.body then
    ngx.log(ngx.ERR, "API response body: " .. res.body)
end

-- Check if we got a valid response
if res.status == 200 and res.body and res.body ~= "null" then
    -- Remove any quotes from the response
    local url = res.body:gsub('^"', ''):gsub('"$', '')
    ngx.log(ngx.ERR, "Redirecting to: " .. url)
    
    -- Track the click asynchronously
    local user_agent = ngx.req.get_headers()["User-Agent"] or ""
    local referer = ngx.req.get_headers()["Referer"] or ""
    local ip = ngx.var.remote_addr or ""
    
    local track_res = ngx.location.capture("/internal-api", {
        method = ngx.HTTP_POST,
        body = '{"p_code": "' .. code .. '", "p_referrer": "' .. referer .. '", "p_user_agent": "' .. user_agent .. '", "p_ip_address": "' .. ip .. '"}',
        args = { path = "rpc/track_link_click" },
        headers = {
            ["Content-Type"] = "application/json"
        }
    })
    
    if not track_res then
        ngx.log(ngx.ERR, "Failed to track click")
    else
        ngx.log(ngx.ERR, "Click tracked successfully")
    end
    
    -- Redirect to the original URL
    return ngx.redirect(url, 301)
else
    ngx.log(ngx.ERR, "Short link not found or invalid response")
    ngx.status = 404
    ngx.say("Short link not found")
    return ngx.exit(404)
end 