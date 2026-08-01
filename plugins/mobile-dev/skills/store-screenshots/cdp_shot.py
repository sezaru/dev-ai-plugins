#!/usr/bin/env python3
"""Deterministic headless-chromium screenshot via the DevTools protocol.

Navigates to a page, waits until it sets window.__READY (so all async WebGL/texture
work is actually finished — chromium's virtual-time budget can't be trusted for the
off-queue createImageBitmap decodes the 3D renderer relies on), then captures a PNG at
an exact device size. Optionally with a transparent background (for compositing).

Stdlib only (socket-level websocket client) so it runs from the plugin's python3.
"""
import base64, json, os, socket, struct, subprocess, sys, time, urllib.request


def _ws_connect(url):
    assert url.startswith("ws://")
    host, _, rest = url[5:].partition("/")
    h, _, p = host.partition(":")
    s = socket.create_connection((h, int(p or 80)))
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall((f"GET /{rest} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
               f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
               f"Sec-WebSocket-Version: 13\r\n\r\n").encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += s.recv(4096)
    return s


def _ws_send(s, obj):
    data = json.dumps(obj).encode()
    hdr = bytearray([0x81])
    n = len(data)
    mask = os.urandom(4)
    if n < 126:
        hdr.append(0x80 | n)
    elif n < 65536:
        hdr.append(0x80 | 126); hdr += struct.pack(">H", n)
    else:
        hdr.append(0x80 | 127); hdr += struct.pack(">Q", n)
    hdr += mask
    s.sendall(bytes(hdr) + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def _ws_recv(s):
    def rd(n):
        b = b""
        while len(b) < n:
            c = s.recv(n - len(b))
            if not c:
                raise IOError("ws closed")
            b += c
        return b
    _, b1 = rd(2)
    ln = b1 & 0x7F
    if ln == 126:
        ln = struct.unpack(">H", rd(2))[0]
    elif ln == 127:
        ln = struct.unpack(">Q", rd(8))[0]
    return json.loads(rd(ln).decode())


class _CDP:
    def __init__(self, ws):
        self.ws = ws
        self.id = 0

    def call(self, method, **params):
        self.id += 1
        mid = self.id
        _ws_send(self.ws, {"id": mid, "method": method, "params": params})
        while True:
            msg = _ws_recv(self.ws)
            if msg.get("id") == mid:
                if "error" in msg:
                    raise RuntimeError(msg["error"])
                return msg.get("result", {})


def capture(chromium, url, out_path, w, h, transparent=False, ready_timeout=40):
    port = 9300 + (os.getpid() % 600)
    prof = f"/tmp/cdp_prof_{os.getpid()}"
    env = dict(os.environ, HOME=prof, XDG_CONFIG_HOME=prof + "/.config")
    proc = subprocess.Popen([
        chromium, "--headless=new", "--no-sandbox", "--disable-gpu",
        "--disable-dev-shm-usage", "--hide-scrollbars",
        "--use-angle=swiftshader", "--enable-unsafe-swiftshader",
        "--allow-file-access-from-files", "--force-device-scale-factor=1",
        f"--window-size={w},{h}", f"--user-data-dir={prof}/profile",
        f"--remote-debugging-port={port}", "about:blank",
    ], env=env, stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    try:
        page_ws = None
        for _ in range(150):
            try:
                lst = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=1))
                for t in lst:
                    if t.get("type") == "page" and t.get("webSocketDebuggerUrl"):
                        page_ws = t["webSocketDebuggerUrl"]
                        break
                if page_ws:
                    break
            except Exception:
                pass
            time.sleep(0.1)
        if not page_ws:
            raise RuntimeError("no page target came up")
        cdp = _CDP(_ws_connect(page_ws))
        cdp.call("Page.enable")
        cdp.call("Runtime.enable")
        # Pin the viewport to exactly w×h. Headless window.innerHeight lands ~180px short of
        # --window-size, so without this the page (and its WebGL canvas) is shorter than the
        # captured clip — the render doesn't fill the image and any pixel maths is off.
        cdp.call("Emulation.setDeviceMetricsOverride",
                 width=w, height=h, deviceScaleFactor=1, mobile=False)
        if transparent:
            cdp.call("Emulation.setDefaultBackgroundColorOverride",
                     color={"r": 0, "g": 0, "b": 0, "a": 0})
        cdp.call("Page.navigate", url=url)
        deadline = time.time() + ready_timeout
        while time.time() < deadline:
            r = cdp.call("Runtime.evaluate", expression="window.__READY===true", returnByValue=True)
            if r.get("result", {}).get("value") is True:
                break
            time.sleep(0.15)
        else:
            print("WARN: __READY never set, capturing anyway", file=sys.stderr)
        meta = None
        try:
            mv = cdp.call("Runtime.evaluate", expression="JSON.stringify(window.__META||null)",
                          returnByValue=True).get("result", {}).get("value")
            meta = json.loads(mv) if mv else None
        except Exception:
            pass
        shot = cdp.call("Page.captureScreenshot", format="png",
                        clip={"x": 0, "y": 0, "width": w, "height": h, "scale": 1})
        with open(out_path, "wb") as f:
            f.write(base64.b64decode(shot["data"]))
        return meta
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("out")
    ap.add_argument("--width", type=int, default=1290)
    ap.add_argument("--height", type=int, default=2796)
    ap.add_argument("--transparent", action="store_true")
    ap.add_argument("--chromium", default=os.environ.get("CHROMIUM_BIN", "chromium"))
    a = ap.parse_args()
    capture(a.chromium, a.url, a.out, a.width, a.height, transparent=a.transparent)
    print(f"wrote {a.out} ({os.path.getsize(a.out)} bytes)")
