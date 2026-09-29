-- Build:  lua tools/build.lua        (run from the project root)
-- Output: dist/Granular.lua                     the ONE file users need
--         dist/Effects/Granular/GranularGen.jsfx (the app also writes this itself on first run)
package.path = "./src/?.lua;" .. package.path
local Core = require("GranularCore")
local Jsfx = require("GranularJsfx")

local MODULES = { "GranularCore", "GranularJsfx", "GranularReaper", "GranularEngine", "GranularUI" }

local function read(p)
  local f = assert(io.open(p, "rb"), "cannot read " .. p)
  local s = f:read("*a"); f:close(); return s
end
local function write(p, s)
  local f = assert(io.open(p, "wb"), "cannot write " .. p)
  f:write(s); f:close()
end

-- split the leading comment header (kept at the very top for ReaPack/@version) from the body
local main = read("src/Granular.lua"):gsub("@@VERSION@@", Core.VERSION)
local header, body = {}, main
while true do
  local line, rest = body:match("^([^\n]*)\n(.*)$")
  if line and line:match("^%-%-") then header[#header + 1] = line; body = rest else break end
end

local out = {}
out[#out + 1] = table.concat(header, "\n")
out[#out + 1] = "-- BUNDLED BUILD of Granular v" .. Core.VERSION .. " - edit the files in src/, not this one."
out[#out + 1] = "local __preload = package.preload"
for _, m in ipairs(MODULES) do
  out[#out + 1] = string.format('__preload["%s"] = function(...)\n%s\nend', m, read("src/" .. m .. ".lua"))
end
out[#out + 1] = body

os.execute("mkdir -p dist/Effects/Granular")
write("dist/Granular.lua", table.concat(out, "\n") .. "\n")
write("dist/Effects/Granular/GranularGen.jsfx", Jsfx.text())
print(string.format("built dist/Granular.lua v%s (%d params)", Core.VERSION, #Core.PARAMS))
