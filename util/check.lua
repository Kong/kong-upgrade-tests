local cjson = require "cjson"
local assert = require "luassert"


local check = {}


local function assert_table_match(expected, given)
  for k, v in pairs(expected) do
    if type(v) == "table" then
      assert.table(given[k], "expected an object at key '" .. k .. "'")
      assert_table_match(v, given[k])
    else
      local pk = tostring(k):match("^%%(.*)$")
      if pk then
        assert.match(v, given[pk], "mismatch at key '" .. k .. "'")
      else
        assert.same(v, given[k], "mismatch at key '" .. k .. "'")
      end
    end
  end
end


function check.res(res, status, expected, headers)
  assert.same(status, res.status, res.body)
  local expected_t = cjson.decode(expected)
  local body_t = cjson.decode(res.body)
  assert_table_match(expected_t, body_t)

  if headers then
    assert_table_match(headers, res.headers)
  end
  return body_t
end


return check
