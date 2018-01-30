require "luarocks.loader"
cjson = require "cjson"
assert = require "luassert"


local _M = {}


do
  local surl = require "socket.url"


  function _M.extract_host_port(url)
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
end


do
  local http = require "resty.http"


  local function request(method)
    return function(self, opts)
      local scheme = opts.scheme or "http"
      local headers = opts.headers or {}
      local timeout = opts.timeout or 3000

      if not self.host then
        error("missing self.host")
      end

      if not self.port then
        error("missing self.port")
      end

      if not method then
        error("missing method")
      end

      if not opts.path then
        error("missing opts.path")
      end

      local httpc = assert(http.new())

      httpc:set_timeout(timeout)

      if scheme == "https" then
        assert(httpc:ssl_handshake(nil, opts.host, false))
      end

      assert(httpc:connect(self.host, self.port))

      local res = assert(httpc:request {
        method = opts.method,
        path = opts.path,
        headers = headers,
      })

      local status = res.status
      local headers = res.headers
      local res_body = assert(res:read_body())

      assert(httpc:close())

      return {
        status = status,
        headers = headers,
        body = res_body,
      }
    end
  end


  local _httpc_mt = {}


  function _M.configure_http_clients(admin_url, proxy_url)
    if not admin_url then
      error("missing admin_url", 2)
    end

    if not proxy_url then
      error("missing proxy_url", 2)
    end

    local admin_host, admin_port = _M.extract_host_port(admin_url)
    local proxy_host, proxy_port = _M.extract_host_port(proxy_url)

    local admin_c = {
      host = admin_host,
      port = admin_port,
    }

    local proxy_c = {
      host = proxy_host,
      port = proxy_port,
    }

    return setmetatable(admin_c, _httpc_mt), setmetatable(proxy_c, _httpc_mt)
  end


  function _httpc_mt.__index(self, k)
    local raw_v = rawget(self, k)
    if type(raw_v) == "function" then
      return raw_v
    end

    -- :get / :post / ...
    return request(string.upper(k))
  end
end


if not arg[1] then
  error("must be given admin_url")
end

if not arg[2] then
  error("must be given proxy_url")
end


admin_c, proxy_c = _M.configure_http_clients(arg[1], arg[2])

