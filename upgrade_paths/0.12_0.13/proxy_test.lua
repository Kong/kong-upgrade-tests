
local socket = require "socket"
local test_helpers = require "util.test_helpers"
local check = require "util.check"
local admin_c = test_helpers.admin_c
local proxy_c = test_helpers.proxy_c

local res = admin_c:get {
  path = "/apis"
}
assert(200 == res.status)

-- =============================================================================
-- Routes and Services tutorial
-- =============================================================================

-- Create a Service

-- Make an invalid request to create a Service and observe the new errors
res = admin_c:post {
  path = "/services",
  body = [[
  {}
  ]]
}
check.res(res, 400, [[
{
  "code": 2,
  "fields": {
    "host": "required field missing"
  },
  "message": "schema violation (host: required field missing)",
  "name": "schema violation"
}
]])

-- Create a Service using "url" sugar-parameter
res = admin_c:post {
  path = "/services",
  body = [[
  {
    "url": "http://httpbin.org/anything"
  }
  ]],
}
local service = check.res(res, 201, [[
{
  "%id": "[%x-]+",
  "%created_at": "%d+",
  "%updated_at": "%d+",
  "connect_timeout": 60000,
  "host": "httpbin.org",
  "name": null,
  "path": "/anything",
  "port": 80,
  "protocol": "http",
  "read_timeout": 60000,
  "retries": 5,
  "write_timeout": 60000
}
]])

-- Create Routes

-- Make an invalid request to create a Route
res = admin_c:post {
  path = "/routes",
  body = [[
  {}
  ]]
}
check.res(res, 400, [[
{
  "code": 2,
  "fields": {
      "@entity": [
          "at least one of 'methods', 'hosts' or 'paths' must be non-empty"
      ],
      "service": "required field missing"
  },
  "message": "2 schema violations (at least one of 'methods', 'hosts' or 'paths' must be non-empty; service: required field missing)",
  "name": "schema violation"
}
]])

-- Add a Route (with a Service, mandatory)
res = admin_c:post {
  path = "/routes",
  body = [[
  {
    "hosts": [ "example.com" ],
    "paths": [ "/request" ],
    "service": {
      "id": "]] .. service.id .. [["
    }
  }
  ]]
}
check.res(res, 201, [[
{
  "%id": "[%x-]+",
  "%created_at": "%d+",
  "%updated_at": "%d+",
  "hosts": [
    "example.com"
  ],
  "methods": null,
  "paths": [
    "/request"
  ],
  "preserve_host": false,
  "regex_priority": 0,
  "protocols": [
    "http",
    "https"
  ],
  "service": {
    "id": "]] .. service.id .. [["
  },
  "strip_path": true
}
]])

-- Make a proxy request to httpbin.org
res = proxy_c:get {
  path = "/request",
  headers = {
    Host = "example.com",
  }
}
check.res(res, 200, [[
{
  "args": {},
  "data": "",
  "files": {},
  "form": {},
  "headers": {
    "Host": "httpbin.org",
    "X-Forwarded-Host": "example.com"
  },
  "json": null,
  "method": "GET",
  "url": "http://example.com/anything"
}
]])

-- Add another Route (with a Service, mandatory)
res = admin_c:post {
  path = "/routes",
  body = [[
  {
    "hosts": [ "example.com" ],
    "paths": [ "/expensive" ],
    "service": {
      "id": "]] .. service.id .. [["
    }
  }
  ]]
}
local expensive = check.res(res, 201, [[
{
  "hosts": [
    "example.com"
  ],
  "methods": null,
  "paths": [
    "/expensive"
  ],
  "preserve_host": false,
  "regex_priority": 0,
  "protocols": [
    "http",
    "https"
  ],
  "service": {
    "id": "]] .. service.id .. [["
  },
  "strip_path": true
}
]])

-- Create Kong Consumer and add Key Authentication Credentials

-- Create a Consumer
res = admin_c:post {
  path = "/consumers",
  body = [[
  {
    "username": "bob"
  }
  ]]
}
local consumer = check.res(res, 201, [[
{
  "username": "bob"
}
]])

-- Add an authorization key to the Consumer
res = admin_c:post {
  path = "/consumers/" .. consumer.id .. "/key-auth",
  body = [[
  {
    "key": "secret"
  }
  ]]
}
check.res(res, 201, [[
{
  "consumer_id": "]] .. consumer.id .. [[",
  "key": "secret"
}
]])

-- Add key-auth plugin to a Service
res = admin_c:post {
  path = "/plugins",
  body = [[
  {
    "name": "key-auth",
    "service_id": "]] .. service.id .. [["
  }
  ]]
}
check.res(res, 201, [[
{
  "config": {
    "anonymous": "",
    "hide_credentials": false,
    "key_in_body": false,
    "key_names": [
      "apikey"
    ],
    "run_on_preflight": true
  },
  "enabled": true,
  "name": "key-auth",
  "service_id": "]] .. service.id .. [["
}
]])

-- Confirm that key-auth plugin is working (without API key)
res = proxy_c:get {
  path = "/request",
  headers = {
    Host = "example.com",
  }
}
check.res(res, 401, [[
{
  "message": "No API key found in request"
}
]], {
  ["WWW-Authenticate"] = [[Key realm="kong"]],
})

res = proxy_c:get {
  path = "/expensive",
  headers = {
    Host = "example.com",
  }
}
check.res(res, 401, [[
{
  "message": "No API key found in request"
}
]])

-- Confirm that key-auth plugin is working (with API key)
res = proxy_c:get {
  path = "/request",
  headers = {
    Host = "example.com",
    ApiKey = "secret",
  }
}
check.res(res, 200, [[
{
  "args": {},
  "data": "",
  "files": {},
  "form": {},
  "headers": {
    "Apikey": "secret",
    "Connection": "close",
    "Host": "httpbin.org",
    "X-Consumer-Id": "]] .. consumer.id .. [[",
    "X-Consumer-Username": "bob",
    "X-Forwarded-Host": "example.com"
  },
  "json": null,
  "method": "GET",
  "url": "http://example.com/anything"
}
]])

res = proxy_c:get {
  path = "/expensive",
  headers = {
    Host = "example.com",
    ApiKey = "secret",
  }
}
check.res(res, 200, [[
{
  "args": {},
  "data": "",
  "files": {},
  "form": {},
  "headers": {
    "Apikey": "secret",
    "Connection": "close",
    "Host": "httpbin.org",
    "X-Consumer-Id": "]] .. consumer.id .. [[",
    "X-Consumer-Username": "bob",
    "X-Forwarded-Host": "example.com"
  },
  "json": null,
  "method": "GET",
  "url": "http://example.com/anything"
}
]])

-- Add rate-limiting plugin to a Route
res = admin_c:post {
  path = "/plugins",
  body = [[
  {
    "name": "rate-limiting",
    "route_id": "]] .. expensive.id .. [[",
    "config": {
      "hour": 1
    }
  }
  ]]
}
check.res(res, 201, [[
{
    "config": {
        "fault_tolerant": true,
        "hide_client_headers": false,
        "hour": 1,
        "limit_by": "consumer",
        "policy": "cluster",
        "redis_database": 0,
        "redis_port": 6379,
        "redis_timeout": 2000
    },
    "enabled": true,
    "name": "rate-limiting",
    "route_id": "]] .. expensive.id .. [["
}
]])

-- Check to prevent the next requests from running at the turn of the hour :)
while tonumber(os.date("%M")) == 59 do
  socket.sleep(1)
end

res = proxy_c:get {
  path = "/expensive",
  headers = {
    Host = "example.com",
    ApiKey = "secret",
  }
}
check.res(res, 200, [[
{
  "args": {},
  "data": "",
  "files": {},
  "form": {},
  "headers": {
    "Apikey": "secret",
    "Connection": "close",
    "Host": "httpbin.org",
    "X-Consumer-Id": "]] .. consumer.id .. [[",
    "X-Consumer-Username": "bob",
    "X-Forwarded-Host": "example.com"
  },
  "json": null,
  "method": "GET",
  "url": "http://example.com/anything"
}
]], {
  ["X-RateLimit-Limit-hour"] = "1",
  ["X-RateLimit-Remaining-hour"] = "0",
})

-- Make another request to the rate-limited Route
res = proxy_c:get {
  path = "/expensive",
  headers = {
    Host = "example.com",
    ApiKey = "secret",
  }
}
check.res(res, 429, [[
{
  "message": "API rate limit exceeded"
}
]], {
  ["X-RateLimit-Limit-hour"] = "1",
  ["X-RateLimit-Remaining-hour"] = "0",
})
