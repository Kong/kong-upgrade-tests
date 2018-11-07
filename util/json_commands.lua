require "luarocks.require"
local cjson = require "cjson"
local test_helpers = require "util.test_helpers"
local assert = require "luassert"
local pretty = require "pl.pretty"
local file = require "pl.file"
local pgmoon = require "pgmoon"


local _M = {}


local function exit(message, ...)
  local fmt = string.format
  io.stderr:write(fmt(fmt("ERROR: %s\n", message), ...))
  os.exit(1)
end


local function assert_table_match(expected, given, context)
  if type(expected) ~= "table" or type(given) ~= "table" then
    return
  end

  for k, v in pairs(expected) do
    local pk = tostring(k):match("^%%(.*)$")
    if pk then
      local errmsg = context .. ": regex mismatch at key '" .. k .. "':\n" ..
                     "Given: \n" ..
                     "(string) " .. given[pk] .. "\n" ..
                     "Expected to match: \n" ..
                     "(regex) " .. v
      assert(ngx.re.match(given[pk], v), errmsg)

    else
      if type(v) ~= type(given[k]) then
        exit("%s: expected object at key '%s' to be of type %s", context, tostring(k), type(v))
      end
      if type(v) == "table" then
        assert_table_match(v, given[k], context .. "." .. k)
      else
        assert.same(v, given[k], context .. ": mismatch at key '" .. k .. "'")
      end
    end
  end
end


local function read_json_file(filepath)
  local f, err = io.open(filepath)
  if not f then
    exit("could not open file: %s", err)
  end

  local str = f:read("*all")
  f:close()

  local pok, data, err2 = pcall(cjson.decode, str)
  if not (pok and data) then
    exit("could not parse JSON from file %s - Error: %s",
      filepath, data or err2)
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


local function parse_string_with_inline_expressions(input, context, responses)
  return string.gsub(input,"(#%{(.-)})", function(_, expr)
    local name, field_name = string.match(expr, "(.+)%.(.+)")
    if not name or not field_name then
      exit("%s: could not parse name and fieldname from %s", context, expr)
    end
    local response = responses[name]
    if not response then
      exit("%s: could not find response %s when parsing %s", context, name, expr)
    end
    local field = response[field_name]
    if not field then
      exit("%s: could not find the value of the field %s in the response named %s", context, field_name, name)
    end
    return field
  end)
end


local function parse_table_with_inline_expressions(input, context, responses)
  if type(input) ~= "table" then
    return input
  end

  local res = {}
  for k, v in pairs(input) do
    local subcontext = context .. "/" .. k
    if type(v) == "string" then
      v = parse_string_with_inline_expressions(v, subcontext, responses)
    elseif type(v) == "table" then
      v = parse_table_with_inline_expressions(v, subcontext, responses)
    end
    res[k] = v
  end
  return res
end


local function parse_command_path(path, context, responses)
  if type(path) ~= "string" then
    exit("%s: path must be a string. Found %s (a %s)",
         context, tostring(path), type(path))
  end

  return parse_string_with_inline_expressions(path, context .. " path", responses)
end


local function parse_command_shell_request(request, context)
  if #request ~= 2 then
    exit("%s: a shell request must be an array of 2 elements", context)
  end
  return { type = "shell",
           execute = request[2],
         }
end


local function parse_command_psql_request(request, context)
  if #request < 2 then
    exit("%s: a psql request must be an array of 2 elements", context)
  end
  return { type = "psql",
           query = request[2],
         }
end


local function parse_command_http_request(request, http_clients, context, responses)
  if #request < 3 then
    exit("%s: the request must be an array of at least 3 elements", context)
  end
  local httpc_name = request[1]
  local httpc = http_clients[httpc_name]
  if not httpc then
    exit("%s: Invalid host name: %s (a %s). Must be admin, proxy, admin_ssl or proxy_ssl",
         context, tostring(httpc_name), type(httpc_name))
  end

  local method = request[2]
  if not is_valid_http_method(method) then
    exit("%s: %s (a %s) is not a valid http method",
         context, tostring(method), type(method))
  end

  local path    = parse_command_path(request[3], context, responses)
  local body    = parse_table_with_inline_expressions(request[4], context .. " body", responses)
  local headers = parse_table_with_inline_expressions(request[5], context .. " headers", responses)

  return { type = "http",
           httpc = httpc,
           method = method,
           path = path,
           body = body,
           headers = headers,
         }
end


local function parse_command_request(request, http_clients, context, responses)
  local ok, len = is_sequence(request)
  if not ok then
    exit("%s: the request must be an array", context)
  end

  if request[1] == "shell" then
    return parse_command_shell_request(request, context, len)
  end

  if request[1] == "psql" then
    return parse_command_psql_request(request, context, len)
  end

  return parse_command_http_request(request, http_clients, context, responses)
end


local function parse_command_expected_response(expected_response, context, responses)
  local ok, len = is_sequence(expected_response)
  if not ok or len == 0 then
    exit("%s: expected response must be an array of at least 1 element", context)
  end

  local status = expected_response[1]
  if type(status) ~= "number" or status < 0 or status ~= math.floor(status) then
    exit("%s: status must be a positive integer. Found %s (a %s)",
         context, tostring(status), type(status))
  end

  local body    = parse_table_with_inline_expressions(
                    expected_response[2],
                    context .. " body",
                    responses)

  local headers = expected_response[3]

  return { status = status,
           body = body,
           headers = headers }
end


local function parse_command(command, http_clients, pos, responses)
  local ok, len = is_sequence(command)
  if not ok or len ~= 3 then
    exit("command #%d: must be an array of 3 elements", pos)
  end

  local name = command[1]
  if type(name) ~= "string" then
    exit("command #%d: name must be a string. Found %s (a %s)",
         pos, tostring(name), type(name))
  end

  local context = string.format("command #%d (%s)", pos, name)

  if name ~= "" and name ~= "_" and responses[name] then
    exit("%s: name already exists", context)
  end

  local request = parse_command_request(command[2], http_clients, context, responses)

  local expected_response = parse_command_expected_response(
    command[3], context, responses)

  return name, request, expected_response, context
end


local function send_http_request(req)
  return req.httpc[req.method:lower()](req.httpc, {
    path = req.path,
    body = req.body,
    headers = req.headers,
    scheme = req.scheme,
    timeout = req.timeout
  })
end


local function validate_response(res, expected, context)
  assert.same(expected.status, res.status, { context = context, res = res })
  assert_table_match(expected.body, res.body, context)
  assert_table_match(expected.headers, res.headers, context)
end


local function run_shell_command(request)
  local stdout = os.tmpname()
  local stderr = os.tmpname()

  local cmd = "( " .. request.execute .. " ) 1> " .. stdout .. " 2> " .. stderr
  local _, _, rc = os.execute(cmd)

  local fdout = io.open(stdout, "r")
  local out = fdout:read("*a")
  fdout:close()

  local fderr = io.open(stderr, "r")
  local err = fderr:read("*a")
  fderr:close()

  os.remove(stdout)
  os.remove(stderr)

  return {
    status = rc,
    body = {
      stdout = out,
      stderr = err,
    }
  }
end


local function run_psql_command(command)

  local pg = pgmoon.new({
    host = os.getenv("POSTGRES_HOST"),
    port = os.getenv("POSTGRES_PORT"),
    database = os.getenv("POSTGRES_DATABASE"),
    user = "kong",
  })

  assert(pg:connect())
  local res, num_queries = assert(pg:query(command.query))
  assert(pg:disconnect())

  return {
    status = num_queries,
    body = res,
  }
end



local function execute_commands(commands, http_clients, file_path)
  local ok, len = is_sequence(commands)
  if not ok or len == 0 then
    exit("expected commands to be an array")
  end

  local dump = file.read("responses.dump")
  local responses = dump and pretty.read(dump) or {}

  for i = 1, len do
    local command = commands[i]
    local name, request, expected_response, context = parse_command(command, http_clients, i, responses)

    local response, err

    if request.type == "http" then
      response, err = send_http_request(request)

    elseif request.type == "shell" then
      response, err = run_shell_command(request)

    elseif request.type == "psql" then
      response, err = run_psql_command(request)
    end

    print("========================================")
    print("Command: " .. command[1])
    print("========================================")
    pretty.dump(command[2])
    print("----------------------------------------")
    print("Expected response: ")
    pretty.dump(expected_response)
    print("----------------------------------------")
    print("Received Response: ")
    pretty.dump(response)

    validate_response(response, expected_response, context .. " response")
    responses[name] = response.body

    local namespace
    local neg_sub_pos = string.find(string.reverse(file_path), "/", 1, true)
    if neg_sub_pos then
      namespace = string.sub(file_path, -neg_sub_pos + 1)
    end

    local pos_sub_pos = string.find(namespace, "-", 1, true)
    if pos_sub_pos then
      namespace = string.sub(namespace, pos_sub_pos + 1)
    end

    namespace = string.sub(namespace, 1, -6)
    responses[namespace .. ":" .. name] = response.body
  end

  pretty.dump(responses, "responses.dump")

  return responses
end


------

function _M.execute(clients, file_path)
  local http_clients = {}
  for name, url in pairs(clients) do
    http_clients[name] = test_helpers.new_http_client(name, url)
  end

  return execute_commands(read_json_file(file_path), http_clients, file_path)
end

return _M
