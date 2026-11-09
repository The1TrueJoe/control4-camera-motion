-- One SOAP POST through Director's own HTTP client (C4:url).
--
-- callback(code, body, err): code is the HTTP status (number) or nil on transport error;
-- body is the response text; err is a message on failure.

function SoapPost(url, envelope, callback)
	local transfer = C4:url()
	transfer:SetOptions({
		fail_on_error = false,
		timeout = (CONFIG.pull_timeout or 4) + 10, -- must outlast the ONVIF long-poll window
		connect_timeout = 10,
	})
	transfer:OnDone(Tracked(function(_, responses, errCode, errMsg)
		if errCode ~= 0 then
			callback(nil, nil, errMsg or ('transfer error ' .. tostring(errCode)))
			return
		end
		local resp = responses and responses[#responses] or {}
		callback(resp.code, resp.body or '', nil)
	end, 'SoapPost'))
	transfer:Post(url, envelope, {
		['Content-Type'] = 'application/soap+xml; charset=utf-8',
	})
end
