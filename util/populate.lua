require "luarocks.require"
local http  = require "resty.http"
local url   = require "socket.url"
local cjson = require "cjson"


local function exit(message, ...)
  local fmt = string.format
  io.stderr:write(fmt(fmt("ERROR: %s\n", message), ...))
  os.exit(1)
end


local function show_usage()
  exit("Usage: resty populate.lua http://kong-host:kong-port [upgrade_path]")
end


local function get_kong_host_and_port(param)
  if not param or param == "" then
    show_usage()
  end

  local parsed, err = url.parse(param)
  local host = parsed.host
  if not host then
    exit("could not parse host from provided url (%s). Error: %s", param, err)
  end

  local port = tonumber(parsed.port)
  if not port then
    exit("could not parse port from provided url (%s)", param)
  end

  return host, port
end


local function read_json_file(filepath)
  local f, err = io.open(filepath)
  if not f then
    exit("could not open file: %s", err)
  end

  local str = f:read("*all")
  f:close()

  local data, err2 = cjson.decode(str)
  if not data then
    exit("could not parse JSON from file %s. Error: %s",
         filepath, err2)
  end

  return data
end


local function is_sequence(tbl)
  if type(tbl) ~= "table" then
    return false
  end

  local i = 0
  for _ in pairs(tbl) do
    i = i + 1
    if tbl[i] == nil then
      return false
    end
  end
  return true, i
end


local function is_valid_http_method(method)
  return method == "GET" or
         method == "POST" or
         method == "PUT" or
         method == "PATCH" or
         method == "DELETE"
end


local function parse_foreign_key_value(value, responses)
  if type(value) == "string" then
    local name, field_name = string.match(value, "(.+)%.(.+)")
    if not name or not field_name then
      exit("could not parse name and fieldname from %s", value)
    end
    local response = responses[name]
    if not response then
      exit("could not find response %s when parsing %s", name, value)
    end
    local field = response[field_name]
    if not field then
      exit("could not find the value of the field %s in the response named %s", field_name, name)
    end
    return field

  elseif type(value) == "table" then
    local result = {}
    local sub = string.sub
    for k,v in pairs(value) do
      if type(k) == "string" and sub(k, 1, 1) == "*" then
        result[sub(k, 2, #k)] = parse_foreign_key_value(v, responses)

      else
        result[k] = v
      end
    end

    return result
  end

  exit("foreign key %s must be either a string or a table", value)
end


local function parse_request_body(input_body, responses)
  if type(input_body) ~= "table" then
    return input_body
  end

  local body = {}
  local sub = string.sub
  for k, v in pairs(input_body) do
    if type(k) == "string" and sub(k, 1, 1) == "*" then
      local fk_field_name = sub(k, 2, #k)
      body[fk_field_name] = parse_foreign_key_value(v, responses)

    else
      body[k] = v
    end
  end

  return body
end


local function parse_request(request, pos, responses)
  local ok, len = is_sequence(request)
  if not ok or len < 3 then
    exit("request #%d: must be an array of at least 3 elements", pos)
  end

  local name = request[1]
  if type(name) ~= "string" then
    exit("request #%d: name must be a string. Found %s (a %s)",
         pos, tostring(name), type(name))
  end

  if name ~= "" and name ~= "_" and responses[name] then
    exit("request #%d (%s): name already exists",
          pos, name)
  end

  local method = request[2]
  if not is_valid_http_method(method) then
    exit("request #%d (%s): %s (a %s) is not a valid http method",
         pos, name, tostring(method), type(method))
  end

  local path = request[3]
  if type(path) ~= "string" then
    exit("request #%d (%s): path must be a string. Found %s (a %s)",
      pos, name, tostring(path), type(path))
  end

  local body = parse_request_body(request[4], responses) or {}

  return name, method, path, body
end


local function send_http_request(method, host, port, path, body, timeout)
  timeout = timeout or 10

  local httpc = assert(http.new())
  local ok, err = httpc:connect(host, port, timeout)
  if not ok then
    exit("could not connect to kong (%s:%s) - %s",
         host, port, err)
  end

  -- build body
  local res, err2 = httpc:request({
    method = method,
    path   = path,
    body   = cjson.encode(body),
    headers = { ["Content-Type"] = "application/json" },
  })
  if not res then
    exit("http request %s %s failed with message: %s", method, path, err2)
  end

  local res_body, err3 = res:read_body()
  if not res_body then
    exit("could not read http response body: %s", err3)
  end

  if res.status >= 300 then
    exit("the request %s %s returned a non-success status %d. Body: %s ",
         method, path, res.status, res_body)
  end

  local response, err4 = cjson.decode(res_body)
  if not response then
    exit("could not parse json response from '%s'. Error: %s",
         res_body, err4)
  end

  return response
end


local function execute_requests(requests, host, port)
  local ok, len = is_sequence(requests)
  if not ok or len == 0 then
    exit("expected requests to be be an array")
  end

  local responses = {}
  for i=1,len do
    local request = requests[i]
    local name, method, path, body = parse_request(request, i, responses)
    print(string.format("%s = %s %s", name, method, path))
    local response = send_http_request(method, host, port, path, body)
    responses[name] = response
  end
end


------

local kong_host, kong_port = get_kong_host_and_port(arg[1])
local upgrade_path = arg[2]
if not upgrade_path then
  show_usage()
end

local requests = read_json_file(upgrade_path .. "/data.json")
execute_requests(requests, kong_host, kong_port)

os.exit(0)
