--!strict
-- Efficient profile replication: the server sends one full snapshot, then sequenced deltas.
--
-- A delta lists, per top-level profile section, either a whole replacement (`set`) or a
-- second-level patch (`patch[section] = { set = {key = value}, del = {key, ...} }`). Second-level
-- values are always replaced whole, so nested deletions inside them (a discovery map, a plot table)
-- are carried by the replacement, and array sections are always replaced whole (see ARRAYS), so
-- RemoteEvent's "no nil holes" rule can never corrupt them. Deleted keys travel in `del` lists
-- because a nil value cannot cross a remote.
--
-- Pure Luau (no Roblox APIs): the server, the client and the offline tests share it.

local ProfileSync = {}

-- Sections that are arrays: always replaced whole.
local ARRAYS: { [string]: boolean } = { pinned = true }

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in pairs(a) do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end
ProfileSync.deepEqual = deepEqual

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in pairs(value) do
		copy[k] = deepCopy(v)
	end
	return copy
end
ProfileSync.deepCopy = deepCopy

export type Delta = {
	set: { [string]: any }?,
	patch: { [string]: { set: { [string]: any }?, del: { string }? } }?,
}

-- Returns a delta turning `old` into `new`, or nil when nothing changed.
function ProfileSync.diff(old: { [string]: any }, new: { [string]: any }): Delta?
	local set: { [string]: any } = {}
	local patch: { [string]: any } = {}
	local any = false
	for key, value in pairs(new) do
		local before = old[key]
		if not deepEqual(before, value) then
			any = true
			if type(value) ~= "table" or type(before) ~= "table" or ARRAYS[key] then
				set[key] = deepCopy(value)
			else
				local subSet: { [string]: any } = {}
				local del: { string } = {}
				local changed = 0
				for subKey, subValue in pairs(value) do
					if not deepEqual(before[subKey], subValue) then
						subSet[subKey] = deepCopy(subValue)
						changed += 1
					end
				end
				for subKey in pairs(before) do
					if value[subKey] == nil then
						table.insert(del, subKey)
					end
				end
				table.sort(del)
				patch[key] = { set = if changed > 0 then subSet else nil, del = if #del > 0 then del else nil }
			end
		end
	end
	if not any then
		return nil
	end
	return { set = if next(set) then set else nil, patch = if next(patch) then patch else nil }
end

-- Applies a delta to `profile` in place (client side). Malformed parts are ignored.
function ProfileSync.apply(profile: { [string]: any }, delta: any)
	if type(delta) ~= "table" then
		return
	end
	if type(delta.set) == "table" then
		for key, value in pairs(delta.set) do
			if type(key) == "string" then
				profile[key] = value
			end
		end
	end
	if type(delta.patch) == "table" then
		for key, change in pairs(delta.patch) do
			if type(key) == "string" and type(change) == "table" then
				local section = profile[key]
				if type(section) ~= "table" then
					section = {}
					profile[key] = section
				end
				if type(change.set) == "table" then
					for subKey, subValue in pairs(change.set) do
						section[subKey] = subValue
					end
				end
				if type(change.del) == "table" then
					for _, subKey in ipairs(change.del) do
						section[subKey] = nil
					end
				end
			end
		end
	end
end

return ProfileSync
