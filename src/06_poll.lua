-- The ONVIF monitor loop: subscribe, then long-poll PullMessages forever.
--
-- Each step is a single C4:url POST with an async callback, so nothing blocks Director and no
-- socket is held open between requests. On any failure we drop the subscription and re-create it
-- after a backoff. Continuously pulling also keeps the subscription's termination time renewed.

local MIN_BACKOFF = 2000
local MAX_BACKOFF = 30000

local function ScheduleReconnect(why)
	if not ONVIF.running then return end
	ONVIF.sub_addr = nil
	UpdateDriverProperty('Connection Status', 'Reconnecting: ' .. tostring(why))
	LogDebug('reconnect in %d ms (%s)', ONVIF.backoff_ms, tostring(why))
	ONVIF.pull_timer = CancelTimer(ONVIF.pull_timer)
	ONVIF.pull_timer = SetTimer(ONVIF.backoff_ms, function()
		OnvifSubscribe()
	end)
	ONVIF.backoff_ms = math.min(ONVIF.backoff_ms * 2, MAX_BACKOFF)
end

-- One PullMessages request against the current subscription.
local function OnvifPull()
	if not ONVIF.running or not ONVIF.sub_addr then return end
	local envelope = OnvifEnvelope(BodyPullMessages(CONFIG.pull_timeout, 50))
	SoapPost(ONVIF.sub_addr, envelope, function(code, body, err)
		if not ONVIF.running then return end
		if err then
			ScheduleReconnect('pull ' .. err)
			return
		end
		if code ~= 200 then
			local fault = ParseSoapFault(body)
			ScheduleReconnect('pull HTTP ' .. tostring(code) .. (fault and (' / ' .. fault) or ''))
			return
		end
		-- Success: reset backoff, apply any motion, keep status fresh, poll again at once.
		ONVIF.backoff_ms = MIN_BACKOFF
		UpdateDriverProperty('Connection Status', 'Monitoring motion')
		local events = ParseMotionEvents(body)
		if #events > 0 then
			LogDebug('pull: %d motion event(s)', #events)
			ApplyMotionEvents(events)
		end
		OnvifPull()
	end)
end

-- Create a PullPoint subscription, then start pulling.
function OnvifSubscribe()
	if not ONVIF.running then return end
	if CONFIG.address == '' then
		UpdateDriverProperty('Connection Status', 'No DVR address set')
		return
	end
	UpdateDriverProperty('Connection Status', 'Subscribing...')
	local envelope = OnvifEnvelope(BodyCreatePullPoint())
	SoapPost(OnvifEventsUrl(), envelope, function(code, body, err)
		if not ONVIF.running then return end
		if err then
			ScheduleReconnect('subscribe ' .. err)
			return
		end
		if code ~= 200 then
			local fault = ParseSoapFault(body)
			ScheduleReconnect('subscribe HTTP ' .. tostring(code) .. (fault and (' / ' .. fault) or ''))
			return
		end
		local addr = ParseSubscriptionAddress(body)
		if not addr then
			ScheduleReconnect('subscribe: no SubscriptionReference')
			return
		end
		ONVIF.sub_addr = addr
		ONVIF.backoff_ms = MIN_BACKOFF
		LogInfo('ONVIF subscription at %s', addr)
		UpdateDriverProperty('Connection Status', 'Monitoring motion')
		OnvifPull()
	end)
end

function StartMonitor()
	StopMonitor()
	ONVIF.running = true
	ONVIF.backoff_ms = MIN_BACKOFF
	OnvifSubscribe()
end

function StopMonitor()
	ONVIF.running = false
	ONVIF.pull_timer = CancelTimer(ONVIF.pull_timer)
	-- Best-effort Unsubscribe so the NVR frees the subscription promptly.
	if ONVIF.sub_addr then
		local addr = ONVIF.sub_addr
		ONVIF.sub_addr = nil
		pcall(function()
			SoapPost(addr, OnvifEnvelope(BodyUnsubscribe()), function() end)
		end)
	end
end
