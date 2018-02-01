local cjson = require "cjson"
local util = require "util.test_helpers"
local admin_c, proxy_ssl_c = util.admin_c, util.proxy_ssl_c

local function json_res(res)
  if res.status >= 300 then
    error(string.format(
          "Expected a success status, but received %d.\nResponse body: %s",
          res.status,
          res.body))
  end
  return assert(cjson.decode(res.body))
end

-- oauth2 base tests
local oauth_api = json_res(admin_c:post {
  path = "/apis",
  body = {
    name = "oauth2_api",
    hosts = "oauth2.com",
    upstream_url = "https://mockbin.org",
  },
})

local consumer = json_res(admin_c:post {
  path = "/consumers",
  body = {
    username = "oauth2_consumer"
  },
})

json_res(admin_c:post {
  path = "/plugins",
  body = {
    name   = "oauth2",
    api_id = oauth_api.id,
    config = {
      scopes                    = { "email", "profile", "user.email" },
      enable_authorization_code = true,
      mandatory_scope           = true,
      provision_key = "provision123",
    },
  }
})


json_res(admin_c:post{
  path = "/consumers/" .. consumer.id .. "/oauth2",
  body = {
    name = "testapp",
    client_id = "clientid123",
    client_secret = "secret123",
    redirect_uri = "http://google.com/kong",
    consumer_id = consumer.id
  }
})

local auth = json_res(proxy_ssl_c:post {
  path = "/oauth2/authorize",
  scheme = "https",
  body = {
    provision_key = "provision123",
    authenticated_userid = "id123",
    client_id = "clientid123",
    scope = "email",
    response_type = "code"
  },
  headers = {
    ["Host"] = "oauth2.com",
    ["Content-Type"]      = "application/json",
    ["X-Forwarded-Proto"] = "https",
  }
})

assert(ngx.re.match(auth.redirect_uri,
                    "^http://google\\.com/kong\\?code=[\\w]{32,32}$"))

