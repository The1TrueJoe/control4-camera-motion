-- Globals, constants and shared state for the NVR Camera Motion driver.

DRIVER_VERSION = 'dev' -- stamped by build.sh

LOG_PREFIX = 'NVRMotion: '

-- Proxy binding ids are 5000 + channel (5001..5008); see driver.xml.
PROXY_BINDING_BASE = 5000
MAX_CHANNELS = 8 -- how many proxy bindings driver.xml declares

-- ONVIF service paths are part of the ONVIF standard, not device-specific; only the host,
-- port and credentials are configurable (driver properties).
ONVIF_DEVICE_PATH = '/onvif/device_service'
ONVIF_EVENTS_PATH = '/onvif/events_service'

-- Live config, refreshed from Properties in ReadConfig().
CONFIG = {
	address = '',
	port = 80,
	username = '',
	password = '',
	channels = 8,
	hold_ms = 5000,
	pull_timeout = 4, -- seconds, ONVIF PullMessages window
	names = {}, -- [channel] = "Front Door"
	debug = false,
}

-- Per-channel motion state.
--   open      : what the proxy currently shows (true = motion/open, false = no motion/closed)
--   known     : have we ever told the proxy a state (so GET_STATE can answer)
--   close_timer: pending CLOSED after the hold window
CHANNELS = {}

-- ONVIF subscription state.
ONVIF = {
	sub_addr = nil, -- SubscriptionReference address from CreatePullPointSubscription
	running = false, -- monitor loop should keep going
	nonce_counter = 0, -- mixed into WS-Security nonces for uniqueness
	backoff_ms = 2000, -- current reconnect backoff
	pull_timer = nil,
}
