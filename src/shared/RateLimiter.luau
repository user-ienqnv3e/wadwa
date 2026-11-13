--!strict
-- Token-bucket rate limiter keyed by an arbitrary value (normally a Player).
-- The clock is passed in so the limiter can be tested deterministically.

export type Bucket = { tokens: number, last: number }

local RateLimiter = {}
RateLimiter.__index = RateLimiter

export type RateLimiter = typeof(setmetatable({} :: { rate: number, burst: number, buckets: { [any]: Bucket } }, RateLimiter))

function RateLimiter.new(rate: number, burst: number): RateLimiter
	return setmetatable({ rate = rate, burst = burst, buckets = {} }, RateLimiter)
end

function RateLimiter.allow(self: RateLimiter, key: any, now: number, cost: number?): boolean
	local price = cost or 1
	local bucket = self.buckets[key]
	if bucket == nil then
		bucket = { tokens = self.burst, last = now }
		self.buckets[key] = bucket
	end
	local elapsed = math.max(0, now - bucket.last)
	bucket.tokens = math.min(self.burst, bucket.tokens + elapsed * self.rate)
	bucket.last = now
	if bucket.tokens >= price then
		bucket.tokens -= price
		return true
	end
	return false
end

function RateLimiter.remove(self: RateLimiter, key: any)
	self.buckets[key] = nil
end

return RateLimiter
