package.path = "./?.lua;" .. package.path

local ResponseUtil = require("ResponseUtil")

assert(ResponseUtil.isHtml("<!DOCTYPE html><html><body>Not Found</body></html>"))
assert(ResponseUtil.isHtml("   <html><head><title>Error</title></head></html>"))
assert(ResponseUtil.isHtml("<div><head><title>Proxy error</title></head></div>"))
assert(not ResponseUtil.isHtml('{"message":"Not found"}'))
assert(not ResponseUtil.isHtml("plain text error"))
assert(not ResponseUtil.isHtml(nil))

print("response_util_test.lua: OK")
