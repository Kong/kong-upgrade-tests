
local test_helpers = require "util.test_helpers"
local check = require "util.check"
local admin_c = test_helpers.admin_c

local res = admin_c:get {
  path = "/apis"
}
local total = 4
local apis = check.res(res, 200, [[
{
  "total": ]] .. total .. [[
}
]])

local api_data = {
  ["simple_api"] = [[
    {
      "strip_uri": true,
      "hosts": ["simple-api.com"],
      "name": "simple_api",
      "http_if_terminated": false,
      "https_only": false,
      "retries": 5,
      "preserve_host": false,
      "upstream_connect_timeout": 60000,
      "upstream_read_timeout": 60000,
      "upstream_send_timeout": 60000,
      "upstream_url": "http://simple-api.com/api"
    }
  ]],
  ["complex_api"] = [[
    {
      "strip_uri": true,
      "hosts": ["complex-api.com"],
      "name": "complex_api",
      "methods": ["GET"],
      "http_if_terminated": false,
      "https_only": false,
      "retries": 5,
      "uris": ["/secret","/public"],
      "preserve_host": false,
      "upstream_connect_timeout": 60000,
      "upstream_read_timeout": 60000,
      "upstream_send_timeout": 60000,
      "upstream_url": "http://complex-api.com/api"
    }
  ]],
  ["basic_auth_api"] = [[
    {
      "strip_uri": true,
      "hosts": ["basic-auth-api.com"],
      "name": "basic_auth_api",
      "http_if_terminated": false,
      "https_only": false,
      "retries": 5,
      "preserve_host": false,
      "upstream_connect_timeout": 60000,
      "upstream_read_timeout": 60000,
      "upstream_send_timeout": 60000,
      "upstream_url": "http://basic-auth-api.com"
    }
  ]],
  ["oauth2_api"] = [[
    {
      "strip_uri": true,
      "hosts": ["oauth2.com"],
      "name": "oauth2_api",
      "http_if_terminated": false,
      "https_only": false,
      "retries": 5,
      "preserve_host": false,
      "upstream_connect_timeout": 60000,
      "upstream_read_timeout": 60000,
      "upstream_send_timeout": 60000,
      "upstream_url": "https://mockbin.org"
    }
  ]],
}

for i = 1, total do
  local name = apis.data[i].name
  local data = assert(api_data[name], name)
  local res = admin_c:get {
    path = "/apis/" .. name
  }
  check.res(res, 200, data)
end
