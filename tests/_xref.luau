local Config = require("../src/shared/Config")
local bad = {}
local function chk(ok, msg)
	if not ok then
		table.insert(bad, msg)
	end
end
for id, f in pairs(Config.Foods) do
	if f.Inputs then
		for inp in pairs(f.Inputs) do
			chk(Config.Foods[inp], "food " .. id .. " input " .. inp)
		end
	end
end
for id, s in pairs(Config.Species) do
	for food, pref in pairs(s.Preferences) do
		chk(Config.Foods[food], "species " .. id .. " pref " .. food)
	end
	if s.Visitor then
		for food, pref in pairs(s.Preferences) do
			local f = Config.Foods[food]
			if f and pref == "favorite" then
				chk(
					(f.Habitat or "meadow") == s.Habitat or f.Kind == "core",
					"fav habitat " .. id .. " " .. food .. " " .. tostring(f.Habitat)
				)
			end
		end
	end
end
for id, d in pairs(Config.Decorations) do
	local s = Config.Species[d.Favored]
	chk(s, "deco " .. id .. " favored " .. d.Favored)
	if s then
		chk(s.Habitat == d.Habitat, "deco habitat " .. id)
	end
end
for id, r in pairs(Config.Recipes) do
	for inp in pairs(r.Inputs) do
		chk(Config.Foods[inp], "recipe " .. id .. " input " .. inp)
	end
end
for id, q in pairs(Config.Quests) do
	if q.Reward.Decoration then
		chk(Config.Decorations[q.Reward.Decoration], "quest deco " .. id)
	end
end
print(#bad .. " problems")
for _, b in ipairs(bad) do
	print(b)
end
