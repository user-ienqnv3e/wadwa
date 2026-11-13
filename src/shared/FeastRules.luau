--!strict
-- Pure rules for the cooperative Grand Feast: appetite scaling and fair reward splitting.
-- Rewards are computed once per event from a contribution table keyed by UserId, so a player
-- can never be paid twice for the same feast and nobody earns from someone else's throws.

local FeastRules = {}

export type Reward = { coins: number, research: number, points: number }

function FeastRules.goalFor(feastConfig: any, playersPresent: number): number
	local players = math.max(1, math.floor(playersPresent))
	return math.min(feastConfig.MaxGoal, feastConfig.BaseGoal + feastConfig.GoalPerExtraPlayer * (players - 1))
end

-- Contribution points for one food item fed to the giant.
function FeastRules.pointsFor(foodValue: number): number
	return math.max(1, math.floor(foodValue + 0.5))
end

-- contributions: { [userId]: points }. Only players with > 0 points are rewarded.
-- Everyone who reaches the participation minimum gets the same participation reward; the shared
-- pool is split by contribution but capped so one player cannot take most of it.
function FeastRules.computeRewards(feastConfig: any, contributions: { [number]: number }, success: boolean): { [number]: Reward }
	local rewards: { [number]: Reward } = {}
	local contributors = 0
	local total = 0
	for _, points in pairs(contributions) do
		if points > 0 then
			contributors += 1
			total += points
		end
	end
	if contributors == 0 then
		return rewards
	end

	local pool = feastConfig.SharePoolPerPlayer * contributors
	local equalShare = pool / contributors
	local shareCap = equalShare * feastConfig.MaxShareMultipleOfAverage
	local fraction = if success then 1 else feastConfig.FailureRewardFraction

	for userId, points in pairs(contributions) do
		if points > 0 then
			local participation = feastConfig.ParticipationCoins * math.min(1, points / feastConfig.ParticipationMinimum)
			local share = math.min(shareCap, pool * points / total)
			local coins = math.floor((participation + share) * fraction)
			local research = 0
			if success and points >= feastConfig.ParticipationMinimum then
				research = feastConfig.ParticipationResearch
			elseif success then
				research = 1
			end
			rewards[userId] = { coins = coins, research = research, points = points }
		end
	end
	return rewards
end

return FeastRules
