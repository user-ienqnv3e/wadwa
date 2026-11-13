--!strict
-- Versioned, session-locked profile persistence.
--
-- * Loads use UpdateAsync inside pcall with bounded retries and take a session lock so two
--   servers never write the same profile at once.
-- * If a load fails (or another server still holds the lock, or the save is from a newer
--   schema) the session runs in "Unsaved" mode: the player can still play, is told clearly, and
--   this server will NEVER write over their stored data.
-- * Autosave runs on an interval; PlayerRemoving and BindToClose do a final save + lock release.
-- * In Roblox Studio without API access, an explicitly-marked in-memory store is used instead
--   ("StudioMemory" mode). Live servers never silently fall back to memory.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local SaveSchema = require(Shared:WaitForChild("SaveSchema"))

export type Mode = "DataStore" | "StudioMemory" | "Unsaved"

export type Session = {
	player: Player,
	key: string,
	profile: SaveSchema.Profile,
	mode: Mode,
	modeReason: string?,
	saving: boolean,
	released: boolean,
	lastSaved: number,
}

local DataService = {}

local sessions: { [Player]: Session } = {}
local loadedCallbacks: { (Player, Session) -> () } = {}
local releasingCallbacks: { (Player, Session) -> () } = {}
local store: DataStore? = nil
local storeMode: "DataStore" | "StudioMemory" = "DataStore"
local memoryStore: { [string]: any } = {} -- Studio-only fallback, lives as long as this server
local jobId = if game.JobId ~= "" then game.JobId else "studio-" .. tostring(math.random(1, 1e9))
local shuttingDown = false

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

local function keyFor(player: Player): string
	return Config.Data.KeyPrefix .. tostring(player.UserId)
end

local function backoff(attempt: number)
	task.wait(Config.Data.RetryBaseDelay * 2 ^ (attempt - 1))
end

local function initStore()
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(Config.Data.StoreName)
	end)
	if ok then
		store = result
	end
	if RunService:IsStudio() then
		-- Probe once: Studio without "Enable Studio Access to API Services" errors here.
		local probeOk = ok and pcall(function()
			(store :: DataStore):GetAsync("__studio_probe")
		end)
		if not probeOk then
			storeMode = "StudioMemory"
			store = nil
			warn("[WildFeast] Studio API access unavailable: using IN-MEMORY profiles. Progress will NOT persist.")
		end
	end
end

-- Returns (record, nil) on success or (nil, reason).
local function loadRecord(key: string): (any, string?)
	if storeMode == "StudioMemory" then
		return deepCopy(memoryStore[key]) or {}, nil
	end
	local dataStore = store
	if not dataStore then
		return nil, "store_unavailable"
	end
	local lastReason = "unknown"
	for attempt = 1, Config.Data.LoadRetries do
		local held = false
		local loaded: any = nil
		local ok, err = pcall(function()
			dataStore:UpdateAsync(key, function(record: any)
				local lockState = SaveSchema.evaluateLock(record, jobId, os.time(), Config.Data.SessionLockTimeout)
				if lockState == "held" then
					held = true
					return nil -- cancel the write, keep their data untouched
				end
				local newRecord = if type(record) == "table" then record else {}
				newRecord.lock = { jobId = jobId, time = os.time() }
				loaded = newRecord
				return newRecord
			end)
		end)
		if ok and loaded ~= nil then
			return loaded, nil
		end
		lastReason = if held then "locked_elsewhere" else tostring(err)
		if attempt < Config.Data.LoadRetries then
			if held then
				task.wait(Config.Data.LockedRetryDelay)
			else
				backoff(attempt)
			end
		end
	end
	return nil, lastReason
end

local function writeRecord(session: Session, release: boolean): boolean
	if session.mode == "Unsaved" then
		return false
	end
	local snapshot = deepCopy(session.profile)
	if session.mode == "StudioMemory" then
		memoryStore[session.key] = { profile = snapshot, savedAt = os.time() }
		return true
	end
	local dataStore = store
	if not dataStore then
		return false
	end
	for attempt = 1, Config.Data.SaveRetries do
		local lostLock = false
		local ok, err = pcall(function()
			dataStore:UpdateAsync(session.key, function(record: any)
				local lockState = SaveSchema.evaluateLock(record, jobId, os.time(), Config.Data.SessionLockTimeout)
				if lockState ~= "ours" then
					-- Another server took over (or the record was removed); never overwrite it.
					lostLock = true
					return nil
				end
				local newRecord = record
				newRecord.profile = snapshot
				newRecord.savedAt = os.time()
				newRecord.lock = if release then nil else { jobId = jobId, time = os.time() }
				return newRecord
			end)
		end)
		if lostLock then
			warn("[WildFeast] Session lock lost for " .. session.key .. "; switching to unsaved mode.")
			session.mode = "Unsaved"
			session.modeReason = "lock_lost"
			return false
		end
		if ok then
			session.lastSaved = os.clock()
			return true
		end
		warn(string.format("[WildFeast] Save attempt %d failed for %s: %s", attempt, session.key, tostring(err)))
		if attempt < Config.Data.SaveRetries and not shuttingDown then
			backoff(attempt)
		end
	end
	return false
end

-- Saves a session, serialising concurrent saves for the same player.
function DataService.save(player: Player, release: boolean?): boolean
	local session = sessions[player]
	if not session or session.released then
		return false
	end
	while session.saving do
		task.wait(0.1)
	end
	if session.released then
		return false
	end
	session.saving = true
	local ok, result = pcall(writeRecord, session, release == true)
	session.saving = false
	if release then
		session.released = true
	end
	return ok and result == true
end

local function onPlayerAdded(player: Player)
	local key = keyFor(player)
	local record, reason = loadRecord(key)
	if not player:IsDescendantOf(Players) then
		-- Left while loading: release the lock we may have just taken without touching the profile.
		if record and storeMode == "DataStore" and store then
			pcall(function()
				(store :: DataStore):UpdateAsync(key, function(r: any)
					if SaveSchema.evaluateLock(r, jobId, os.time(), Config.Data.SessionLockTimeout) == "ours" then
						r.lock = nil
						return r
					end
					return nil
				end)
			end)
		end
		return
	end

	local mode: Mode = storeMode
	local profile: SaveSchema.Profile
	if record == nil then
		mode = "Unsaved"
		profile = SaveSchema.default(Config)
		warn("[WildFeast] Could not load profile for " .. key .. " (" .. tostring(reason) .. "); progress will not be saved this session.")
	else
		local migrated, migrateErr = SaveSchema.migrate(Config, record.profile or {})
		if migrated == nil then
			mode = "Unsaved"
			reason = migrateErr
			profile = SaveSchema.default(Config)
		else
			profile = SaveSchema.sanitize(Config, migrated)
		end
	end

	local session: Session = {
		player = player,
		key = key,
		profile = profile,
		mode = mode,
		modeReason = if mode == "Unsaved" then reason else nil,
		saving = false,
		released = false,
		lastSaved = os.clock(),
	}
	sessions[player] = session
	player:SetAttribute("PersistenceMode", mode)
	for _, callback in ipairs(loadedCallbacks) do
		task.spawn(callback, player, session)
	end
end

local function onPlayerRemoving(player: Player)
	local session = sessions[player]
	if not session then
		return
	end
	for _, callback in ipairs(releasingCallbacks) do
		pcall(callback, player, session)
	end
	DataService.save(player, true)
	sessions[player] = nil
end

function DataService.getSession(player: Player): Session?
	local session = sessions[player]
	if session and not session.released then
		return session
	end
	return nil
end

function DataService.getProfile(player: Player): SaveSchema.Profile?
	local session = DataService.getSession(player)
	return if session then session.profile else nil
end

function DataService.onLoaded(callback: (Player, Session) -> ())
	table.insert(loadedCallbacks, callback)
	for player, session in pairs(sessions) do
		task.spawn(callback, player, session)
	end
end

function DataService.onReleasing(callback: (Player, Session) -> ())
	table.insert(releasingCallbacks, callback)
end

function DataService.storeMode(): string
	return storeMode
end

function DataService.init()
	initStore()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end

	task.spawn(function()
		while not shuttingDown do
			task.wait(Config.Data.AutosaveInterval)
			for player in pairs(sessions) do
				task.spawn(DataService.save, player, false)
			end
		end
	end)

	game:BindToClose(function()
		shuttingDown = true
		local pending = 0
		for player in pairs(sessions) do
			pending += 1
			task.spawn(function()
				DataService.save(player, true)
				pending -= 1
			end)
		end
		local deadline = os.clock() + Config.Data.ShutdownBudget
		while pending > 0 and os.clock() < deadline do
			task.wait(0.2)
		end
	end)
end

return DataService
