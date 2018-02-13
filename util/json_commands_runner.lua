local json_commands = require "util.json_commands"

local function show_usage()
  io.stderr:write(
    "Usage: resty json_commands_runner.lua admin:port proxy:port admin_ssl:port proxy_ssl:port filepath\n")
  os.exit(1)
end

------

if not arg[1] or not arg[2] or not arg[3] or not arg[4] or not arg[5] then
  show_usage()
end

json_commands.execute(arg[1], arg[2], arg[3], arg[4], arg[5])

os.exit(0)
