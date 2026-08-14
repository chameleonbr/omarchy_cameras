#!/usr/bin/env python3
"""Self-check for bin/omarchy-cameras-mqtt. Run: python3 test_mqtt.py

Frames the MQTT packets by hand, so the parts that fail silently against a real
broker — a malformed CONNECT, a misread variable-length header — are asserted
here instead of showing up as "no alerts ever arrive".
"""

import importlib.machinery
import importlib.util
import io
import json
import pathlib
import struct
import sys

spec = importlib.util.spec_from_loader(
    "mqtt",
    importlib.machinery.SourceFileLoader(
        "mqtt", str(pathlib.Path(__file__).parent / "bin" / "omarchy-cameras-mqtt")))
mqtt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mqtt)


# --- variable-length integer ------------------------------------------------
#
# The one piece of MQTT framing with real edge cases: it is 7 bits per byte,
# and a payload of 127 vs 128 bytes is the boundary where it grows.

assert mqtt.KEEPALIVE / 2 > mqtt.POLL_TIMEOUT, \
    "the loop must wake several times per keepalive window to ping on schedule"
assert mqtt.KEEPALIVE / 2 < mqtt.KEEPALIVE * 1.5, \
    "brokers drop a client after 1.5 keepalives, so ping well inside that"

assert mqtt.remaining_length(0) == b"\x00"
assert mqtt.remaining_length(127) == b"\x7f"
assert mqtt.remaining_length(128) == b"\x80\x01"
assert mqtt.remaining_length(16383) == b"\xff\x7f"
assert mqtt.remaining_length(16384) == b"\x80\x80\x01"


def reader_over(data):
    """A read(n) like the one run() builds around a socket."""
    stream = io.BytesIO(data)

    def read(count):
        chunk = stream.read(count)
        if len(chunk) < count:
            raise ConnectionError("short read")
        return chunk
    return read


for value in (0, 1, 127, 128, 300, 16383, 16384, 2097151):
    assert mqtt.read_remaining_length(reader_over(mqtt.remaining_length(value))) == value, value

# A length field that never terminates must not spin forever.
try:
    mqtt.read_remaining_length(reader_over(b"\xff\xff\xff\xff\xff"))
    raise AssertionError("a malformed length must raise")
except ValueError:
    pass


# --- CONNECT ----------------------------------------------------------------

def parse_connect(packet):
    assert packet[0] == mqtt.CONNECT
    read = reader_over(packet[1:])
    length = mqtt.read_remaining_length(read)
    offset = 1 + len(mqtt.remaining_length(length))
    body = packet[offset:]
    assert len(body) == length, (len(body), length)
    name_len = struct.unpack("!H", body[:2])[0]
    assert body[2:2 + name_len] == b"MQTT"
    rest = body[2 + name_len:]
    return {"version": rest[0], "flags": rest[1],
            "keepalive": struct.unpack("!H", rest[2:4])[0], "payload": rest[4:]}


def fields(payload):
    out = []
    while payload:
        size = struct.unpack("!H", payload[:2])[0]
        out.append(payload[2:2 + size].decode())
        payload = payload[2 + size:]
    return out


anon = parse_connect(mqtt.connect_packet("cid", "", ""))
assert anon["version"] == 4, "MQTT 3.1.1"
assert anon["flags"] == 0x02, "clean session only"
assert fields(anon["payload"]) == ["cid"]

authed = parse_connect(mqtt.connect_packet("cid", "avila", "s3cr3t"))
assert authed["flags"] == 0x02 | 0x80 | 0x40, "username and password flags"
assert fields(authed["payload"]) == ["cid", "avila", "s3cr3t"]

# A user with no stored password must still announce the username, or the
# broker rejects the connection with a misleading protocol error.
user_only = parse_connect(mqtt.connect_packet("cid", "avila", ""))
assert user_only["flags"] == 0x02 | 0x80
assert fields(user_only["payload"]) == ["cid", "avila"]

# A long client id crosses the one-byte length boundary.
long_id = "x" * 200
assert fields(parse_connect(mqtt.connect_packet(long_id, "", ""))["payload"]) == [long_id]


# --- SUBSCRIBE --------------------------------------------------------------

sub = mqtt.subscribe_packet("frigate/events")
assert sub[0] == mqtt.SUBSCRIBE, "SUBSCRIBE must carry the required 0x02 flags"
read = reader_over(sub[1:])
length = mqtt.read_remaining_length(read)
body = sub[1 + len(mqtt.remaining_length(length)):]
assert len(body) == length
assert struct.unpack("!H", body[:2])[0] == 1, "packet id"
assert fields(body[2:-1]) == ["frigate/events"]
assert body[-1] == 0, "QoS 0, so PUBLISH frames carry no packet id"


# --- event payloads ---------------------------------------------------------

def captured(payload):
    out = io.StringIO()
    real, sys.stdout = sys.stdout, out
    try:
        mqtt.handle_publish(payload)
    finally:
        sys.stdout = real
    return [json.loads(line) for line in out.getvalue().splitlines()]


event = {"id": "1786722898.5-abc", "camera": "tapo", "label": "person",
         "start_time": 1786722898.5, "end_time": None, "has_snapshot": True}

# Only `new`. `update` and `end` are the same detection again, and the QML side
# dedupes on id anyway — but sending them would make every event alert three
# times if that dedup ever regressed.
assert captured(json.dumps({"type": "new", "before": {}, "after": event}).encode()) == [[event]]
assert captured(json.dumps({"type": "update", "after": event}).encode()) == []
assert captured(json.dumps({"type": "end", "after": event}).encode()) == []

# The wrapper is a one-element array so the QML side can hand it to the same
# parser it uses for HTTP replies.
assert captured(json.dumps({"type": "new", "after": event}).encode())[0] == [event]

assert captured(b"not json") == [], "a malformed retained message must not kill the stream"
assert captured(b'{"type":"new"}') == [], "no event object, nothing to report"
assert captured(json.dumps({"type": "new", "after": {"camera": "x"}}).encode()) == [], \
    "an event with no id cannot be de-duplicated"
assert captured(b'[1,2,3]') == [], "a non-object payload is not an event"

# Frigate omits `after` on some messages; `before` carries the same shape.
assert captured(json.dumps({"type": "new", "before": event}).encode()) == [[event]]

print("ok")
