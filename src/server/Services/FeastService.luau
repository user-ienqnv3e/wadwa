--!strict
-- Repeatable cooperative Grand Feast.
--
--   Waiting --(cooldown)--> Ready --(bell or auto timer)--> Arriving --> Active --> Leaving --> Waiting
--
-- The giant's appetite scales with the number of players present when it starts, so one player
-- can finish it alone. Contributions are tracked per UserId from the server's own projectile
-- hits, and rewards are paid exactly once per event to players still in the server.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Guard = require(ReplicatedStorage.Shared.Guard)
local Economy = require(ReplicatedStorage.Shared.Economy)
local FeastRules = require(ReplicatedStorage.Shared.FeastRules)
local AnimalFactory = require(script.Parent.Parent.World.AnimalFactory)

local FeastRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Feast") :: RemoteEvent

type Deps = {
	getProfile: (Player) -> any,
	markDirty: (Player) -> (),
	notify: (Player, string, string?) -> (),
	notifyAll: (string, string?) -> (),
}

local FeastService = {}

local deps: Deps
local feastConfig = Config.Feast
local state = "Waiting"
local stateEnds = 0 -- os.clock() deadline for the current state
local eventId = 0
local goal = 0
local progress = 0
local contributions: { [number]: number } = {}
local paidEvents: { [number]: { [number]: boolean } } = {}
local giant: AnimalFactory.Built
local bell: BasePart?
local statusLabel: TextLabel?
local giantPhase = 0
local dirty = true
local lastBroadcast = 0

local HIDDEN_Y = -40
local ACTIVE_Y = 7

local function serverDeadline(): number
	return workspace:GetServerTimeNow() + math.max(0, stateEnds - os.clock())
end

local function setState(newState: string, duration: number)
	state = newState
	stateEnds = os.clock() + duration
	dirty = true
end

local function broadcast()
	dirty = false
	lastBroadcast = os.clock()
	local payload = {
		state = state,
		eventId = eventId,
		goal = goal,
		progress = progress,
		deadline = serverDeadline(),
		contributors = 0,
	}
	for _, points in pairs(contributions) do
		if points > 0 then
			payload.contributors += 1
		end
	end
	for _, player in ipairs(Players:GetPlayers()) do
		local personal = table.clone(payload)
		personal.yourPoints = contributions[player.UserId] or 0
		FeastRemote:FireClient(player, personal)
	end
	if statusLabel then
		local remaining = math.max(0, math.ceil(stateEnds - os.clock()))
		if state == "Waiting" then
			statusLabel.Text = string.format("Next feast in %ds", remaining)
		elseif state == "Ready" then
			statusLabel.Text = "Feast ready!\nRing the bell"
		elseif state == "Active" then
			statusLabel.Text = string.format("Feed me! %d / %d", progress, goal)
		elseif state == "Arriving" then
			statusLabel.Text = feastConfig.GiantName .. " is coming!"
		else
			statusLabel.Text = "Thank you, friends!"
		end
	end
end

local function playersPresent(except: Player?): number
	local n = 0
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= except and deps.getProfile(player) then
			n += 1
		end
	end
	return math.min(n, Config.Caps.FeastParticipants)
end

function FeastService.start(byPlayer: Player?): boolean
	if state ~= "Ready" then
		return false
	end
	eventId += 1
	goal = FeastRules.goalFor(feastConfig, playersPresent())
	progress = 0
	contributions = {}
	setState("Arriving", feastConfig.ArriveSeconds)
	local who = if byPlayer then byPlayer.DisplayName .. " rang the bell! " else ""
	deps.notifyAll(who .. "The " .. feastConfig.GiantName .. " is surfacing at Feast Cove!", "success")
	return true
end

local function finish(success: boolean)
	if state ~= "Active" then
		return
	end
	local finishedId = eventId
	local paid = paidEvents[finishedId] or {}
	paidEvents[finishedId] = paid
	paidEvents[finishedId - 3] = nil -- bounded history
	local rewards = FeastRules.computeRewards(feastConfig, contributions, success)
	for userId, reward in pairs(rewards) do
		if not paid[userId] then
			local player = Players:GetPlayerByUserId(userId)
			local profile = player and deps.getProfile(player)
			if player and profile then
				paid[userId] = true
				reward.coins = math.floor(reward.coins * (1 + Economy.modifier(Config, profile, "feastCoins") / 100) + 0.5)
				Economy.addCoins(Config, profile, reward.coins)
				Economy.addResearch(Config, profile, reward.research)
				profile.stats.feastsJoined = math.min(profile.stats.feastsJoined + 1, Config.Caps.Counter)
				if success then
					profile.stats.feastsCompleted = math.min(profile.stats.feastsCompleted + 1, Config.Caps.Counter)
				end
				deps.markDirty(player)
				local text = string.format(
					"%s Feast reward: +%d coins%s (you fed %d)",
					if success then "★" else "•",
					reward.coins,
					if reward.research > 0 then string.format(", +%d research", reward.research) else "",
					reward.points
				)
				deps.notify(player, text, "success")
			end
		end
	end
	if success then
		deps.notifyAll("The " .. feastConfig.GiantName .. " is full and happy! Thank you, islanders!", "success")
	else
		deps.notifyAll("The " .. feastConfig.GiantName .. " swims off, still a little peckish. Rewards shared anyway!", "info")
	end
	contributions = {}
	setState("Leaving", feastConfig.LeaveSeconds)
end

-- Called by the feeding service when a projectile reaches the giant's mouth.
function FeastService.contribute(player: Player, foodId: string): boolean
	if state ~= "Active" then
		return false
	end
	local food = Config.Foods[foodId]
	if not food then
		return false
	end
	local points = math.min(FeastRules.pointsFor(food.Value), Config.Feast.MaxPointsPerItem)
	local profile = deps.getProfile(player)
	if profile then
		points = math.floor(points * (1 + Economy.modifier(Config, profile, "feastPoints") / 100) + 0.5)
	end
	contributions[player.UserId] = (contributions[player.UserId] or 0) + points
	progress += points
	dirty = true
	if progress >= goal then
		finish(true)
	end
	return true
end

function FeastService.mouthPosition(): Vector3?
	if state ~= "Active" then
		return nil
	end
	return giant.root.CFrame * giant.mouthOffset
end

function FeastService.state(): string
	return state
end

function FeastService.bellPosition(): Vector3?
	return if bell then bell.Position else nil
end

function FeastService.ringFromPlayer(player: Player): boolean
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local bellPos = FeastService.bellPosition()
	if not hrp or not bellPos or (hrp.Position - bellPos).Magnitude > feastConfig.BellRange + 6 then
		deps.notify(player, "Walk to the bell on the Feast Cove pier to ring it.", "info")
		return false
	end
	if state ~= "Ready" then
		deps.notify(player, "The bell isn't ready yet.", "info")
		return false
	end
	return FeastService.start(player)
end

local function giantFrame(y: number): CFrame
	local center = feastConfig.Center
	-- Face +Z (toward the pier).
	return CFrame.new(center[1], y, center[2]) * CFrame.Angles(0, math.pi, 0)
end

local function update(dt: number)
	local now = os.clock()
	giantPhase += dt
	if state == "Waiting" and now >= stateEnds then
		setState("Ready", feastConfig.AutoStartAfterReady)
		deps.notifyAll("A Grand Feast is ready at Feast Cove. Ring the bell on the pier!", "info")
	elseif state == "Ready" and now >= stateEnds then
		if #Players:GetPlayers() > 0 then
			FeastService.start(nil)
		else
			setState("Ready", feastConfig.AutoStartAfterReady)
		end
	elseif state == "Arriving" and now >= stateEnds then
		setState("Active", feastConfig.Duration)
	elseif state == "Active" and now >= stateEnds then
		finish(false)
	elseif state == "Leaving" and now >= stateEnds then
		setState("Waiting", feastConfig.ReadyCooldown)
	end

	local y = HIDDEN_Y
	if state == "Arriving" then
		local alpha = 1 - math.clamp((stateEnds - now) / feastConfig.ArriveSeconds, 0, 1)
		y = HIDDEN_Y + (ACTIVE_Y - HIDDEN_Y) * (1 - (1 - alpha) ^ 3)
	elseif state == "Active" then
		y = ACTIVE_Y + math.sin(giantPhase * 1.5) * 0.8
	elseif state == "Leaving" then
		local alpha = 1 - math.clamp((stateEnds - now) / feastConfig.LeaveSeconds, 0, 1)
		y = ACTIVE_Y + (HIDDEN_Y - ACTIVE_Y) * alpha ^ 2
	end
	local roll = if state == "Leaving" then math.sin(giantPhase * 6) * 0.05 else 0
	giant.root.CFrame = giantFrame(y) * CFrame.Angles(0, 0, roll)
	local emote = if state == "Active" then string.format("%d / %d", progress, goal) elseif state == "Leaving" then "♥ ♥ ♥" else ""
	if giant.emote.Text ~= emote then
		giant.emote.Text = emote
	end

	if dirty and now - lastBroadcast > 0.25 or now - lastBroadcast > 1 then
		broadcast()
	end
end

function FeastService.init(dependencies: Deps, world: Instance)
	deps = dependencies
	local existing = workspace:FindFirstChild("WildFeastGiant")
	if existing then
		existing:Destroy()
	end
	giant = AnimalFactory.buildGiant(feastConfig.GiantName)
	giant.model.Name = "WildFeastGiant"
	giant.root.CFrame = giantFrame(HIDDEN_Y)
	giant.model.Parent = workspace

	local cove = world:FindFirstChild("FeastCove")
	if cove then
		bell = cove:FindFirstChild("FeastBell") :: BasePart?
		local post = cove:FindFirstChild("BellPost")
		local labelGui = post and post:FindFirstChild("StatusLabel")
		statusLabel = labelGui and labelGui:FindFirstChild("Text") :: TextLabel?
		local prompt = bell and bell:FindFirstChild("RingPrompt") :: ProximityPrompt?
		if prompt then
			prompt.Triggered:Connect(function(player)
				FeastService.ringFromPlayer(player)
			end)
		end
	end

	Players.PlayerAdded:Connect(function()
		dirty = true
	end)
	-- The appetite only ever shrinks mid-event: when players leave, whoever stays can still finish
	-- (joiners help for free and never make it harder).
	Players.PlayerRemoving:Connect(function(leaving)
		Guard.run("Feast rescale", function()
			if state ~= "Active" and state ~= "Arriving" then
				return
			end
			local rescaled = FeastRules.goalFor(feastConfig, playersPresent(leaving))
			if rescaled < goal then
				goal = math.max(rescaled, 1)
				dirty = true
				if state == "Active" and progress >= goal then
					finish(true)
				end
			end
		end)
	end)
	setState("Waiting", feastConfig.FirstDelay)
	RunService.Heartbeat:Connect(function(dt)
		Guard.run("Feast update", update, dt)
	end)
end

return FeastService
