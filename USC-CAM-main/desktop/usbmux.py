"""Tiny pure-python usbmuxd client (no iproxy / extra packages needed).

On Windows the usbmuxd service is installed together with iTunes / Apple Devices
(Apple Mobile Device Service) and listens on 127.0.0.1:27015.
"""
import plistlib
import socket
import struct
import sys

CLIENT = "USC-CAM"


class UsbmuxError(Exception):
    pass


def _open():
    if sys.platform == "win32":
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(3)
        s.connect(("127.0.0.1", 27015))
    else:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(3)
        s.connect("/var/run/usbmuxd")
    return s


def recv_exact(sock, n):
    """Reads exactly n bytes straight into one preallocated buffer (no copies)."""
    buf = bytearray(n)
    view = memoryview(buf)
    got = 0
    while got < n:
        k = sock.recv_into(view[got:], min(n - got, 4 << 20))
        if not k:
            raise ConnectionError("connection closed")
        got += k
    return buf


def _request(sock, payload, tag=1):
    body = plistlib.dumps(payload)
    sock.sendall(struct.pack("<IIII", 16 + len(body), 1, 8, tag) + body)
    length = struct.unpack("<IIII", recv_exact(sock, 16))[0]
    return plistlib.loads(recv_exact(sock, length - 16))


def list_usb_devices():
    """Returns a list of DeviceIDs of iPhones connected through USB."""
    s = _open()
    try:
        reply = _request(s, {"MessageType": "ListDevices",
                             "ClientVersionString": CLIENT, "ProgName": CLIENT})
    finally:
        s.close()
    return [d["DeviceID"] for d in reply.get("DeviceList", [])
            if d.get("Properties", {}).get("ConnectionType") == "USB"]


def connect(device_id, port):
    """Opens a raw TCP tunnel to `port` on the device. Returns a connected socket."""
    s = _open()
    try:
        reply = _request(s, {"MessageType": "Connect", "ClientVersionString": CLIENT,
                             "ProgName": CLIENT, "DeviceID": device_id,
                             "PortNumber": socket.htons(port)})
    except Exception:
        s.close()
        raise
    if reply.get("Number") != 0:          # 3 = connection refused (app not open)
        s.close()
        raise UsbmuxError("connect failed, code %s" % reply.get("Number"))
    for level, opt, val in ((socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024),
                            (socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)):
        try:
            s.setsockopt(level, opt, val)
        except OSError:
            pass
    s.settimeout(5)
    return s


def connect_tcp(ip, port):
    """Direct TCP connection to the iPhone over Wi-Fi."""
    s = socket.create_connection((ip, port), timeout=3)
    for level, opt, val in ((socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024),
                            (socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)):
        try:
            s.setsockopt(level, opt, val)
        except OSError:
            pass
    s.settimeout(5)
    return s
