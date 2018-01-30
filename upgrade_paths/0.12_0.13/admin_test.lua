local res = admin_c:get {
  path = "/apis"
}
assert.equal(200, res.status)
print(res.status)
print(res.headers)
print(res.body)
