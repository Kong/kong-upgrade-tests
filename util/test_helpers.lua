require "luarocks.loader"
local surl = require "socket.url"
local cjson = require "cjson"

local _M = {}
local http = require "resty.http"

local function extract_host_port(url)
  local parsed = assert(surl.parse(url))

  local host = parsed.host
  if not host then
    error("mising host in url")
  end

  local port = tonumber(parsed.port)
  if not port then
    error("missing or invalid port in url")
  end

  return host, port
end


local function build_request_function(http_method)
  return function(self, opts)
    local headers = opts.headers or {}
    local timeout = opts.timeout or 3000
    local body = opts.body
    local path = opts.path

    headers["Content-Type"] = headers["Content-Type"] or "application/json"

    if not self.scheme then
      error("missing self.scheme")
    end

    if not self.host then
      error("missing self.host")
    end

    if not self.port then
      error("missing self.port")
    end

    if not http_method then
      error("missing http method")
    end

    if not path then
      error("missing opts.path")
    end

    if headers["Content-Type"] == "application/json" and type(body) == "table" then
      body = assert(cjson.encode(body))
    end

    local httpc = assert(http.new())

    httpc:set_timeout(timeout)

    assert(httpc:connect(self.host, self.port))

    if self.scheme == "https" then
      assert(httpc:ssl_handshake(nil, self.host, false))
    end

    local res = assert(httpc:request {
      method = http_method,
      path = path,
      body = body,
      headers = headers,
    })

  --[[
    print()
    print(require('inspect'){
      method = http_method,
      path = path,
      body = body ~= nil and body ~= "" and cjson.decode(body) or nil,
      headers = headers,
      scheme = self.scheme,
    })
    print()
  --]]

    local status = res.status
    local res_headers = res.headers
    local res_body = assert(res:read_body())

    assert(httpc:close())

    res_body = assert(cjson.decode(res_body))

    return {
      status = status,
      headers = res_headers,
      body = res_body,
    }
  end
end


local _httpc_mt = {
  __index = function(self, k)
    -- :get / :post / ...
    local f = build_request_function(string.upper(k))
    -- memoize the function so it is not rebuilt on every call to get/post/etc
    rawset(self, k, f)
    return f
  end,
}


function _M.new_http_client(name, url, scheme)
  if not url then
    error("missing " .. name .. " url", 2)
  end

  local host, port = extract_host_port(url)

  return setmetatable({
    host = host,
    port = port,
    scheme = scheme,
  }, _httpc_mt)
end


return _M
