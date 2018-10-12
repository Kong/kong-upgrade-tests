local json_commands = require "util.json_commands"

local function show_usage()
  io.stderr:write(
    "\nUsage: resty json_commands_runner.lua filepath" ..
    "\nThe command expects the following environment variables to be set: " ..
    "\n* $ADMIN_LISTEN" ..
    "\n* $PROXY_LISTEN" ..
    "\n* $ADMIN_LISTEN_SSL" ..
    "\n* $PROXY_LISTEN_SSL" ..
    "\n* $ADMIN_LISTEN_2" ..
    "\n* $PROXY_LISTEN_2" ..
    "\n* $ADMIN_LISTEN_SSL_2" ..
    "\n* $PROXY_LISTEN_SSL_2" ..
    "\nIf any of these is missing, it will just exit with this error message."
  )
  os.exit(1)
end

------

local admin       = os.getenv("ADMIN_LISTEN")
local proxy       = os.getenv("PROXY_LISTEN")
local admin_ssl   = os.getenv("ADMIN_LISTEN_SSL")
local proxy_ssl   = os.getenv("PROXY_LISTEN_SSL")
local admin_2     = os.getenv("ADMIN_LISTEN_2")
local proxy_2     = os.getenv("PROXY_LISTEN_2")
local admin_ssl_2 = os.getenv("ADMIN_LISTEN_SSL_2")
local proxy_ssl_2 = os.getenv("PROXY_LISTEN_SSL_2")

if not arg[1]
  or not admin or not admin_ssl or not proxy or not proxy_ssl
  or not admin_2 or not admin_ssl_2 or not proxy_2 or not proxy_ssl_2 then
  show_usage()
end

json_commands.execute({
    admin = "http://" .. admin,
    proxy = "http://" .. proxy,
    admin_ssl = "https://" .. admin_ssl,
    proxy_ssl = "https://" .. proxy_ssl,
    admin_2 = "http://" .. admin_2,
    proxy_2 = "http://" .. proxy_2,
    admin_ssl_2 = "https://" .. admin_ssl_2,
    proxy_ssl_2 = "https://" .. proxy_ssl_2,
  },
  arg[1])

os.exit(0)
