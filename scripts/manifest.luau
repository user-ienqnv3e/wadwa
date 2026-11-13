--!nocheck
-- Writes docs/CONTENT_MANIFEST.md. Usage: lune run scripts/manifest.luau
local fs = require("@lune/fs")
local Config = require("../src/shared/Config")
local Manifest = require("./manifest-lib")
fs.writeFile("docs/CONTENT_MANIFEST.md", Manifest.render(Config))
print("Wrote docs/CONTENT_MANIFEST.md")
