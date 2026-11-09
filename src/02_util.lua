-- Small helpers: logging, timers, properties, crypto and string work.

function LogDebug(...)
	if CONFIG.debug then
		print(LOG_PREFIX .. string.format(...))
	end
end

function LogInfo(...)
	print(LOG_PREFIX .. string.format(...))
end

-- Wrap a callback so an error in it is logged, never thrown into Director.
function Tracked(fn, label)
	return function(...)
		local ok, err = pcall(fn, ...)
		if not ok then
			print(LOG_PREFIX .. (label or 'handler') .. ' error: ' .. tostring(err))
		end
	end
end

function SetTimer(ms, fn, repeating)
	return C4:SetTimer(ms, Tracked(fn, 'timer'), repeating or false)
end

function CancelTimer(timer)
	if timer then
		pcall(function() timer:Cancel() end)
	end
	return nil
end

function UpdateDriverProperty(name, value)
	value = tostring(value)
	if Properties and Properties[name] ~= value then
		pcall(function() C4:UpdateProperty(name, value) end)
	end
end

function Trim(s)
	return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Escape text for inclusion in an XML/SOAP element or attribute value.
function XmlEscape(s)
	s = tostring(s or '')
	s = s:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;')
	s = s:gsub('"', '&quot;'):gsub("'", '&apos;')
	return s
end

-- 16 random bytes, unique enough for a WS-Security nonce even across rapid calls.
function RandomNonce()
	ONVIF.nonce_counter = ONVIF.nonce_counter + 1
	local bytes = {}
	for i = 1, 16 do
		bytes[i] = string.char(math.random(0, 255))
	end
	-- Fold a counter in so two nonces in the same second never collide.
	local c = ONVIF.nonce_counter
	bytes[1] = string.char(c % 256)
	bytes[2] = string.char(math.floor(c / 256) % 256)
	return table.concat(bytes)
end

-- Base64 of SHA1(data). Works on a real controller (C4:Hash BASE64) and under the test
-- harness (C4:Hash returns the raw digest, which we then Base64Encode).
function Sha1Base64(data)
	local ok, hashed = pcall(function()
		return C4:Hash('SHA1', data, { ['return_encoding'] = 'BASE64' })
	end)
	if ok and type(hashed) == 'string' and #hashed >= 24 and not hashed:find('[^A-Za-z0-9+/=]') then
		return hashed -- Director already handed back Base64 text
	end
	return C4:Base64Encode(C4:Hash('SHA1', data))
end

function Base64(data)
	return C4:Base64Encode(data)
end

-- UTC timestamp in the form ONVIF wants, e.g. 2026-11-09T06:21:10Z.
function IsoNow()
	return os.date('!%Y-%m-%dT%H:%M:%SZ')
end
