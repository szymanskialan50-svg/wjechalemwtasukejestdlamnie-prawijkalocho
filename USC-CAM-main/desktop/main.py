import os
import socket
import struct
import sys
import threading
import time
from collections import deque

import cv2
import numpy as np
from PyQt5.QtCore import Qt, QRectF, QSettings, QThread, pyqtSignal
from PyQt5.QtGui import QColor, QFont, QIcon, QImage, QPainter, QPixmap
from PyQt5.QtWidgets import (QApplication, QComboBox, QFrame, QHBoxLayout, QLabel,
                             QLineEdit, QMainWindow, QVBoxLayout, QWidget)

import usbmux

PORT = 9999
CAM_NAME = "HD Camera iPhone"            # name of the virtual webcam (see Install-HD-Camera.bat)
OUT_FPS = [("120 fps", 120), ("60 fps", 60), ("30 fps", 30)]   # rate the virtual camera is fed at
LIVE_INTERVAL = 1 / 60                   # live window refresh
PREVIEW_INTERVAL = 1 / 15              # window preview refresh (the preview costs CPU, keep it low)
PLACEHOLDER_SIZE = (1920, 1080)
PREVIEW_SIZE = (464, 261)                # shown 1:1 in the window (no pixelated upscaling)
DEFAULT_RES_INDEX = 3                    # 1920x1080 - stable size, same as the placeholder
RESOLUTIONS = [("Native (as sent by iPhone)", None),
               ("3840x2160  (4K UHD)", (3840, 2160)),
               ("2560x1440  (QHD)", (2560, 1440)),
               ("1920x1080  (FHD)", (1920, 1080)),
               ("1280x720  (HD)", (1280, 720))]


def resource_path(name):
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, name)


def dshow_camera_installed(name):
    """True if a DirectShow video device with this friendly name is registered."""
    if sys.platform != "win32":
        return False
    import winreg
    path = r"CLSID\{860BB310-5D01-11d0-BD3B-00A0C911CE86}\Instance"
    try:
        root = winreg.OpenKey(winreg.HKEY_CLASSES_ROOT, path)
    except OSError:
        return False
    i = 0
    while True:
        try:
            sub = winreg.EnumKey(root, i)
        except OSError:
            return False
        i += 1
        try:
            with winreg.OpenKey(root, sub) as k:
                if winreg.QueryValueEx(k, "FriendlyName")[0] == name:
                    return True
        except OSError:
            pass


def open_camera(w, h, fps):
    """Opens ONLY our own virtual camera 'HD Camera iPhone' (never OBS)."""
    import pyvirtualcam
    last = None
    for fmt, swap in ((pyvirtualcam.PixelFormat.BGR, False),
                      (pyvirtualcam.PixelFormat.RGB, True)):
        try:
            cam = pyvirtualcam.Camera(width=w, height=h, fps=fps, fmt=fmt, backend="unitycapture")
            return cam, CAM_NAME, swap
        except Exception as e:      # noqa: BLE001
            last = e
    raise RuntimeError(last)


def install_driver():
    """Copies the bundled camera DLLs to a permanent folder and registers them as
    'HD Camera iPhone' (one UAC prompt). Returns True when the camera is registered."""
    if sys.platform != "win32":
        return False
    import ctypes
    import tempfile
    src = resource_path("driver")
    if not os.path.isdir(src):
        return False
    dst = os.path.join(os.environ.get("ProgramData", r"C:\ProgramData"), "HDCameraiPhone")
    bat = os.path.join(tempfile.gettempdir(), "hdcam_install.bat")
    with open(bat, "w") as f:
        f.write('@echo off\r\nmkdir "%s" 2>nul\r\ncopy /y "%s\\*.dll" "%s\\" >nul\r\n' % (dst, src, dst))
        f.write('regsvr32 /s /u /n /i:UnityCaptureName="HD Camera USC-CAM" "%s\\HDCameraiPhone64.dll" >nul 2>&1\r\n' % dst)
        f.write('regsvr32 /s /n /i:UnityCaptureName="%s" "%s\\HDCameraiPhone64.dll"\r\n' % (CAM_NAME, dst))
        f.write('regsvr32 /s /n /i:UnityCaptureName="%s" "%s\\HDCameraiPhone32.dll"\r\n' % (CAM_NAME, dst))
    ctypes.windll.shell32.ShellExecuteW(None, "runas", "cmd.exe", '/c "%s"' % bat, None, 0)
    for _ in range(60):
        time.sleep(0.5)
        if dshow_camera_installed(CAM_NAME):
            return True
    return False


def make_placeholder(icon_path):
    """Renders the 'Waiting for camera' screen (app icon + text) as a BGR numpy image."""
    w, h = PLACEHOLDER_SIZE
    img = QImage(w, h, QImage.Format_RGB888)
    img.fill(QColor("#0A0A0A"))
    p = QPainter(img)
    p.setRenderHint(QPainter.Antialiasing)
    p.setRenderHint(QPainter.SmoothPixmapTransform)
    p.setRenderHint(QPainter.TextAntialiasing)
    size = 340
    if os.path.exists(icon_path):
        pm = QIcon(icon_path).pixmap(512, 512)
        if not pm.isNull():
            pm = pm.scaled(size, size, Qt.KeepAspectRatio, Qt.SmoothTransformation)
            p.drawPixmap((w - pm.width()) // 2, h // 2 - pm.height() // 2 - 90, pm)
    p.setPen(QColor("#FFFFFF"))
    f = QFont("Segoe UI", 44)
    f.setBold(True)
    f.setLetterSpacing(QFont.AbsoluteSpacing, 2)
    p.setFont(f)
    p.drawText(QRectF(0, h // 2 + 120, w, 90), Qt.AlignCenter, "Waiting for camera")
    p.setPen(QColor("#8A8A8A"))
    p.setFont(QFont("Segoe UI", 20))
    p.drawText(QRectF(0, h // 2 + 210, w, 50), Qt.AlignCenter,
               "Connect your iPhone with USB and open USC-CAM")
    p.end()
    ptr = img.constBits()
    ptr.setsize(img.byteCount())
    arr = np.frombuffer(ptr, np.uint8).reshape(h, img.bytesPerLine())[:, :w * 3]
    return cv2.cvtColor(np.ascontiguousarray(arr).reshape(h, w, 3), cv2.COLOR_RGB2BGR)


class LatestSlot:
    """Thread-safe 'newest item only' mailbox. Old unread items are overwritten."""

    def __init__(self):
        self.cond = threading.Condition()
        self.item = None
        self.dead = False

    def put(self, item):
        with self.cond:
            self.item = item
            self.cond.notify()

    def close(self):
        with self.cond:
            self.dead = True
            self.cond.notify_all()

    def get(self, timeout):
        with self.cond:
            if self.item is None and not self.dead:
                self.cond.wait(timeout)
            item, self.item = self.item, None
            return item


class FrameQueue:
    """Ordered mailbox (H.264 frames depend on each other, so none may be skipped)."""

    def __init__(self):
        self.cond = threading.Condition()
        self.items = deque()
        self.dead = False

    def put(self, item):
        with self.cond:
            self.items.append(item)
            self.cond.notify()

    def close(self):
        with self.cond:
            self.dead = True
            self.cond.notify_all()

    def take_all(self, timeout):
        with self.cond:
            if not self.items and not self.dead:
                self.cond.wait(timeout)
            out = list(self.items)
            self.items.clear()
            return out


class FrameReceiver(threading.Thread):
    """Drains the socket as fast as possible. Packet: [4B len][1B codec 0=JPEG 1=H.264][payload]."""

    def __init__(self, sock):
        super().__init__(daemon=True)
        self.sock = sock
        self.q = FrameQueue()
        self.halt = False
        self.bytes = 0

    def ack(self, n):
        """Tells the phone n frames are done -> it may send n more (keeps the link free of old frames)."""
        try:
            self.sock.sendall(b"\x01" * n)
        except OSError:
            pass

    def run(self):
        try:
            while not self.halt:
                size = struct.unpack(">I", usbmux.recv_exact(self.sock, 4))[0]
                if size < 2 or size > 64 * 1024 * 1024:
                    raise ConnectionError("bad frame header")
                buf = usbmux.recv_exact(self.sock, size)
                self.bytes += size
                self.q.put((buf[0], memoryview(buf)[1:]))
        except Exception:                        # noqa: BLE001 - any error ends the stream
            pass
        finally:
            self.q.close()


class H264Decoder:
    """Low-latency H.264 decoding with PyAV (FFmpeg): one access unit in -> one frame out."""

    def __init__(self):
        import av
        self.av = av
        self.reset()

    def reset(self):
        ctx = self.av.CodecContext.create("h264", "r")
        try:
            ctx.thread_type = "SLICE"            # no frame threading = no extra frames of delay
            ctx.options = {"flags": "low_delay"}
        except Exception:                        # noqa: BLE001
            pass
        self.ctx = ctx

    def decode(self, data, target):
        try:
            frames = self.ctx.decode(self.av.Packet(bytes(data)))
        except Exception:                        # noqa: BLE001 - wait for the next key frame
            self.reset()
            return None
        if not frames:
            return None
        fr = frames[-1]
        w, h = target if target else (fr.width, fr.height)
        try:
            return fr.reformat(width=w, height=h, format="bgr24", src_colorspace="ITU709").to_ndarray()
        except Exception:                        # noqa: BLE001
            return fr.reformat(width=w, height=h, format="bgr24").to_ndarray()


class Decoder(threading.Thread):
    """Decode + rotate in its own thread, so the (sometimes blocking) virtual-camera send never
    delays decoding. Keeps only the newest finished frame. Acks every frame AFTER decoding."""

    def __init__(self, rx, worker):
        super().__init__(daemon=True)
        self.rx = rx
        self.worker = worker
        self.slot = LatestSlot()
        self.halt = False
        self.h264 = None
        self.decode_ms = 0.0
        self.codec = ""

    def _jpeg(self, data, target, src_w):
        flag = cv2.IMREAD_COLOR
        # Downscaling to <= half size: libjpeg decodes at 1/2 scale (much faster than full 4K)
        if target and src_w >= 2 * target[0]:
            flag = cv2.IMREAD_REDUCED_COLOR_2
        frame = cv2.imdecode(np.frombuffer(data, np.uint8), flag)
        if frame is None:
            return None, src_w
        src_w = frame.shape[1] * (2 if flag == cv2.IMREAD_REDUCED_COLOR_2 else 1)
        if target and (frame.shape[1], frame.shape[0]) != target:
            frame = cv2.resize(frame, target, interpolation=cv2.INTER_LINEAR)
        return frame, src_w

    def run(self):
        src_w = 0
        try:
            while not self.halt:
                items = self.rx.q.take_all(0.5)
                if not items:
                    if self.rx.q.dead:
                        break
                    continue
                t0 = t_rx = time.perf_counter()
                target = self.worker.target
                frame = None
                jpeg = None
                for codec, data in items:
                    if codec == 1:
                        if self.h264 is None:
                            self.h264 = H264Decoder()
                        f = self.h264.decode(data, target)
                        if f is not None:
                            frame = f
                            self.codec = "H.264"
                    else:
                        jpeg = data                  # MJPEG: only the newest one matters
                if frame is None and jpeg is not None:
                    frame, src_w = self._jpeg(jpeg, target, src_w)
                    self.codec = "MJPEG"
                self.rx.ack(len(items))
                if frame is None:
                    continue
                if self.worker.rotate180:
                    frame = cv2.rotate(frame, cv2.ROTATE_180)
                self.decode_ms = self.decode_ms * 0.9 + (time.perf_counter() - t0) * 1000 * 0.1
                self.slot.put((frame, t_rx))
        except Exception:                        # noqa: BLE001
            pass
        finally:
            self.slot.close()


class VirtualCam:
    """Keeps ONE virtual camera open (also while the phone is away) and re-opens it on size/fps change."""

    def __init__(self):
        self.cam = None
        self.key = None
        self.name = ""
        self.swap = False
        self.send_ms = 0.0              # how long cam.send() blocks (average)

    def ensure(self, w, h, fps=30):
        if self.cam is not None and self.key == (w, h, fps):
            return True
        self.close()
        try:
            self.cam, self.name, self.swap = open_camera(w, h, fps)
            self.key = (w, h, fps)
            return True
        except Exception:                        # noqa: BLE001
            self.cam = None
            return False

    def send(self, frame):
        if self.cam is not None:
            t0 = time.perf_counter()
            self.cam.send(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB) if self.swap else frame)
            self.send_ms = self.send_ms * 0.9 + (time.perf_counter() - t0) * 1000 * 0.1

    def close(self):
        if self.cam is not None:
            try:
                self.cam.close()
            except Exception:                    # noqa: BLE001
                pass
        self.cam, self.key = None, None


def precise_sleep(seconds):
    """Sleeps ~seconds (1 ms Windows timer is requested at start-up, see tune_process)."""
    if seconds > 0.0005:
        time.sleep(seconds)


def to_qimage(frame):
    """Exactly the frame that goes to the virtual camera, scaled down smoothly for the window."""
    small = cv2.resize(frame, PREVIEW_SIZE, interpolation=cv2.INTER_AREA)
    rgb = cv2.cvtColor(small, cv2.COLOR_BGR2RGB)
    return QImage(rgb.data, rgb.shape[1], rgb.shape[0], rgb.strides[0], QImage.Format_RGB888).copy()


class StreamWorker(QThread):
    status = pyqtSignal(str, str)      # text, state: wait | live | error
    stats = pyqtSignal(str)
    preview = pyqtSignal(QImage)
    live = pyqtSignal(object)         # full-size frame for the live window

    def __init__(self, placeholder):
        super().__init__()
        self._running = True
        self.target = None             # None = native, or (w, h)
        self.rotate180 = True          # always: phone is mounted upside down
        self.wifi_ip = None            # None = USB cable, otherwise the iPhone's IP (Wi-Fi)
        self.out_fps = 120             # rate the virtual camera is fed at (set the same fps in OBS)
        self.show_live = False         # also push every frame to the separate live window
        self.placeholder = placeholder
        self.vcam = VirtualCam()
        self._ph_cache = {}
        self._ph_preview = None

    def stop(self):
        self._running = False

    # -- 'Waiting for camera' screen shown in Zoom/OBS/etc. while the phone is not streaming
    def _placeholder_for(self, size):
        if size not in self._ph_cache:
            self._ph_cache[size] = (self.placeholder if size == PLACEHOLDER_SIZE else
                                    cv2.resize(self.placeholder, size, interpolation=cv2.INTER_AREA))
        return self._ph_cache[size]

    def _wait(self, seconds):
        """Sleeps while feeding the placeholder to the virtual camera (~10 fps)."""
        end = time.time() + seconds
        size = self.target or PLACEHOLDER_SIZE
        while self._running and time.time() < end:
            if self.vcam.ensure(size[0], size[1], self.out_fps):
                try:
                    self.vcam.send(self._placeholder_for(size))
                except Exception:                # noqa: BLE001
                    self.vcam.close()
            if self._ph_preview is None:
                self._ph_preview = to_qimage(self.placeholder)
            self.preview.emit(self._ph_preview)
            time.sleep(0.1)

    # -- main loop: find phone -> open tunnel -> stream -> repeat
    def run(self):
        try:
            self._loop()
        finally:
            self.vcam.close()

    def _loop(self):
        if sys.platform == "win32" and not dshow_camera_installed(CAM_NAME):
            self.status.emit("Installing camera '%s' - accept the Windows prompt" % CAM_NAME, "wait")
            if not install_driver():
                self.status.emit("Camera driver not installed - run Install-HD-Camera.bat as admin", "error")
        while self._running:
            if self.wifi_ip:
                try:
                    sock = usbmux.connect_tcp(self.wifi_ip, PORT)
                except OSError:
                    self.status.emit("Waiting for iPhone on Wi-Fi (%s) - open USC-CAM, same network" % self.wifi_ip, "wait")
                    self._wait(1.5)
                    continue
                try:
                    self._stream(sock)
                except (OSError, ConnectionError, struct.error):
                    pass
                finally:
                    sock.close()
                self.stats.emit("")
                self.status.emit("Waiting for camera - stream stopped", "wait")
                self._wait(1)
                continue
            try:
                devices = usbmux.list_usb_devices()
            except OSError:
                self.status.emit("Apple USB driver not found - install iTunes or Apple Devices", "error")
                self._wait(2)
                continue
            if not devices:
                self.status.emit("Waiting for camera - connect your iPhone with a USB cable", "wait")
                self._wait(1.5)
                continue
            try:
                sock = usbmux.connect(devices[0], PORT)
            except (usbmux.UsbmuxError, OSError):
                self.status.emit("Waiting for camera - open USC-CAM on your iPhone (tap Trust)", "wait")
                self._wait(1.5)
                continue
            try:
                self._stream(sock)
            except (OSError, ConnectionError, struct.error):
                pass
            finally:
                sock.close()
            self.stats.emit("")
            self.status.emit("Waiting for camera - stream stopped", "wait")
            self._wait(1)

    def _stream(self, sock):
        rx = FrameReceiver(sock)
        rx.start()
        dec = Decoder(rx, self)
        dec.start()
        log = open_log()
        is_live = False
        last = None
        t_rx = 0.0
        fresh_n = out_n = 0
        age_sum = 0.0
        last_bytes = 0
        tick = last_prev = last_live = time.perf_counter()
        next_t = time.perf_counter()
        try:
            while self._running:
                # Fixed output rhythm (= the fps announced to the virtual camera): the consuming app
                # gets evenly spaced frames instead of bursts, always the newest decoded picture.
                interval = 1.0 / self.out_fps
                wait = next_t - time.perf_counter()
                if wait > 0:
                    precise_sleep(wait)
                next_t = max(next_t + interval, time.perf_counter() - interval)

                item = dec.slot.get(0)
                if item is not None:
                    last, t_rx = item
                    fresh_n += 1
                elif dec.slot.dead:
                    raise ConnectionError("stream ended")
                if last is None:
                    time.sleep(0.002)
                    continue
                frame = last
                h, w = frame.shape[:2]
                if not self.vcam.ensure(w, h, self.out_fps):
                    self.status.emit("Camera driver missing - run Install-HD-Camera.bat as admin", "error")
                    self._wait(2)
                    raise ConnectionError("no virtual camera")
                if not is_live:
                    is_live = True
                    self.status.emit("LIVE  -  select '%s' in your app" % self.vcam.name, "live")
                now = time.perf_counter()
                age_sum += (now - t_rx) * 1000
                self.vcam.send(frame)
                out_n += 1

                now = time.perf_counter()
                if now - last_prev >= PREVIEW_INTERVAL:   # ~15 fps preview of the real camera output
                    last_prev = now
                    self.preview.emit(to_qimage(frame))
                if self.show_live and item is not None and now - last_live >= LIVE_INTERVAL:
                    last_live = now
                    self.live.emit(frame)
                if now - tick >= 1:
                    dt = now - tick
                    mbit = (rx.bytes - last_bytes) * 8 / 1e6 / dt
                    last_bytes = rx.bytes
                    text = ("%dx%d  -  in %d fps / out %d fps  -  %s  -  %.0f Mbit/s\n"
                            "decode %.1f ms  -  vcam send %.1f ms  -  frame age %.0f ms" % (
                                w, h, round(fresh_n / dt), round(out_n / dt), dec.codec or "?", mbit,
                                dec.decode_ms, self.vcam.send_ms, age_sum / max(out_n, 1)))
                    self.stats.emit(text)
                    if log:
                        log.write(time.strftime("%H:%M:%S ") + text.replace("\n", " | ") + "\n")
                        log.flush()
                    fresh_n = out_n = 0
                    age_sum = 0.0
                    tick = now
        finally:
            rx.halt = True
            dec.halt = True
            if log:
                log.close()


def open_log():
    """Per-second timing log (usc-cam.log in the temp folder) - handy for diagnosing lag."""
    try:
        import tempfile
        return open(os.path.join(tempfile.gettempdir(), "usc-cam.log"), "a", encoding="utf-8")
    except OSError:
        return None


class LiveWindow(QWidget):
    """Full-quality picture in its own window, bypassing the virtual camera.
    In OBS add it with 'Window Capture' (or Game Capture) - low latency, no driver in between."""

    def __init__(self):
        super().__init__()
        self.setWindowTitle("USC-CAM Live")
        self.resize(960, 540)
        self.setStyleSheet("background-color: #000000;")
        self.label = QLabel(self)
        self.label.setAlignment(Qt.AlignCenter)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.addWidget(self.label)

    def show_frame(self, frame):
        h, w = frame.shape[:2]
        img = QImage(frame.data, w, h, frame.strides[0], QImage.Format_BGR888)
        pm = QPixmap.fromImage(img)
        self.label.setPixmap(pm.scaled(self.label.size(), Qt.KeepAspectRatio, Qt.FastTransformation))


class MainWindow(QMainWindow):
    COLORS = {"wait": "#E8A33D", "live": "#3DDC84", "error": "#FF5A5A"}

    def __init__(self):
        super().__init__()
        self.setWindowTitle(CAM_NAME)
        self.setFixedSize(520, 830)
        icon_file = resource_path("icon.ico")
        if os.path.exists(icon_file):
            self.setWindowIcon(QIcon(icon_file))
        self.setStyleSheet("""
            QMainWindow { background-color: #0A0A0A; }
            QLabel { color: #FFFFFF; font-family: 'Segoe UI', sans-serif; }
            QLabel#Title { font-size: 24px; font-weight: bold; letter-spacing: 3px; }
            QLabel#Sub { font-size: 11px; color: #888888; font-weight: 600; letter-spacing: 3px; }
            QLabel#Stats { font-size: 13px; color: #BBBBBB; }
            QFrame#Pill { background-color: #1A1A1A; border-radius: 18px; }
            QLabel#Preview { background-color: #000000; border: 1px solid #262626; border-radius: 10px; }
            QComboBox { background-color: #1A1A1A; color: #FFFFFF; border: 1px solid #333333;
                        border-radius: 8px; padding: 10px 14px; font-size: 14px; font-weight: 600; }
            QComboBox::drop-down { border: none; }
            QComboBox QAbstractItemView { background-color: #1A1A1A; color: #FFFFFF;
                        selection-background-color: #333333; border: 1px solid #333333; }
        """)

        central = QWidget()
        root = QVBoxLayout(central)
        root.setContentsMargins(24, 24, 24, 24)
        root.setSpacing(14)

        title = QLabel(CAM_NAME)
        title.setObjectName("Title")
        title.setAlignment(Qt.AlignCenter)
        sub = QLabel("USB WEBCAM")
        sub.setObjectName("Sub")
        sub.setAlignment(Qt.AlignCenter)
        root.addWidget(title)
        root.addWidget(sub)

        self.preview = QLabel("Waiting for camera")
        self.preview.setObjectName("Preview")
        self.preview.setAlignment(Qt.AlignCenter)
        self.preview.setFixedHeight(270)
        root.addWidget(self.preview)

        pill = QFrame()
        pill.setObjectName("Pill")
        pl = QHBoxLayout(pill)
        pl.setContentsMargins(16, 10, 16, 10)
        self.dot = QLabel("●")
        self.status = QLabel("Starting...")
        self.status.setStyleSheet("font-size: 13px; font-weight: 600;")
        pl.addWidget(self.dot)
        pl.addWidget(self.status, 1)
        root.addWidget(pill)

        self.stats = QLabel("")
        self.stats.setObjectName("Stats")
        self.stats.setAlignment(Qt.AlignCenter)
        root.addWidget(self.stats)

        self.settings = QSettings("USC-CAM", "USC-CAM")
        self.res = QComboBox()
        for label, _ in RESOLUTIONS:
            self.res.addItem(label)
        idx = self.settings.value("res", DEFAULT_RES_INDEX, type=int)
        self.res.setCurrentIndex(idx if 0 <= idx < len(RESOLUTIONS) else DEFAULT_RES_INDEX)
        self.res.currentIndexChanged.connect(self.on_res)
        root.addWidget(self.res)

        self.conn = QComboBox()
        self.conn.addItems(["Connection: USB cable", "Connection: Wi-Fi (same network)"])
        self.conn.setCurrentIndex(self.settings.value("conn", 0, type=int))
        self.conn.currentIndexChanged.connect(self.on_conn)
        root.addWidget(self.conn)

        self.ip = QLineEdit(self.settings.value("ip", "", type=str))
        self.ip.setPlaceholderText("iPhone IP shown in the app, e.g. 192.168.1.23")
        self.ip.setStyleSheet("QLineEdit { background-color: #1A1A1A; color: #FFFFFF; border: 1px solid #333333;"
                              " border-radius: 8px; padding: 10px 14px; font-size: 14px; font-weight: 600; }")
        self.ip.editingFinished.connect(self.on_conn)
        root.addWidget(self.ip)

        self.outfps = QComboBox()
        for label, _ in OUT_FPS:
            self.outfps.addItem("Virtual camera output: " + label)
        oi = self.settings.value("outfps", 0, type=int)
        self.outfps.setCurrentIndex(oi if 0 <= oi < len(OUT_FPS) else 0)
        self.outfps.currentIndexChanged.connect(self.on_outfps)
        root.addWidget(self.outfps)

        self.livebox = QComboBox()
        self.livebox.addItems(["Live window: off", "Live window: on (OBS -> Window Capture)"])
        self.livebox.currentIndexChanged.connect(self.on_live)
        root.addWidget(self.livebox)
        self.livewin = LiveWindow()

        root.addStretch(1)
        self.setCentralWidget(central)

        self.set_status("Starting...", "wait")
        self.worker = StreamWorker(make_placeholder(resource_path("icon.ico")))
        self.worker.target = RESOLUTIONS[self.res.currentIndex()][1]
        self.on_conn()
        self.on_outfps()
        self.worker.live.connect(self.livewin.show_frame)
        self.worker.status.connect(self.set_status)
        self.worker.stats.connect(self.stats.setText)
        self.worker.preview.connect(self.set_preview)
        self.worker.start()

    def on_res(self, i):
        self.settings.setValue("res", i)
        self.worker.target = RESOLUTIONS[i][1]

    def on_conn(self, *_):
        self.settings.setValue("conn", self.conn.currentIndex())
        self.settings.setValue("ip", self.ip.text().strip())
        wifi = self.conn.currentIndex() == 1 and bool(self.ip.text().strip())
        self.ip.setEnabled(self.conn.currentIndex() == 1)
        self.worker.wifi_ip = self.ip.text().strip() if wifi else None

    def on_outfps(self, *_):
        i = self.outfps.currentIndex()
        self.settings.setValue("outfps", i)
        self.worker.out_fps = OUT_FPS[i][1]

    def on_live(self, i):
        self.worker.show_live = bool(i)
        self.livewin.setVisible(bool(i))

    def set_status(self, text, state):
        self.status.setText(text)
        self.dot.setStyleSheet("color: %s; font-size: 14px;" % self.COLORS.get(state, "#888"))

    def set_preview(self, img):
        self.preview.setPixmap(QPixmap.fromImage(img))

    def closeEvent(self, event):
        self.livewin.close()
        self.worker.stop()
        self.worker.wait(2000)
        event.accept()


def tune_process():
    """Lower scheduling latency: 1 ms Windows timer, higher priority, faster thread hand-off."""
    sys.setswitchinterval(0.001)
    if sys.platform == "win32":
        import ctypes
        try:
            ctypes.windll.winmm.timeBeginPeriod(1)
            k32 = ctypes.windll.kernel32
            k32.SetPriorityClass(k32.GetCurrentProcess(), 0x00008000)   # ABOVE_NORMAL_PRIORITY_CLASS
        except Exception:                        # noqa: BLE001
            pass


if __name__ == "__main__":
    tune_process()
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    w = MainWindow()
    w.show()
    sys.exit(app.exec_())
