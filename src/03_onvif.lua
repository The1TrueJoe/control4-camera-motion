-- ONVIF SOAP: build authenticated requests and parse motion events.
--
-- The NVR's legacy Hikvision/ISAPI alert stream is gone on this firmware (every
-- /ISAPI/Event/notification/* path returns 404), so motion comes from ONVIF events instead.
-- ONVIF PullPoint is request/response HTTP POST, which fits Control4's C4:url perfectly:
--   1. CreatePullPointSubscription -> a SubscriptionReference URL
--   2. PullMessages against that URL, repeatedly (long-poll)
--   3. each response carries tns1:VideoSource/MotionAlarm notifications per channel
-- Auth is WS-Security UsernameToken with a PasswordDigest = Base64(SHA1(nonce+created+pass)).

local WSSE = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd'
local WSU = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd'
local PWD_DIGEST = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest'
local B64_ENC = 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary'

-- WS-Security UsernameToken header for the current credentials.
local function SecurityHeader()
	local nonce = RandomNonce()
	local created = IsoNow()
	local digest = Sha1Base64(nonce .. created .. CONFIG.password)
	return table.concat({
		'<wsse:Security s:mustUnderstand="1" xmlns:wsse="', WSSE, '" xmlns:wsu="', WSU, '">',
		'<wsse:UsernameToken>',
		'<wsse:Username>', XmlEscape(CONFIG.username), '</wsse:Username>',
		'<wsse:Password Type="', PWD_DIGEST, '">', digest, '</wsse:Password>',
		'<wsse:Nonce EncodingType="', B64_ENC, '">', Base64(nonce), '</wsse:Nonce>',
		'<wsu:Created>', created, '</wsu:Created>',
		'</wsse:UsernameToken></wsse:Security>',
	})
end

-- Wrap a SOAP body with an authenticated envelope. Pass authed=false for calls that need none
-- (GetSystemDateAndTime), which also lets Test Connection work before credentials are set.
function OnvifEnvelope(body, authed)
	local header = ''
	if authed ~= false then
		header = '<s:Header>' .. SecurityHeader() .. '</s:Header>'
	end
	return '<?xml version="1.0" encoding="UTF-8"?>' ..
		'<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">' ..
		header .. '<s:Body>' .. body .. '</s:Body></s:Envelope>'
end

function OnvifDeviceUrl()
	return 'http://' .. CONFIG.address .. ':' .. CONFIG.port .. ONVIF_DEVICE_PATH
end

function OnvifEventsUrl()
	return 'http://' .. CONFIG.address .. ':' .. CONFIG.port .. ONVIF_EVENTS_PATH
end

-- Request bodies ---------------------------------------------------------------------------

function BodyGetSystemDateAndTime()
	return '<tds:GetSystemDateAndTime xmlns:tds="http://www.onvif.org/ver10/device/wsdl"/>'
end

function BodyCreatePullPoint()
	-- Ask for a generous termination; PullMessages keeps renewing it as we poll.
	return '<tev:CreatePullPointSubscription xmlns:tev="http://www.onvif.org/ver10/events/wsdl">' ..
		'<tev:InitialTerminationTime>PT3600S</tev:InitialTerminationTime>' ..
		'</tev:CreatePullPointSubscription>'
end

function BodyPullMessages(timeout_s, limit)
	return '<tev:PullMessages xmlns:tev="http://www.onvif.org/ver10/events/wsdl">' ..
		'<tev:Timeout>PT' .. tostring(timeout_s) .. 'S</tev:Timeout>' ..
		'<tev:MessageLimit>' .. tostring(limit or 50) .. '</tev:MessageLimit>' ..
		'</tev:PullMessages>'
end

function BodyUnsubscribe()
	return '<wsnt:Unsubscribe xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2"/>'
end

-- Parsing ----------------------------------------------------------------------------------

-- The SubscriptionReference address from a CreatePullPointSubscription response.
function ParseSubscriptionAddress(xml)
	if not xml then return nil end
	-- First <...Address>http...</...Address> inside the reference. Tolerate any prefix.
	local addr = xml:match('[Aa]ddress>%s*(ht[tp]-s?://[^<]-)%s*</')
	return addr and Trim(addr) or nil
end

-- Pull SimpleItem Name/Value pairs out of one notification message.
local function SimpleItems(msg)
	local items = {}
	for name, value in msg:gmatch('SimpleItem%s+Name="([^"]+)"%s+Value="([^"]*)"') do
		items[name] = value
	end
	return items
end

-- Channel number embedded in a token like "VideoSourceToken008" -> 8.
local function TokenChannel(token)
	if not token then return nil end
	local digits = token:match('(%d+)%s*$')
	return digits and tonumber(digits) or nil
end

-- Parse a PullMessagesResponse into a list of { channel = N, motion = bool }.
-- Recognizes both topics this NVR emits:
--   tns1:VideoSource/MotionAlarm            Source=VideoSourceToken00N  State=true|false
--   tns1:RuleEngine/CellMotionDetector/Motion  ...ConfigurationToken00N IsMotion=true|false
function ParseMotionEvents(xml)
	local events = {}
	if not xml then return events end
	for msg in xml:gmatch('<[%w]-:?NotificationMessage.->(.-)</[%w]-:?NotificationMessage>') do
		local topic = msg:match('[Tt]opic[^>]*>%s*([^<]-)%s*<') or ''
		local items = SimpleItems(msg)
		local channel, motion
		if topic:find('MotionAlarm') then
			channel = TokenChannel(items['Source'])
			motion = (items['State'] == 'true')
		elseif topic:find('CellMotionDetector') or topic:find('/Motion') then
			channel = TokenChannel(items['VideoSourceConfigurationToken'] or items['Source'])
			motion = (items['IsMotion'] == 'true')
		end
		if channel then
			events[#events + 1] = { channel = channel, motion = motion }
		end
	end
	return events
end

-- A SOAP fault's reason text, if the body is a fault.
function ParseSoapFault(xml)
	if not xml then return nil end
	if not xml:find('[Ff]ault') then return nil end
	local reason = xml:match('[Tt]ext[^>]*>%s*([^<]-)%s*</') or 'SOAP Fault'
	return Trim(reason)
end
