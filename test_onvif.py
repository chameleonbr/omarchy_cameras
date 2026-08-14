#!/usr/bin/env python3
"""Self-check for bin/omarchy-cameras-onvif. Run: python3 test_onvif.py

Covers the two things that fail silently against a real camera: a wrong
WS-Security digest (the camera just answers 401) and a SOAP response parsed
with the wrong namespace assumptions (an empty stream URI).
"""

import base64
import importlib.machinery
import importlib.util
import pathlib

# The script has no .py extension, so import it by path.
spec = importlib.util.spec_from_loader(
    "onvif",
    importlib.machinery.SourceFileLoader(
        "onvif", str(pathlib.Path(__file__).parent / "bin" / "omarchy-cameras-onvif")))
onvif = importlib.util.module_from_spec(spec)
spec.loader.exec_module(onvif)


# --- WS-Security UsernameToken digest ---------------------------------------
#
# Vector cross-checked against zeep 4.x (zeep.wsse.username.UsernameToken with
# use_digest=True), an independent implementation of the same profile. The
# example printed in the OASIS spec itself does not reproduce — it is a known
# erratum — so do not "fix" this constant to match it.

NONCE = b"0123456789abcdef"
CREATED = "2026-01-02T03:04:05+00:00"
assert onvif.password_digest(NONCE, CREATED, "s3cr3t") == "wk1Gzs05dw9arqW9sBJzUezLSt4="

# The nonce is hashed raw but travels as base64, and the hashed timestamp must
# be byte-identical to the one in <Created>. Getting either wrong still
# produces a plausible-looking header, so assert both explicitly.
header = onvif.security_header("admin", "s3cr3t", nonce=NONCE, created=CREATED)
assert "wk1Gzs05dw9arqW9sBJzUezLSt4=" in header
assert base64.b64encode(NONCE).decode() in header
assert ">%s<" % CREATED in header
assert onvif.security_header("", "s3cr3t") == "", "no user means no Security header"

# XML metacharacters in a password or username must not break the envelope.
assert "&amp;" in onvif.security_header("a&b", "x", nonce=NONCE, created=CREATED)


# --- WS-Discovery ProbeMatches ----------------------------------------------

PROBE_MATCHES = """<?xml version="1.0" encoding="utf-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope"
  xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
  xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
 <SOAP-ENV:Body>
  <d:ProbeMatches>
   <d:ProbeMatch>
    <wsa:EndpointReference><wsa:Address>urn:uuid:abc</wsa:Address></wsa:EndpointReference>
    <d:Scopes>onvif://www.onvif.org/type/video_encoder onvif://www.onvif.org/name/Port%C3%A3o%20Lateral onvif://www.onvif.org/hardware/IPC-B140</d:Scopes>
    <d:XAddrs>http://192.168.1.64/onvif/device_service http://[fe80::1]/onvif/device_service</d:XAddrs>
   </d:ProbeMatch>
  </d:ProbeMatches>
 </SOAP-ENV:Body>
</SOAP-ENV:Envelope>"""

devices = onvif.parse_probe_matches(PROBE_MATCHES.encode())
assert len(devices) == 1, devices
assert devices[0]["xaddr"] == "http://192.168.1.64/onvif/device_service"
assert devices[0]["host"] == "192.168.1.64"
assert devices[0]["name"] == "Portão Lateral", "percent-encoded scope names must decode"
assert onvif.parse_probe_matches(b"not xml") == [], "junk on the wire must not raise"

# A device with no scope name falls back to the hardware scope, then the host.
no_name = PROBE_MATCHES.replace("onvif://www.onvif.org/name/Port%C3%A3o%20Lateral ", "")
assert onvif.parse_probe_matches(no_name.encode())[0]["name"] == "IPC-B140"


# --- GetCapabilities / GetStreamUri parsing ---------------------------------
#
# Namespace prefixes below are deliberately not the ones the request uses:
# cameras answer with their own, and matching on prefixes rather than local
# names is the classic way this breaks in the field.

CAPABILITIES = """<env:Envelope xmlns:env="http://www.w3.org/2003/05/soap-envelope"
  xmlns:tds="http://www.onvif.org/ver10/device/wsdl"
  xmlns:tt="http://www.onvif.org/ver10/schema">
 <env:Body><tds:GetCapabilitiesResponse><tds:Capabilities>
  <tt:Device><tt:XAddr>http://192.168.1.64/onvif/device_service</tt:XAddr></tt:Device>
  <tt:Media><tt:XAddr>http://192.168.1.64/onvif/media_service</tt:XAddr></tt:Media>
  <tt:PTZ><tt:XAddr>http://192.168.1.64/onvif/ptz_service</tt:XAddr></tt:PTZ>
 </tds:Capabilities></tds:GetCapabilitiesResponse></env:Body></env:Envelope>"""

import xml.etree.ElementTree as ET  # noqa: E402 - after the module is loaded

services = onvif.service_xaddrs(ET.fromstring(CAPABILITIES))
assert services["Media"] == "http://192.168.1.64/onvif/media_service"
assert services["PTZ"] == "http://192.168.1.64/onvif/ptz_service"

fixed = CAPABILITIES.replace("<tt:PTZ><tt:XAddr>http://192.168.1.64/onvif/ptz_service</tt:XAddr></tt:PTZ>", "")
assert "PTZ" not in onvif.service_xaddrs(ET.fromstring(fixed)), "a fixed camera has no PTZ"


# --- credential stripping ---------------------------------------------------

assert (onvif.strip_credentials("rtsp://admin:hunter2@192.168.1.64:554/Streaming/1")
        == "rtsp://192.168.1.64:554/Streaming/1")
assert (onvif.strip_credentials("rtsp://192.168.1.64/Streaming/1?x=1")
        == "rtsp://192.168.1.64/Streaming/1?x=1")
assert onvif.strip_credentials("garbage") == "garbage", "unparseable input passes through"

# ...and putting them back for mpv. A password with URL metacharacters must not
# be able to redirect the stream at another host.
assert (onvif.with_credentials("rtsp://192.168.1.64:554/s1", "admin", "p@ss/word")
        == "rtsp://admin:p%40ss%2Fword@192.168.1.64:554/s1")
assert (onvif.with_credentials("rtsp://192.168.1.64/s1", "admin", "")
        == "rtsp://admin@192.168.1.64/s1")
assert (onvif.with_credentials("rtsp://192.168.1.64/s1", "", "pw")
        == "rtsp://192.168.1.64/s1"), "no user means the URL is left alone"

# --- resolving a typed address ------------------------------------------------
#
# WS-Discovery is multicast and most Wi-Fi access points drop it between
# clients, so naming a camera by address is the path that actually works there.
# The port is not knowable in advance either: of three cameras on one network,
# one answered on 2020 and two on 80.

assert onvif.DEVICE_PORTS[0] == 80, "cheapest guess first"
for port in (80, 8000, 2020):
    assert port in onvif.DEVICE_PORTS, port
assert "/onvif/device_service" in onvif.DEVICE_PATHS

calls = []


def fake_probe(url, timeout=2):
    calls.append(url)
    return url == "http://10.0.0.9:2020/onvif/device_service"


real_probe, onvif.probe_service = onvif.probe_service, fake_probe
try:
    assert onvif.resolve_service("10.0.0.9") == "http://10.0.0.9:2020/onvif/device_service"
    assert calls[0] == "http://10.0.0.9:80/onvif/device_service", "tries 80 first"

    # An explicit port is an instruction, not a hint: do not scan past it.
    calls.clear()
    assert onvif.resolve_service("10.0.0.9:2020") == "http://10.0.0.9:2020/onvif/device_service"
    assert all(":2020" in c for c in calls), calls

    # A full URL is taken as given, and still verified.
    calls.clear()
    assert onvif.resolve_service("http://10.0.0.9:2020/onvif/device_service")
    assert calls == ["http://10.0.0.9:2020/onvif/device_service"]
    assert onvif.resolve_service("http://10.0.0.9/nope") == ""

    calls.clear()
    assert onvif.resolve_service("10.0.0.250") == "", "nothing answering is not an error"
    assert len(calls) == len(onvif.DEVICE_PORTS) * len(onvif.DEVICE_PATHS)
finally:
    onvif.probe_service = real_probe

print("ok")
