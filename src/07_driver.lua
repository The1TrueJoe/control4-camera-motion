-- Driver lifecycle: properties, proxy dispatch, bindings and actions.

-- Read the Properties table into CONFIG. Returns true if a monitor-affecting setting changed.
function ReadConfig()
	local function prop(name, default)
		local v = Properties and Properties[name]
		if v == nil or v == '' then return default end
		return v
	end

	local before = table.concat({
		CONFIG.address, CONFIG.port, CONFIG.username, CONFIG.password, CONFIG.channels, CONFIG.pull_timeout,
	}, '|')

	CONFIG.address = Trim(prop('DVR Address', ''))
	CONFIG.port = tonumber(prop('HTTP Port', 80)) or 80
	CONFIG.username = prop('Username', '')
	CONFIG.password = prop('Password', '')
	CONFIG.channels = math.min(tonumber(prop('Camera Channel Count', 8)) or 8, MAX_CHANNELS)
	CONFIG.hold_ms = (tonumber(prop('Motion Hold (seconds)', 5)) or 5) * 1000
	CONFIG.pull_timeout = tonumber(prop('Pull Timeout (seconds)', 4)) or 4
	CONFIG.debug = (prop('Debug Mode', 'Off') == 'On')

	CONFIG.names = {}
	for channel = 1, MAX_CHANNELS do
		local n = Trim(prop('Camera ' .. channel .. ' Name', ''))
		if n ~= '' then CONFIG.names[channel] = n end
	end

	local after = table.concat({
		CONFIG.address, CONFIG.port, CONFIG.username, CONFIG.password, CONFIG.channels, CONFIG.pull_timeout,
	}, '|')
	return before ~= after
end

function OnDriverInit()
	math.randomseed(os.time())
	ReadConfig()
	UpdateDriverProperty('Driver Version', DRIVER_VERSION)
	UpdateDriverProperty('Connection Status', 'Starting...')
end

function OnDriverLateInit()
	ReadConfig()
	UpdateDriverProperty('Driver Version', DRIVER_VERSION)
	-- SendToProxy / UpdateProperty are only safe once the driver is fully up.
	InitChannels()
	StartMonitor()
	LogInfo('started v%s: %s:%d, %d channel(s)', DRIVER_VERSION, CONFIG.address, CONFIG.port, CONFIG.channels)
end

function OnDriverDestroyed()
	StopMonitor()
end

function OnPropertyChanged(strProperty)
	local changed = ReadConfig()
	if strProperty == 'Debug Mode' then
		LogInfo('debug %s', CONFIG.debug and 'on' or 'off')
		return
	end
	if changed then
		LogInfo('settings changed (%s): restarting monitor', tostring(strProperty))
		InitChannels()
		StartMonitor()
	end
end

-- The contact proxy asks the driver for the current state when a consumer binds or Composer
-- refreshes. Answer per channel.
function ReceivedFromProxy(idBinding, strCommand, tParams)
	local channel = idBinding - PROXY_BINDING_BASE
	if strCommand == 'GET_STATE' then
		ReportState(channel)
	else
		LogDebug('proxy %d command %s (ignored)', idBinding, tostring(strCommand))
	end
end

-- When something binds to a channel's CONTACT_SENSOR connection, push the current state.
function OnBindingChanged(idBinding, strClass, bIsBound)
	if bIsBound and idBinding > PROXY_BINDING_BASE and idBinding <= PROXY_BINDING_BASE + MAX_CHANNELS then
		SendCurrentState(idBinding - PROXY_BINDING_BASE)
	end
end

-- Actions / commands -----------------------------------------------------------------------

local function DoTestConnection()
	UpdateDriverProperty('Connection Status', 'Testing...')
	-- Step 1: reachability (no auth needed for GetSystemDateAndTime).
	SoapPost(OnvifDeviceUrl(), OnvifEnvelope(BodyGetSystemDateAndTime(), false), function(code, body, err)
		if err or code ~= 200 or not (body or ''):find('SystemDateAndTime') then
			UpdateDriverProperty('Connection Status',
				'ONVIF unreachable: ' .. tostring(err or ('HTTP ' .. tostring(code))))
			return
		end
		-- Step 2: credentials + events, via an authenticated subscription we immediately drop.
		SoapPost(OnvifEventsUrl(), OnvifEnvelope(BodyCreatePullPoint()), function(code2, body2, err2)
			if err2 or code2 ~= 200 then
				local fault = ParseSoapFault(body2)
				UpdateDriverProperty('Connection Status',
					'Reachable, auth/events failed: ' .. tostring(fault or err2 or ('HTTP ' .. tostring(code2))))
				return
			end
			local addr = ParseSubscriptionAddress(body2)
			if addr then
				pcall(function() SoapPost(addr, OnvifEnvelope(BodyUnsubscribe()), function() end) end)
			end
			UpdateDriverProperty('Connection Status', 'OK: ONVIF events available')
			LogInfo('Test Connection OK')
		end)
	end)
end

function ExecuteCommand(strCommand, tParams)
	if strCommand == 'TEST_CONNECTION' then
		DoTestConnection()
	elseif strCommand == 'RESTART' then
		ReadConfig()
		InitChannels()
		StartMonitor()
	elseif strCommand == 'LUA_ACTION' and tParams then
		-- Composer "Lua Command" actions arrive wrapped; dispatch the inner command name.
		for k in pairs(tParams) do
			if k == 'TEST_CONNECTION' or k == 'RESTART' then
				ExecuteCommand(k, {})
			end
		end
	else
		LogDebug('ExecuteCommand %s (ignored)', tostring(strCommand))
	end
end
