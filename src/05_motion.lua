-- Per-channel motion state and the contact-sensor proxy protocol.
--
-- Control4 models a motion sensor as a contact: OPEN = motion, CLOSED = no motion. The
-- contactsingle proxy exposes a ContactState variable (read by the Homebridge plugin) and the
-- stock "senses motion" / "stops sensing motion" events. We drive it with four notifications
-- (verified against Snap One's KNX and Lutron LEAP motion drivers and the Proxy/Protocol guide):
--   OPENED / CLOSED             set state AND fire the motion events
--   STATE_OPENED / STATE_CLOSED set state only (initial sync, answering GET_STATE)
-- all sent as NOTIFY with an empty parameter table.

local function Binding(channel)
	return PROXY_BINDING_BASE + channel
end

local function ChannelState(channel)
	local st = CHANNELS[channel]
	if not st then
		st = { open = false, known = false, close_timer = nil }
		CHANNELS[channel] = st
	end
	return st
end

function ChannelActive(channel)
	return channel >= 1 and channel <= CONFIG.channels and channel <= MAX_CHANNELS
end

function ChannelName(channel)
	return CONFIG.names[channel] or ('Camera ' .. channel)
end

local function Notify(channel, command)
	C4:SendToProxy(Binding(channel), command, {}, 'NOTIFY')
end

-- Push the current state to the proxy without firing events (used on bind / GET_STATE).
function SendCurrentState(channel)
	if not ChannelActive(channel) then return end
	local st = ChannelState(channel)
	if not st.known then return end
	Notify(channel, st.open and 'STATE_OPENED' or 'STATE_CLOSED')
end

-- Answer the proxy's GET_STATE. If we have never had a reading, send the safe default (closed).
function ReportState(channel)
	if not ChannelActive(channel) then return end
	local st = ChannelState(channel)
	Notify(channel, st.open and 'STATE_OPENED' or 'STATE_CLOSED')
	st.known = true
end

local function SetOpen(channel, open)
	local st = ChannelState(channel)
	if st.open == open and st.known then return end
	st.open = open
	st.known = true
	Notify(channel, open and 'OPENED' or 'CLOSED')
	LogInfo('%s (ch %d): %s', ChannelName(channel), channel, open and 'motion' or 'clear')
	UpdateDriverProperty('Last Event',
		string.format('%s %s @ %s', ChannelName(channel), open and 'motion' or 'clear', IsoNow()))
end

-- A motion event arrived from the NVR for a channel.
--   motion=true  -> open immediately, cancel any pending close.
--   motion=false -> schedule CLOSED after the Motion Hold window (debounce), unless motion
--                   returns first. hold=0 closes at once.
function ApplyMotion(channel, motion)
	if not ChannelActive(channel) then
		LogDebug('ignoring motion for inactive channel %d', channel)
		return
	end
	local st = ChannelState(channel)
	if motion then
		st.close_timer = CancelTimer(st.close_timer)
		SetOpen(channel, true)
	else
		st.close_timer = CancelTimer(st.close_timer)
		if CONFIG.hold_ms <= 0 then
			SetOpen(channel, false)
		else
			st.close_timer = SetTimer(CONFIG.hold_ms, function()
				st.close_timer = nil
				SetOpen(channel, false)
			end)
		end
	end
end

-- Apply a batch of parsed events (order preserved).
function ApplyMotionEvents(events)
	for _, e in ipairs(events) do
		ApplyMotion(e.channel, e.motion)
	end
end

-- Initialise every active channel to closed so Composer and the plugin see a defined state.
function InitChannels()
	for channel = 1, math.min(CONFIG.channels, MAX_CHANNELS) do
		local st = ChannelState(channel)
		st.close_timer = CancelTimer(st.close_timer)
		st.open = false
		st.known = true
		Notify(channel, 'STATE_CLOSED')
	end
end
