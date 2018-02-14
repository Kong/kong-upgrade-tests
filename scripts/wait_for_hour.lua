#!/usr/bin/env resty

local socket = require "socket"

-- Check to prevent the next requests from running at the turn of the hour :)
while tonumber(os.date("%M")) == 59 do
  socket.sleep(0.1)
end
