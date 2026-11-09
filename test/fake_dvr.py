"""A fake ONVIF NVR for the camera-motion driver's tests.

Implements only the SOAP calls the driver makes, routed through c4mock's `web(method, url,
headers, body)` hook. It does not validate the WS-Security digest (the driver's auth header is
exercised on a real controller); it checks the request shapes and lets a test feed per-channel
motion events that the next PullMessages returns.

  GET  system date/time   -> reachability probe (no auth)
  CreatePullPointSubscription -> a SubscriptionReference URL
  PullMessages            -> queued motion NotificationMessages, then clears the queue
  Unsubscribe             -> empty 200
"""

from urllib.parse import urlsplit

SUB_PATH = "/onvif/subscription/1"


def _motion_message(channel, motion):
    tok = "VideoSourceToken%03d" % channel
    state = "true" if motion else "false"
    return (
        "<wsnt:NotificationMessage>"
        '<wsnt:Topic Dialect="http://www.onvif.org/ver10/tev/topicExpression/ConcreteSet">'
        "tns1:VideoSource/MotionAlarm</wsnt:Topic>"
        "<wsnt:Message>"
        '<tt:Message UtcTime="2026-11-09T06:22:20Z" PropertyOperation="Changed">'
        "<tt:Source>"
        '<tt:SimpleItem Name="Source" Value="%s"/>'
        "</tt:Source>"
        "<tt:Data>"
        '<tt:SimpleItem Name="State" Value="%s"/>'
        "</tt:Data>"
        "</tt:Message>"
        "</wsnt:Message>"
        "</wsnt:NotificationMessage>"
    ) % (tok, state)


class FakeDvr:
    def __init__(self, host="192.0.2.50", port=80):
        self.host = host
        self.port = port
        self.queue = []          # pending (channel, motion) for the next PullMessages
        self.subscriptions = 0
        self.unsubscribes = 0
        self.pulls = 0
        self.calls = []          # (kind) seen, for assertions

    def sub_url(self):
        return "http://%s:%d%s" % (self.host, self.port, SUB_PATH)

    def queue_motion(self, channel, motion):
        self.queue.append((channel, motion))

    # c4mock calls this as web(method, url, headers, body) and expects (code, text).
    def __call__(self, method, url, headers, body):
        path = urlsplit(url).path
        body = body or ""

        if "GetSystemDateAndTime" in body:
            self.calls.append("datetime")
            return 200, (
                "<s:Envelope xmlns:s='http://www.w3.org/2003/05/soap-envelope'>"
                "<s:Body><tds:GetSystemDateAndTimeResponse>"
                "<tds:SystemDateAndTime><tt:UTCDateTime/></tds:SystemDateAndTime>"
                "</tds:GetSystemDateAndTimeResponse></s:Body></s:Envelope>"
            )

        if "CreatePullPointSubscription" in body:
            self.calls.append("subscribe")
            self.subscriptions += 1
            return 200, (
                "<s:Envelope xmlns:s='http://www.w3.org/2003/05/soap-envelope' "
                "xmlns:tev='http://www.onvif.org/ver10/events/wsdl' "
                "xmlns:wsa='http://www.w3.org/2005/08/addressing'>"
                "<s:Body><tev:CreatePullPointSubscriptionResponse>"
                "<tev:SubscriptionReference><wsa:Address>%s</wsa:Address></tev:SubscriptionReference>"
                "<wsnt:CurrentTime xmlns:wsnt='x'>2026-11-09T06:20:51Z</wsnt:CurrentTime>"
                "</tev:CreatePullPointSubscriptionResponse></s:Body></s:Envelope>"
            ) % self.sub_url()

        if path == SUB_PATH and "Unsubscribe" in body:
            self.calls.append("unsubscribe")
            self.unsubscribes += 1
            return 200, "<s:Envelope xmlns:s='http://www.w3.org/2003/05/soap-envelope'><s:Body/></s:Envelope>"

        if path == SUB_PATH and "PullMessages" in body:
            self.calls.append("pull")
            self.pulls += 1
            msgs = "".join(_motion_message(c, m) for c, m in self.queue)
            self.queue = []
            return 200, (
                "<s:Envelope xmlns:s='http://www.w3.org/2003/05/soap-envelope' "
                "xmlns:wsnt='http://docs.oasis-open.org/wsn/b-2' "
                "xmlns:tns1='http://www.onvif.org/ver10/topics' "
                "xmlns:tt='http://www.onvif.org/ver10/schema' "
                "xmlns:tev='http://www.onvif.org/ver10/events/wsdl'>"
                "<s:Body><tev:PullMessagesResponse>"
                "<tev:CurrentTime>2026-11-09T06:21:14Z</tev:CurrentTime>"
                "<tev:TerminationTime>2026-11-09T06:31:14Z</tev:TerminationTime>"
                "%s"
                "</tev:PullMessagesResponse></s:Body></s:Envelope>"
            ) % msgs

        return 404, "<s:Envelope><s:Body><s:Fault><s:Reason><s:Text>not found</s:Text></s:Reason></s:Fault></s:Body></s:Envelope>"
