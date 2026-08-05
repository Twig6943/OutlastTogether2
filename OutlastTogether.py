import asyncio
import ctypes
import hashlib
import json
import logging
import math
import os
import random
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.request
import webbrowser
from collections import deque
from dataclasses import dataclass, field
from typing import Callable, Dict, Optional, Tuple
from urllib.parse import quote

import tkinter as tk
from tkinter import filedialog, messagebox, ttk
import tkinter.font as tkfont

APP_VERSION = "1.0.0"

# ---------------------------------------------------------------------------
# Custom font: JetBrains Mono Bold
# Windows registers the TTF via AddFontResourceEx so tkinter can reference it
# by family name without needing to install it system-wide.
# ---------------------------------------------------------------------------
_JBM_FAMILY = "JetBrains Mono"   # the family name embedded in the TTF

def _load_custom_font():
    """Register JetBrainsMono-Bold.ttf with the Windows font engine."""
    path = _resource_path("JetBrainsMono-Bold.ttf")
    if not os.path.isfile(path):
        return False
    try:
        FR_PRIVATE = 0x10
        ctypes.windll.gdi32.AddFontResourceExW(path, FR_PRIVATE, None)
        return True
    except Exception:
        return False


# Will be set to the real family name if loading succeeds, else a safe fallback.
_FONT_LOADED = False
APP_FONT      = "Segoe UI"
APP_FONT_MONO = "Segoe UI"


def _init_font():
    """Call once after the Tk root is created to finalise font constants."""
    global APP_FONT, APP_FONT_MONO, _FONT_LOADED
    ok = _load_custom_font()
    available = [f.lower() for f in tkfont.families()]
    if ok and _JBM_FAMILY.lower() in available:
        family = _JBM_FAMILY
        _FONT_LOADED = True
    else:
        family = "Consolas"
    APP_FONT      = family
    APP_FONT_MONO = family

LOG = logging.getLogger("oltogether")


def _resource_path(name):
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, name)


def _set_app_icon(root):
    icon_png = _resource_path("app_icon.png")
    icon_ico = _resource_path("app_icon.ico")
    try:
        if os.path.exists(icon_ico):
            root.iconbitmap(default=icon_ico)
    except Exception:
        pass
    try:
        img = tk.PhotoImage(file=icon_png)
        root.iconphoto(True, img)
        root._app_icon_ref = img
    except Exception:
        pass




def _resolve_device_index(name):
    if not name or name == "Default":
        return None
    try:
        import sounddevice
        label = name.replace(" [Default]", "").strip()
        for idx, dev in enumerate(sounddevice.query_devices()):
            if dev.get("max_input_channels", 0) <= 0:
                continue
            if dev.get("name", "").strip() == label:
                return idx
    except Exception:
        pass
    return None


def _get_audio_devices():
    devices = ["Default"]
    try:
        import sounddevice
        default_in = -1
        try:
            default_in = sounddevice.default.device[0]
        except Exception:
            pass
        for idx, dev in enumerate(sounddevice.query_devices()):
            if dev.get("max_input_channels", 0) > 0:
                name = dev.get("name", "Unknown Device").strip()
                if idx == default_in:
                    devices.append(f"{name} [Default]")
                else:
                    devices.append(name)
    except Exception:
        pass
    seen = set()
    return [d for d in devices if not (d in seen or seen.add(d))]


class MicMeter:
    """Scrolling bar-graph mic meter (adapted from DontScream's AudioVisualizer)."""

    def __init__(self, parent, bg="#0a0e14"):
        self.frame = tk.Frame(parent, bg=bg)
        self.canvas = tk.Canvas(self.frame, width=320, height=40, bg="#050508", highlightthickness=0)
        self.canvas.pack(fill="x")
        self.width = 320
        self.height = 40
        self.num_bars = 32
        self.bars = [0.0] * self.num_bars
        self.smooth = [0.0] * self.num_bars
        self.peaks = [0.0] * self.num_bars
        self.smooth_peaks = [0.0] * self.num_bars
        self._volume = 0.0
        self._peak_hold = [0.0] * self.num_bars
        self._peak_decay = 0.96
        self._color = "#00ff88"
        self._gate = 0.0
        self._gated = True
        self._label = tk.Label(self.frame, text="MIC \u2014 no signal", font=(APP_FONT, 8), bg=bg, fg="#5a6577")
        self._label.pack(fill="x")

    def push(self, volume):
        self._volume = volume

    def set_gate(self, gate_norm, gated):
        # gate_norm is a normalized RMS (0..1); scale to the meter's display
        # range which uses vol = min(1, rms*5).
        self._gate = min(1.0, gate_norm * 5.0)
        self._gated = gated

    def set_color(self, c):
        self._color = c

    def tick(self):
        v = self._volume
        for i in range(self.num_bars - 1):
            self.bars[i] = self.bars[i + 1]
            self.peaks[i] = self.peaks[i + 1]
        self.bars[-1] = v
        if v >= self.peaks[-1]:
            self.peaks[-1] = v
        else:
            self.peaks[-1] = self.peaks[-1] * self._peak_decay
        for i in range(self.num_bars):
            self.smooth[i] += (self.bars[i] - self.smooth[i]) * 0.25
            self.smooth_peaks[i] += (self.peaks[i] - self.smooth_peaks[i]) * 0.2
        self._draw()
        if v > 0.01:
            if self._gated:
                self._label.configure(text="MIC \u2014 below gate (not sent)", fg="#ffaa22")
            else:
                self._label.configure(text=f"MIC \u2588{'█' * int(v * 20)}", fg=self._color)
        else:
            self._label.configure(text="MIC \u2014 no signal", fg="#5a6577")

    def _draw(self):
        self.canvas.delete("all")
        w, h = self.width, self.height
        n = self.num_bars
        bar_w = max(1, (w - 4) // n - 1)
        gap = 1
        for i, (val, pk) in enumerate(zip(self.smooth, self.smooth_peaks)):
            x = 2 + i * (bar_w + gap)
            bh = val * (h - 6)
            ph = pk * (h - 6)
            pct = i / n
            r = int(pct * 255)
            g = int(255 * (1.0 - pct * 0.7))
            b = int(80 * (1.0 - pct))
            if bh > 1:
                self.canvas.create_rectangle(x, h - bh - 2, x + bar_w, h - 2,
                                             fill=f"#{min(255,r):02x}{min(255,g):02x}{min(255,b):02x}", outline="")
            if ph > 1:
                self.canvas.create_rectangle(x, h - ph - 4, x + bar_w, h - ph - 2,
                                             fill="#ffffff", outline="")
        # Noise-gate threshold line: audio below this level isn't transmitted.
        if self._gate > 0.0:
            gy = h - 2 - self._gate * (h - 6)
            self.canvas.create_line(0, gy, w, gy, fill="#ff3355", width=1, dash=(4, 3))


class MicMonitor:
    """Background mic listener that feeds a MicMeter widget."""

    def __init__(self, meter, get_device_fn, get_settings_fn=None):
        self._meter = meter
        self._get_device = get_device_fn
        self._get_settings = get_settings_fn or (lambda: VoiceSettings())
        self._stream = None
        self._volume = 0.0
        self._gated = False

    def restart(self):
        self.stop()
        dev_name = self._get_device()
        dev_idx = _resolve_device_index(dev_name)
        try:
            import sounddevice as sd
            self._stream = sd.InputStream(device=dev_idx, channels=1,
                                          samplerate=16000, blocksize=512, dtype="int16",
                                          callback=self._cb)
            self._stream.start()
        except Exception:
            self._stream = None

    def stop(self):
        if self._stream is not None:
            try:
                self._stream.stop()
                self._stream.close()
            except Exception:
                pass
            self._stream = None

    def _cb(self, indata, frames, time_info, status):
        try:
            import numpy as np
            vs = self._get_settings()
            rms = (np.sqrt(np.mean(indata.astype(np.float32) ** 2)) / 32768.0) * vs.input_gain
            self._gated = rms < vs.noise_gate
            vol = min(1.0, rms * 5.0)
            self._volume = self._volume * 0.3 + vol * 0.7
        except Exception:
            pass

    def tick(self):
        self._meter.push(self._volume)
        self._meter.set_gate(self._get_settings().noise_gate, self._gated)
        self._meter.tick()

MAX_LINE_BYTES = 8192
READ_CHUNK = 4096
CLIENT_QUEUE_LIMIT = 256
CLIENT_TIMEOUT = 20.0
IDLE_CHECK_INTERVAL = 5.0
DISCOVERY_PORT = 47777
DISCOVERY_MAGIC = b"OLTG1"
LAN_BROADCAST_INTERVAL = 2.5
LAN_BROADCAST_COUNT = 3
PING_REPLY_TIMEOUT = 0.35
RELAY_PORT = 7777
MASTER_SERVER_PORT = 47778
MASTER_SERVER_TIMEOUT = 6.0
MASTER_SERVER_HEARTBEAT = 30.0

CRITICAL_PREFIXES = (b"CHAT,", b"NAME,", b"NOTIF,", b"PONG,", b"SMOVE,", b"AUTH,")

VOICE_LOG = logging.getLogger("oltogether.voice")

VOICE_MAGIC = b"OLTV2"
VOICE_MAGIC_V1 = b"OLTV1"  # accepted for backward compat
VOICE_PORT = 7778
VOICE_SAMPLE_RATE = 16000
VOICE_FRAME_MS = 20
VOICE_FRAME_SAMPLES = int(VOICE_SAMPLE_RATE * VOICE_FRAME_MS / 1000)
# OLTV2 header: magic(5s) client_id(I) x(f) y(f) z(f) yaw_rad(f) pcm_len(H)
VOICE_PACKET_FORMAT = "!5sIffffH"
VOICE_PACKET_HEADER = struct.Struct(VOICE_PACKET_FORMAT)
VOICE_MAX_PACKET = 8192
VOICE_BROADCAST_INTERVAL = 0.25

# Local control channel from the game (OLTogetherVoiceListener.uc). Carries
# the player's full 3D world position + yaw and push-to-talk state so the
# voice client can do proper 3D spatial audio without game integration.
# Format: POS,x,y,z,yaw_deg  PTT,0|1  PROX,near,far
GAME_CONTROL_HOST = "127.0.0.1"
GAME_CONTROL_PORT = 6700
GAME_CONTROL_RETRY = 2.0


def _now() -> float:
    return time.monotonic()


@dataclass
class VoiceSettings:
    # Multiplier applied to captured mic samples before sending. 1.0 = unity.
    input_gain: float = 1.0
    # Normalized RMS (0..1, after gain) below which mic frames are treated as
    # silence and not transmitted. Suppresses background hiss / keyboard noise.
    noise_gate: float = 0.02
    # Multiplier applied to incoming audio before playback. 1.0 = unity.
    output_volume: float = 1.0

    def clamp(self):
        self.input_gain = max(0.0, min(5.0, self.input_gain))
        self.noise_gate = max(0.0, min(1.0, self.noise_gate))
        self.output_volume = max(0.0, min(5.0, self.output_volume))
        return self


@dataclass
class VoicePeer:
    client_id: int
    address: Tuple[str, int]
    name: str = ""
    x: float = 0.0
    y: float = 0.0
    z: float = 0.0
    yaw: float = 0.0   # radians, forward = 0
    last_seen: float = field(default_factory=_now)
    muted: bool = False
    ptt: bool = False


class VoiceRelay:
    def __init__(self, host: str = "0.0.0.0", port: int = VOICE_PORT,
                 position_lookup: Optional[Callable[[str], Optional[Tuple[float, float]]]] = None):
        self.host = host
        self.port = port
        self.sock: Optional[socket.socket] = None
        self.running = False
        self.clients_by_addr: Dict[Tuple[str, int], VoicePeer] = {}
        self.clients_by_id: Dict[int, VoicePeer] = {}
        self.next_id = 1
        self.position_lookup = position_lookup

    def start(self):
        if self.running:
            return
        self.running = True
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((self.host, self.port))
        self.sock.settimeout(0.1)
        VOICE_LOG.info("Voice relay listening on %s:%s", self.host, self.port)
        while self.running:
            try:
                data, addr = self.sock.recvfrom(VOICE_MAX_PACKET)
            except socket.timeout:
                self._expire_clients()
                continue
            except Exception:
                if self.running:
                    continue
                break
            self._handle_packet(data, addr)

    def stop(self):
        self.running = False
        try:
            if self.sock:
                self.sock.close()
        except Exception:
            pass

    def _expire_clients(self):
        cutoff = _now() - 5.0
        stale = [addr for addr, client in self.clients_by_addr.items() if client.last_seen < cutoff]
        for addr in stale:
            client = self.clients_by_addr.pop(addr, None)
            if client:
                self.clients_by_id.pop(client.client_id, None)

    def _get_or_create_client(self, addr: Tuple[str, int]) -> VoicePeer:
        client = self.clients_by_addr.get(addr)
        if client is None:
            client = VoicePeer(client_id=self.next_id, address=addr)
            self.next_id += 1
            self.clients_by_addr[addr] = client
            self.clients_by_id[client.client_id] = client
        client.last_seen = _now()
        return client

    def _handle_packet(self, data: bytes, addr: Tuple[str, int]):
        if data.startswith(VOICE_MAGIC + b",JOIN,") or data.startswith(VOICE_MAGIC_V1 + b",JOIN,"):
            self._get_or_create_client(addr)
            return
        is_v2 = data.startswith(VOICE_MAGIC)
        is_v1 = (not is_v2) and data.startswith(VOICE_MAGIC_V1)
        if not (is_v2 or is_v1):
            return
        try:
            if is_v2:
                if len(data) < VOICE_PACKET_HEADER.size:
                    return
                magic, client_id, x, y, z, yaw, pcm_len = VOICE_PACKET_HEADER.unpack_from(data)
                pcm = data[VOICE_PACKET_HEADER.size:VOICE_PACKET_HEADER.size + pcm_len]
            else:
                # OLTV1 fallback: !5sIffH  (no z/yaw)
                _hdr_v1 = struct.Struct("!5sIffH")
                if len(data) < _hdr_v1.size:
                    return
                magic, client_id, x, y, pcm_len = _hdr_v1.unpack_from(data)
                z, yaw = 0.0, 0.0
                pcm = data[_hdr_v1.size:_hdr_v1.size + pcm_len]
            client = self._get_or_create_client(addr)
            client.client_id = client_id or client.client_id
            resolved = self.position_lookup(addr[0]) if self.position_lookup else None
            if resolved is not None:
                client.x, client.y = resolved
            else:
                client.x, client.y, client.z, client.yaw = x, y, z, yaw
            client.last_seen = _now()
            self._broadcast_audio(client, pcm)
        except Exception:
            return

    def _broadcast_audio(self, sender: VoicePeer, pcm: bytes):
        """Forward audio to every other peer. We send full 3D position of the
        sender so each client can compute its own spatial gain + pan."""
        if not self.sock:
            return
        header = VOICE_PACKET_HEADER.pack(
            VOICE_MAGIC, sender.client_id,
            sender.x, sender.y, sender.z, sender.yaw,
            len(pcm)
        )
        payload = header + pcm
        for client in list(self.clients_by_addr.values()):
            if client.address == sender.address:
                continue
            try:
                self.sock.sendto(payload, client.address)
            except Exception:
                continue


class VoiceClient:
    def __init__(self, mic_device: str = "Default", control_host: str = GAME_CONTROL_HOST,
                 control_port: int = GAME_CONTROL_PORT, voice_settings: Optional[VoiceSettings] = None):
        self.mic_device = mic_device
        self.control_host = control_host
        self.control_port = control_port
        self.voice_settings = voice_settings or VoiceSettings()
        self.sock: Optional[socket.socket] = None
        self._relay_addr: Tuple[str, int] = ("127.0.0.1", VOICE_PORT)
        self.running = False
        self.thread: Optional[threading.Thread] = None
        self.send_thread: Optional[threading.Thread] = None
        self.control_thread: Optional[threading.Thread] = None
        self.control_sock: Optional[socket.socket] = None
        self.x: float = 0.0
        self.y: float = 0.0
        self.z: float = 0.0
        self.yaw: float = 0.0   # radians; updated from game POS line
        self.client_id: int = 0
        # ptt: true when always-on OR push-to-talk bind is held
        self.ptt: bool = False
        self.prox_near: float = 800.0
        self.prox_far: float = 5000.0

    def start(self, host: str, port: int):
        if self.running:
            return
        self.running = True
        self._relay_addr = (host, port)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(0.1)
        # Register with relay
        self.sock.sendto(VOICE_MAGIC + b",JOIN,\n", self._relay_addr)
        self.send_thread = threading.Thread(target=self._capture_loop, args=(host, port), daemon=True)
        self.send_thread.start()
        self.thread = threading.Thread(target=self._receive_loop, args=(port,), daemon=True)
        self.thread.start()
        self.control_thread = threading.Thread(target=self._control_loop, daemon=True)
        self.control_thread.start()

    def stop(self):
        self.running = False
        try:
            if self.sock:
                self.sock.close()
        except Exception:
            pass
        try:
            if self.control_sock:
                self.control_sock.close()
        except Exception:
            pass

    def _control_loop(self):
        # Connects to the game's local OLTogetherVoiceListener and applies
        # POS,x,y / PTT,0|1 lines as they arrive. Reconnects on drop since the
        # game may not have spawned the listener yet when this starts, or the
        # player may reconnect to a different session.
        buffer = b""
        while self.running:
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(1.0)
                sock.connect((self.control_host, self.control_port))
                sock.settimeout(0.5)
                self.control_sock = sock
            except Exception:
                time.sleep(GAME_CONTROL_RETRY)
                continue
            try:
                while self.running:
                    try:
                        chunk = sock.recv(1024)
                    except socket.timeout:
                        continue
                    except Exception:
                        break
                    if not chunk:
                        break
                    buffer += chunk
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        self._apply_control_line(line.decode("utf-8", "ignore").strip())
            finally:
                try:
                    sock.close()
                except Exception:
                    pass
                self.control_sock = None
            if self.running:
                time.sleep(GAME_CONTROL_RETRY)

    def _apply_control_line(self, line: str):
        if not line:
            return
        parts = line.split(",")
        try:
            if parts[0] == "POS" and len(parts) >= 3:
                self.x = float(parts[1])
                self.y = float(parts[2])
                if len(parts) >= 4:
                    self.z = float(parts[3])
                if len(parts) >= 5:
                    # yaw_deg from UE3 (0=East, increases CCW). Convert to
                    # standard math radians so trig works consistently.
                    self.yaw = math.radians(float(parts[4]))
            elif parts[0] == "PTT" and len(parts) >= 2:
                self.ptt = parts[1] == "1"
            elif parts[0] == "PROX" and len(parts) >= 3:
                self.prox_near = float(parts[1])
                self.prox_far = float(parts[2])
        except Exception:
            pass

    def _resolve_input_device(self, sd):
        # Map the user-facing mic name (as shown in the launcher dropdown)
        # back to a sounddevice index. Falls back to system default if the
        # label doesn't match or the device can't be opened.
        if not self.mic_device or self.mic_device == "Default":
            return None
        label = self.mic_device.replace(" [Default]", "").strip()
        try:
            for idx, dev in enumerate(sd.query_devices()):
                if dev.get("max_input_channels", 0) <= 0:
                    continue
                if dev.get("name", "").strip() == label:
                    return idx
        except Exception:
            pass
        return None

    def _capture_loop(self, host: str, port: int):
        try:
            import sounddevice as sd
        except Exception as exc:
            VOICE_LOG.warning("Voice capture disabled (sounddevice unavailable): %s", exc)
            return
        try:
            device = self._resolve_input_device(sd)
            stream = sd.InputStream(device=device, channels=1, samplerate=VOICE_SAMPLE_RATE,
                                    blocksize=VOICE_FRAME_SAMPLES, dtype="int16")
            stream.start()
            VOICE_LOG.info("Voice mic streaming to %s:%s (device=%s)", host, port,
                           self.mic_device or "Default")
            try:
                import numpy as np
                while self.running:
                    if not self.ptt:
                        time.sleep(0.02)
                        continue
                    data, _ = stream.read(VOICE_FRAME_SAMPLES)
                    pcm_f = data.astype(np.float32) / 32768.0
                    vs = self.voice_settings
                    pcm_f *= vs.input_gain
                    rms = float(np.sqrt(np.mean(pcm_f ** 2)))
                    if rms < vs.noise_gate:
                        continue
                    np.clip(pcm_f, -1.0, 1.0, out=pcm_f)
                    pcm = (pcm_f * 32767.0).astype(np.int16).tobytes()
                    # OLTV2: include full 3D position + yaw so relay forwards it
                    header = VOICE_PACKET_HEADER.pack(
                        VOICE_MAGIC, self.client_id,
                        self.x, self.y, self.z, self.yaw,
                        len(pcm)
                    )
                    try:
                        self.sock.sendto(header + pcm, (host, port))
                    except Exception as send_exc:
                        VOICE_LOG.warning("Voice send failed: %s", send_exc)
                        break
            finally:
                stream.stop()
                stream.close()
        except Exception as exc:
            VOICE_LOG.warning("Voice capture error: %s", exc)

    def _receive_loop(self, port: int):
        # A listener who isn't transmitting (mic muted, or PTT not held)
        # sends nothing after the initial JOIN, so the relay's 5s idle
        # expiry would otherwise drop it from the roster and it would stop
        # receiving anyone else's audio too. Re-send JOIN periodically to
        # stay registered even while silent.
        join_packet = VOICE_MAGIC + b",JOIN,\n"
        last_keepalive = _now()
        try:
            while self.running:
                try:
                    data, _ = self.sock.recvfrom(VOICE_MAX_PACKET)
                except socket.timeout:
                    now = _now()
                    if now - last_keepalive > 3.0:
                        try:
                            self.sock.sendto(join_packet, self._relay_addr)
                        except Exception:
                            pass
                        last_keepalive = now
                    continue
                except Exception:
                    if self.running:
                        continue
                    break
                self._play_audio(data)
        except Exception:
            pass

    def _play_audio(self, data: bytes):
        """3D spatial audio playback.

        Computes distance attenuation (inverse-square between prox_near and
        prox_far) and horizontal stereo panning based on the angle between the
        listener's facing direction and the vector to the speaker.
        Output is stereo so headphones and speakers both benefit.
        """
        if not (data.startswith(VOICE_MAGIC) or data.startswith(VOICE_MAGIC_V1)):
            return
        if len(data) < VOICE_PACKET_HEADER.size:
            return
        try:
            magic, client_id, sx, sy, sz, syaw, pcm_len = VOICE_PACKET_HEADER.unpack_from(data)
            pcm = data[VOICE_PACKET_HEADER.size:VOICE_PACKET_HEADER.size + pcm_len]
            if pcm_len == 0 or len(pcm) < pcm_len:
                return
            import sounddevice as sd
            import numpy as np

            mono = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0

            # --- Distance attenuation (inverse-square law) ---
            dx = sx - self.x
            dy = sy - self.y
            dz = sz - self.z
            dist3d = math.sqrt(dx*dx + dy*dy + dz*dz)

            near = max(1.0, self.prox_near)
            far  = max(near + 1.0, self.prox_far)

            if dist3d >= far:
                return  # out of range, silence
            if dist3d <= near:
                gain = 1.0
            else:
                # smooth inverse-square between near and far
                t = (dist3d - near) / (far - near)  # 0..1
                gain = (1.0 - t) ** 2

            if gain <= 0.005:
                return

            gain *= self.voice_settings.output_volume

            # --- 3D Stereo panning (listener-relative horizontal angle) ---
            # listener_yaw: our camera yaw in radians (UE3 convention)
            # speaker is at angle theta relative to listener forward
            horiz_dist = math.sqrt(dx*dx + dy*dy)
            if horiz_dist > 0.1:
                # world angle from listener to speaker
                angle_to_speaker = math.atan2(dy, dx)  # world-space
                # relative angle: subtract listener yaw
                rel_angle = angle_to_speaker - self.yaw
                # normalise to -pi .. +pi
                rel_angle = (rel_angle + math.pi) % (2 * math.pi) - math.pi
                # pan: +1.0 = full right, -1.0 = full left
                pan = math.sin(rel_angle)  # smooth -1..+1
            else:
                pan = 0.0  # speaker directly above/below: centred

            # Elevation: sounds above/below lose high-freq shimmer
            # Simulate with subtle gain reduction for large elevation diff
            elev_factor = 1.0
            if horiz_dist > 0.1:
                elev_angle = math.atan2(abs(dz), horiz_dist)  # 0..pi/2
                elev_factor = 1.0 - 0.35 * (elev_angle / (math.pi / 2))

            gain *= elev_factor

            # Constant-power panning (keeps perceived loudness even)
            pan_rad = pan * (math.pi / 4)  # map -1..1 -> -45..+45 deg
            l_gain = gain * math.cos(pan_rad + math.pi / 4)
            r_gain = gain * math.sin(pan_rad + math.pi / 4)

            # Build stereo frame
            stereo = np.empty((len(mono), 2), dtype=np.float32)
            stereo[:, 0] = mono * l_gain
            stereo[:, 1] = mono * r_gain
            np.clip(stereo, -1.0, 1.0, out=stereo)

            sd.play(stereo, samplerate=VOICE_SAMPLE_RATE, blocking=False)
        except Exception as exc:
            VOICE_LOG.debug("Voice playback error: %s", exc)


def _safe_int(value, default):
    try:
        return int(value)
    except Exception:
        return default


GAME_REQUIRED_DIRS = ("Binaries", "Engine", "OLGame")


def _validate_game_folder(folder):
    """Check a selected game folder has the expected layout.

    Returns (ok, missing_dirs). ok is True only when all of Binaries, Engine
    and OLGame exist directly inside the folder.
    """
    if not folder or not os.path.isdir(folder):
        return False, list(GAME_REQUIRED_DIRS)
    missing = [d for d in GAME_REQUIRED_DIRS
               if not os.path.isdir(os.path.join(folder, d))]
    return (len(missing) == 0), missing


def _resolve_game_exe(folder, arch="Win64"):
    """Resolve OLGame.exe inside a validated game folder for the given arch.

    arch is "Win64" or "Win32". Returns the exe path if found, else None.
    Falls back to the other arch's folder if the preferred one lacks the exe.
    """
    ok, _ = _validate_game_folder(folder)
    if not ok:
        return None
    order = ["Win64", "Win32"]
    if arch in order:
        order.remove(arch)
        order.insert(0, arch)
    for a in order:
        candidate = os.path.join(folder, "Binaries", a, "OLGame.exe")
        if os.path.isfile(candidate):
            return candidate
    return None


def _auto_detect_game_folder():
    """Return the game folder if the script/exe sits inside or next to it.

    Checks, in order:
      1. The directory containing the script/exe.
      2. Its parent directory.
    Returns the first one that passes _validate_game_folder, or "" on failure.
    No exceptions are raised.
    """
    try:
        exe_dir = os.path.dirname(os.path.abspath(
            sys.executable if getattr(sys, "frozen", False) else __file__
        ))
        candidates = [exe_dir, os.path.dirname(exe_dir)]
        for folder in candidates:
            ok, _ = _validate_game_folder(folder)
            if ok:
                return folder
    except Exception:
        pass
    return ""


def _sha256(text):
    return hashlib.sha256(text.encode("utf-8", "ignore")).hexdigest()


def _generate_room_code():
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    return "".join(random.choice(alphabet) for _ in range(6))


def _detect_region():
    try:
        offset = -time.timezone // 3600
    except Exception:
        return "Auto"
    table = [
        (-9, -7, "NA-West"),
        (-7, -4, "NA-Central"),
        (-4, -2, "NA-East"),
        (-2, 0, "SA"),
        (0, 3, "EU-West"),
        (3, 5, "EU-East"),
        (5, 8, "ME/CA"),
        (8, 10, "Asia"),
        (10, 13, "Oceania"),
    ]
    for low, high, name in table:
        if low <= offset < high:
            return name
    return "Auto"


def _enable_alt_tab(hwnd):
    try:
        user32 = ctypes.windll.user32
        GWL_EXSTYLE = -20
        WS_EX_APPWINDOW = 0x00040000
        WS_EX_TOOLWINDOW = 0x00000080
        # winfo_id() gives the child frame; the real top-level owner is its parent.
        parent = user32.GetParent(hwnd)
        target = parent if parent else hwnd
        style = user32.GetWindowLongW(target, GWL_EXSTYLE)
        style = (style | WS_EX_APPWINDOW) & ~WS_EX_TOOLWINDOW
        user32.SetWindowLongW(target, GWL_EXSTYLE, style)
    except Exception:
        pass


def _detect_local_host():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            ip = s.getsockname()[0]
            if ip and not ip.startswith(("127.", "169.254.")):
                return ip
    except Exception:
        pass
    try:
        for entry in socket.gethostbyname_ex(socket.gethostname())[2]:
            if entry and not entry.startswith(("127.", "169.254.")):
                return entry
    except Exception:
        pass
    return "127.0.0.1"


def _measure_relay_ping(host, port):
    try:
        with socket.create_connection((host, port), timeout=PING_REPLY_TIMEOUT) as s:
            start = time.perf_counter()
            s.sendall(b"PING,0\n")
            data = b""
            deadline = time.perf_counter() + PING_REPLY_TIMEOUT
            while time.perf_counter() < deadline and b"\n" not in data:
                chunk = s.recv(1024)
                if not chunk:
                    break
                data += chunk
            return int((time.perf_counter() - start) * 1000)
    except Exception:
        return 9999


def _parse_room_payload(fields):
    if len(fields) < 13:
        return None
    try:
        limit = int(fields[4])
        count = int(fields[3])
        room = {
            "name": fields[1],
            "region": fields[2],
            "players": count,
            "limit": limit,
            "unlimited": fields[5] == "1",
            "public": fields[6] == "1",
            "allow_chat": fields[7] == "1",
            "password": fields[8] == "1",
            "code": fields[9],
            "host": fields[10],
            "port": int(fields[11]),
            "speedrun_mode": fields[12] == "1",
            "ping": 0,
            "player_display": f"{count}/{limit}" if limit else f"{count}/\u221e",
        }
        return room
    except Exception:
        return None


def _room_matches_query(room, query):
    query = query.lower()
    if not query:
        return True
    return any(query in str(room.get(f, "")).lower() for f in ("name", "region", "code"))


def _room_matches_filters(room, region, room_type, players):
    if region != "All" and room.get("region", "") != region:
        return False
    speedrun = room.get("speedrun_mode", False)
    if room_type == "Freeroam" and speedrun:
        return False
    if room_type == "Speedrun" and not speedrun:
        return False
    limit = int(room.get("limit", 0))
    count = int(room.get("players", 0))
    if players == "Open" and limit and count >= limit:
        return False
    if players == "Nearly Full" and limit and count < max(0, limit - 1):
        return False
    if players == "Full" and (not limit or count < limit):
        return False
    return True


def _sorted_rooms(rooms, sort_key, query, region, room_type, players):
    visible = [r for r in rooms if _room_matches_query(r, query) and _room_matches_filters(r, region, room_type, players)]
    if sort_key == "Name":
        visible.sort(key=lambda r: r.get("name", ""))
    elif sort_key == "Region":
        visible.sort(key=lambda r: r.get("region", ""))
    elif sort_key == "Players":
        visible.sort(key=lambda r: (r.get("limit", 0) or 99999, r.get("players", 0)))
    else:
        visible.sort(key=lambda r: r.get("ping", 9999))
    return visible


def _room_to_row(room):
    return (
        room.get("name", ""),
        room.get("region", ""),
        room.get("player_display", f"{room.get('players', 0)}/{room.get('limit', 0) or '\u221e'}"),
        str(room.get("ping", 0)),
        "Speedrun" if room.get("speedrun_mode", False) else "Freeroam",
        room.get("code", "") or "\u2014",
        "On" if room.get("allow_chat", True) else "Off",
    )


@dataclass
class RoomConfig:
    room_name: str = "OLTogether Room"
    region: str = "Auto"
    player_limit: int = 8
    unlimited: bool = False
    allow_chat: bool = True
    public_room: bool = True
    room_code: str = ""
    password: str = ""
    speedrun_mode: bool = False

    def to_dict(self):
        return {
            "room_name": self.room_name,
            "region": self.region,
            "player_limit": self.player_limit,
            "unlimited": self.unlimited,
            "allow_chat": self.allow_chat,
            "public_room": self.public_room,
            "room_code": self.room_code,
            "password": self.password,
            "speedrun_mode": self.speedrun_mode,
        }

    @classmethod
    def from_dict(cls, data):
        return cls(
            room_name=str(data.get("room_name", "OLTogether Room")),
            region=str(data.get("region", "Auto")),
            player_limit=_safe_int(str(data.get("player_limit", 8)), 8),
            unlimited=bool(data.get("unlimited", False)),
            allow_chat=bool(data.get("allow_chat", True)),
            public_room=bool(data.get("public_room", True)),
            room_code=str(data.get("room_code", "")),
            password=str(data.get("password", "")),
            speedrun_mode=bool(data.get("speedrun_mode", False)),
        )


@dataclass
class Client:
    cid: int
    writer: asyncio.StreamWriter
    address: str
    name: str = ""
    connected_at: float = field(default_factory=_now)
    last_seen: float = field(default_factory=_now)
    rx_bytes: int = 0
    tx_bytes: int = 0
    rx_msgs: int = 0
    tx_msgs: int = 0
    dropped: int = 0
    outbox: deque = field(default_factory=deque)
    wake: Optional[asyncio.Event] = None
    writer_task: Optional[asyncio.Task] = None
    closing: bool = False
    authed: bool = False
    pos_x: float = 0.0
    pos_y: float = 0.0

    @property
    def label(self):
        return self.name or f"Player{self.cid}"

    @property
    def uptime(self):
        return _now() - self.connected_at


def _make_room(outbox):
    for i, item in enumerate(outbox):
        if not item.startswith(CRITICAL_PREFIXES):
            del outbox[i]
            return
    if outbox:
        outbox.popleft()


class LANDiscoveryResponder:
    def __init__(self, app):
        self.app = app
        self.sock = None
        self.thread = None
        self.running = False

    def start(self):
        if self.running:
            return
        self.running = True
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()

    def stop(self):
        self.running = False
        try:
            if self.sock:
                self.sock.close()
        except Exception:
            pass

    def _loop(self):
        try:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            except Exception:
                pass
            self.sock.bind(("", DISCOVERY_PORT))
            while self.running:
                try:
                    data, addr = self.sock.recvfrom(1024)
                    if data.startswith(DISCOVERY_MAGIC):
                        self.sock.sendto(self.app.discovery_payload().encode("utf-8"), addr)
                except Exception:
                    if self.running:
                        continue
        finally:
            try:
                if self.sock:
                    self.sock.close()
            except Exception:
                pass


class LANDiscoveryBrowser:
    def __init__(self, app):
        self.app = app
        self.sock = None
        self.thread = None
        self.running = False
        self.found = {}
        self.lock = threading.Lock()

    def start(self):
        if self.running:
            return
        self.running = True
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()

    def stop(self):
        self.running = False
        try:
            if self.sock:
                self.sock.close()
        except Exception:
            pass

    def get_rooms(self):
        with self.lock:
            rooms = list(self.found.values())
        now = _now()
        rooms = [r for r in rooms if now - r.get("_seen", 0) < 12.0]
        with self.lock:
            stale = [k for k, v in self.found.items() if now - v.get("_seen", 0) >= 12.0]
            for k in stale:
                self.found.pop(k, None)
        return rooms

    def _loop(self):
        try:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            except Exception:
                pass
            self.sock.bind(("", 0))
            self.sock.settimeout(0.1)
            probe = DISCOVERY_MAGIC + b",QUERY"
            while self.running:
                for _ in range(LAN_BROADCAST_COUNT):
                    try:
                        self.sock.sendto(probe, ("255.255.255.255", DISCOVERY_PORT))
                    except Exception:
                        pass
                deadline = _now() + LAN_BROADCAST_INTERVAL
                while self.running and _now() < deadline:
                    try:
                        data, addr = self.sock.recvfrom(1024)
                    except socket.timeout:
                        continue
                    except Exception:
                        break
                    self._handle(data, addr)
        finally:
            try:
                if self.sock:
                    self.sock.close()
            except Exception:
                pass

    def _handle(self, data, addr):
        if not data.startswith(DISCOVERY_MAGIC):
            return
        fields = data.decode("utf-8", "ignore").split(",")
        if len(fields) < 2 or fields[1] == "QUERY":
            return
        room = _parse_room_payload(fields)
        if not room:
            return
        host = str(room.get("host", ""))
        port = int(room.get("port", RELAY_PORT))
        if not host:
            return
        room["_host_tuple"] = (host, port)
        room["_seen"] = _now()
        threading.Thread(target=self._measure, args=(room, host, port), daemon=True).start()
        with self.lock:
            self.found[(host, port)] = room
        try:
            self.app.after(0, self.app._refresh_browser)
        except Exception:
            pass

    def _measure(self, room, host, port):
        room["ping"] = _measure_relay_ping(host, port)


# ---------------------------------------------------------------------------
# Master-server client
# ---------------------------------------------------------------------------

class MasterServerClient:
    """Connects to a VPS master server to register/list rooms.

    Protocol (line-based, UTF-8):
      REGISTER,<payload>  - register a room (same CSV as LAN discovery)
      UNREGISTER          - remove a room registered from this IP:port
      LIST                - request all rooms; server replies with ROOM,... lines then END
    """

    def __init__(self, host: str, port: int = MASTER_SERVER_PORT):
        self.host = host
        self.port = port
        self._hb_thread: Optional[threading.Thread] = None
        self._stop_evt = threading.Event()
        self._payload: Optional[str] = None  # current hosted room payload

    # ---- public API ----

    def start_heartbeat(self, payload_fn: Callable[[], str]):
        """Begin periodically re-registering the room."""
        self._stop_evt.clear()
        self._payload_fn = payload_fn
        self._hb_thread = threading.Thread(target=self._hb_loop, daemon=True)
        self._hb_thread.start()

    def stop_heartbeat(self):
        """Stop heartbeat and send UNREGISTER."""
        self._stop_evt.set()
        try:
            self._send_line("UNREGISTER")
        except Exception:
            pass

    def list_rooms(self) -> list:
        """Fetch room list from master server. Returns list of room dicts."""
        rooms = []
        try:
            with socket.create_connection((self.host, self.port), timeout=MASTER_SERVER_TIMEOUT) as s:
                s.sendall(b"LIST\n")
                s.settimeout(MASTER_SERVER_TIMEOUT)
                buf = b""
                while True:
                    chunk = s.recv(4096)
                    if not chunk:
                        break
                    buf += chunk
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        txt = line.decode("utf-8", "ignore").strip()
                        if txt == "END":
                            return rooms
                        if txt.startswith("OLTG1,ROOM,"):
                            fields = txt.split(",")
                            room = _parse_room_payload(fields[1:])  # strip leading OLTG1
                            if room:
                                rooms.append(room)
        except Exception:
            pass
        return rooms

    # ---- internals ----

    def _hb_loop(self):
        while not self._stop_evt.is_set():
            try:
                payload = self._payload_fn()
                self._send_line(f"REGISTER,{payload}")
            except Exception:
                pass
            self._stop_evt.wait(MASTER_SERVER_HEARTBEAT)

    def _send_line(self, line: str):
        with socket.create_connection((self.host, self.port), timeout=MASTER_SERVER_TIMEOUT) as s:
            s.sendall((line.rstrip("\n") + "\n").encode("utf-8"))


async def _run_tcp_bridge(app, host, port, room):
    loop = asyncio.get_event_loop()
    clients = {}
    counters = {"next_id": 1, "connections": 0, "relayed": 0}
    started_at = _now()
    shutdown_future = loop.create_future()
    app._bridge_loop = loop
    app._bridge_shutdown = shutdown_future
    app._bridge_clients = clients

    def voice_position_lookup(ip):
        # Resolve a voice peer's authoritative in-game position from the TCP
        # roster by matching on source IP. The last-updated client wins when a
        # single IP hosts multiple clients (e.g. loopback testing).
        match = None
        for c in clients.values():
            if c.closing:
                continue
            if c.address.rsplit(":", 1)[0] == ip:
                match = c
        if match is None:
            return None
        return (match.pos_x, match.pos_y)

    app._voice_position_lookup = voice_position_lookup

    def wake(client):
        if client.wake is not None and not client.wake.is_set():
            client.wake.set()

    def enqueue(client, data):
        if client.closing:
            return
        if len(client.outbox) >= CLIENT_QUEUE_LIMIT:
            _make_room(client.outbox)
            client.dropped += 1
        client.outbox.append(data)
        wake(client)

    def broadcast(line, exclude=None):
        exclude_cid = exclude.cid if exclude else None
        counters["relayed"] += 1
        for client in clients.values():
            if client.cid == exclude_cid or client.closing:
                continue
            if exclude_cid is not None:
                data = f"FROM,{exclude_cid},{line.rstrip(chr(10))}\n".encode("utf-8")
            else:
                data = (line.rstrip("\n") + "\n").encode("utf-8")
            enqueue(client, data)

    def send_to(client, line):
        enqueue(client, (line.rstrip("\n") + "\n").encode("utf-8"))

    def refresh_roster():
        snapshot = []
        for c in sorted(clients.values(), key=lambda x: x.cid):
            snapshot.append({"name": c.label, "address": c.address, "uptime": c.uptime, "rx": c.rx_msgs, "dropped": c.dropped})
        app.refresh_clients(snapshot)
        app.set_server_info(len(clients), counters["connections"], counters["relayed"], started_at)

    async def handle(reader, writer):
        peer = writer.get_extra_info("peername")
        address = f"{peer[0]}:{peer[1]}" if peer else "unknown"
        client = Client(cid=counters["next_id"], writer=writer, address=address)
        counters["next_id"] += 1
        client.wake = asyncio.Event()
        counters["connections"] += 1
        if not room.unlimited and len(clients) >= room.player_limit:
            enqueue(client, b"NOTIF,Room is full.\n")
            wake(client)
            await asyncio.sleep(0.1)
            client.closing = True
            try:
                writer.close()
            except Exception:
                pass
            return
        clients[client.cid] = client
        client.writer_task = loop.create_task(client_writer(client))
        app.log(f"Connected: {address} (assigned {client.label})")
        send_to(client, f"YOUR_CID,{client.cid}")
        refresh_roster()
        buffer = b""
        try:
            while True:
                chunk = await reader.read(READ_CHUNK)
                if not chunk:
                    break
                client.rx_bytes += len(chunk)
                client.last_seen = _now()
                buffer += chunk
                if len(buffer) > MAX_LINE_BYTES * 4:
                    buffer = buffer[-MAX_LINE_BYTES:]
                while b"\n" in buffer:
                    raw, buffer = buffer.split(b"\n", 1)
                    line = raw.decode("utf-8", "ignore").strip("\r").strip()
                    if line:
                        client.rx_msgs += 1
                        await process_line(line, client)
        except (ConnectionResetError, asyncio.IncompleteReadError):
            pass
        finally:
            await disconnect(client)

    async def client_writer(client):
        assert client.wake is not None
        try:
            while True:
                if not client.outbox:
                    if client.closing:
                        break
                    await client.wake.wait()
                    client.wake.clear()
                    continue
                data = client.outbox.popleft()
                client.writer.write(data)
                client.tx_bytes += len(data)
                client.tx_msgs += 1
                if not client.outbox:
                    await client.writer.drain()
        except Exception:
            pass

    async def disconnect(client):
        if client.cid not in clients:
            return
        clients.pop(client.cid, None)
        client.closing = True
        wake(client)
        if client.writer_task:
            client.writer_task.cancel()
        try:
            client.writer.close()
            await client.writer.wait_closed()
        except Exception:
            pass
        broadcast(f"LEFT,{client.cid}")
        broadcast(f"NOTIF,{client.label} left the room.")
        refresh_roster()

    async def process_line(line, client):
        if line.startswith("AUTH,"):
            parts = line.split(",", 2)
            token = parts[1] if len(parts) > 1 else ""
            if room.password and token != _sha256(room.password):
                send_to(client, "AUTH,FAIL")
                client.closing = True
                try:
                    client.writer.close()
                except Exception:
                    pass
                return
            client.authed = True
            send_to(client, "AUTH,OK")
            return
        if room.password and not client.authed and line.startswith(("LOC,", "CHAT,", "NAME,", "SMOVE,")):
            send_to(client, "AUTH,REQUIRED")
            return
        if line.startswith("NAME,"):
            new_name = line[5:].strip() or client.label
            old = client.label
            client.name = new_name
            broadcast(f"NAME,{new_name}", exclude=client)
            if old != new_name:
                broadcast(f"NOTIF,{new_name} joined the room.", exclude=client)
            refresh_roster()
            return
        if line.startswith("PING,"):
            send_to(client, "PONG," + line[5:])
            return
        if line.startswith("PONG,"):
            return
        if line.startswith("CHAT,"):
            if room.allow_chat:
                broadcast(line, exclude=client)
            return
        if line.startswith("LOC,"):
            fields = line.split(",")
            if len(fields) >= 3:
                try:
                    client.pos_x = float(fields[1])
                    client.pos_y = float(fields[2])
                except Exception:
                    pass
        broadcast(line, exclude=client)

    async def idle_monitor():
        try:
            while True:
                await asyncio.sleep(IDLE_CHECK_INTERVAL)
                now = _now()
                stale = [c for c in clients.values() if not c.closing and now - c.last_seen > CLIENT_TIMEOUT]
                for client in stale:
                    client.closing = True
                    wake(client)
                    try:
                        client.writer.close()
                    except Exception:
                        pass
        except asyncio.CancelledError:
            pass

    try:
        server = await asyncio.start_server(handle, host, port, limit=MAX_LINE_BYTES)
    except Exception as exc:
        app.log(f"Failed to start server: {exc}")
        app.set_server_state(False)
        return

    sock = server.sockets[0].getsockname()
    app.log(f"Listening on {sock[0]}:{sock[1]}")
    app.set_server_state(True)
    refresh_roster()
    app.start_discovery_responder()
    idle_task = loop.create_task(idle_monitor())
    try:
        async with server:
            await shutdown_future
    finally:
        idle_task.cancel()
        server.close()
        await server.wait_closed()
        for client in list(clients.values()):
            client.closing = True
            wake(client)
            try:
                client.writer.close()
            except Exception:
                pass
        for client in list(clients.values()):
            try:
                await client.writer.wait_closed()
            except Exception:
                pass
        clients.clear()
        app.stop_discovery_responder()
        app.set_server_state(False)
        app.set_server_info(0, counters["connections"], counters["relayed"], started_at)
        app.log("Server stopped.")
        app._bridge_loop = None
        app._bridge_shutdown = None
        app._bridge_clients = None


class OLTogetherApp(tk.Tk):
    # ---- Neon palette ----
    BG = "#0a0e14"
    PANEL = "#111820"
    CARD = "#151c25"
    CYAN = "#00f0ff"
    MAGENTA = "#ff00c8"
    BLUE = "#3a7aff"
    GREEN = "#00ff88"
    RED = "#ff3355"
    YELLOW = "#ffe033"
    TEXT = "#e0e6f0"
    DIM = "#5a6577"
    BORDER = "#1e2a38"
    INPUT_BG = "#0d1219"

    def __init__(self):
        super().__init__()
        _init_font()
        host = ""
        port = RELAY_PORT
        self.overrideredirect(True)
        # Start fully transparent so the boot fade-in is smooth.
        try:
            self.attributes("-alpha", 0.0)
        except Exception:
            pass
        self.minsize(1140, 780)
        self.configure(bg=self.BG)
        _set_app_icon(self)
        self._closing = False
        self._save_after_id = None
        self._drag_data = {"x": 0, "y": 0}
        self._pulse_phase = 0.0
        self._glow_widgets = []
        self._animating_window = False
        self._window_anim_job = None
        self._boot_anim_name = None
        self._close_anim_name = None
        self._anim_frame_ms = self._detect_frame_interval_ms()
        self.host_var = tk.StringVar(value=host)
        self.port_var = tk.StringVar(value=str(port))
        self.name_var = tk.StringVar(value="Player")
        self.room_name_var = tk.StringVar(value="OLTogether Room")
        self.region_var = tk.StringVar(value=_detect_region())
        self.player_limit_var = tk.StringVar(value="8")
        self._auto_region = self.region_var.get()
        self.unlimited_var = tk.BooleanVar(value=False)
        self.allow_chat_var = tk.BooleanVar(value=True)
        self.public_room_var = tk.BooleanVar(value=True)
        self.password_var = tk.StringVar(value="")
        self.room_code_var = tk.StringVar(value=_generate_room_code())
        self.speedrun_mode_var = tk.BooleanVar(value=False)
        self.check_updates_var = tk.BooleanVar(value=True)
        self._dismissed_update_version = ""
        self.game_path_var = tk.StringVar(value="")
        self.game_arch_var = tk.StringVar(value="Win64")
        self.game_extra_args_var = tk.StringVar(value="")
        self.status_var = tk.StringVar(value="OFFLINE")
        self.stats_var = tk.StringVar(value="")
        self.search_var = tk.StringVar(value="")
        self.sort_var = tk.StringVar(value="Ping")
        self.filter_region_var = tk.StringVar(value="All")
        self.filter_type_var = tk.StringVar(value="All")
        self.filter_players_var = tk.StringVar(value="All")
        self.theme_var = tk.StringVar(value="Cyan")
        self.theme_dark_var = tk.BooleanVar(value=True)
        self.mic_var = tk.StringVar(value="Default")
        self.voice_input_gain_var = tk.DoubleVar(value=1.0)
        self.voice_noise_gate_var = tk.DoubleVar(value=0.02)
        self.voice_output_volume_var = tk.DoubleVar(value=1.0)
        self._mic_meter = None
        self._mic_monitor = None
        self.server_running = False
        self._bridge_loop = None
        self._bridge_shutdown = None
        self._bridge_clients = None
        self._voice_relay = None
        self._voice_thread = None
        self._voice_position_lookup = None
        self._voice_client = None
        self.room = RoomConfig()
        self.responder = LANDiscoveryResponder(self)
        self.browser = LANDiscoveryBrowser(self)
        self.config_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "server_config.json")
        # Master servers: list of dicts {name, host, port, enabled}
        self.master_servers: list = [
            {"name": "Official VPS", "host": "74.81.32.241", "port": MASTER_SERVER_PORT, "enabled": True}
        ]
        self._master_clients: list = []  # active MasterServerClient instances while hosting
        self._build_ui()
        self._load_settings()
        self._auto_detect_game_folder_if_needed()
        if not self.room_code_var.get().strip():
            self.room_code_var.set(_generate_room_code())
        if not self.region_var.get().strip() or self.region_var.get().strip() == "Auto":
            self.region_var.set(_detect_region())
        self.browser.start()
        self._setup_autosave()
        self.protocol("WM_DELETE_WINDOW", self._on_close)
        self.after(100, self._pulse_tick)
        self.after(500, self._tick_stats)
        self.after(1000, self._refresh_browser)
        self.after(2000, self._check_for_updates)
        self._boot_slide_in()

    def _build_ui(self):
        self._configure_styles()
        outer = tk.Frame(self, bg=self.CYAN)
        outer.pack(fill="both", expand=True, padx=1, pady=1)
        inner = tk.Frame(outer, bg=self.BG)
        inner.pack(fill="both", expand=True, padx=1, pady=1)
        self._root_frame = inner

        self._build_title_bar(inner)
        body = tk.Frame(inner, bg=self.BG)
        body.pack(fill="both", expand=True, padx=14, pady=(0, 14))

        paned = tk.PanedWindow(body, orient="horizontal", bg=self.BG, sashwidth=4, sashrelief="flat", bd=0)
        paned.pack(fill="both", expand=True)

        left = tk.Frame(paned, bg=self.BG)
        right = tk.Frame(paned, bg=self.BG)
        paned.add(left, minsize=340, width=420)
        paned.add(right, minsize=500, width=720)

        self._build_host_card(left)
        self._build_join_card(right)
        self._build_footer(body)

    def _configure_styles(self):
        s = ttk.Style(self)
        try:
            s.theme_use("clam")
        except Exception:
            pass
        s.configure("Neon.TEntry", fieldbackground=self.INPUT_BG, foreground=self.TEXT, insertcolor=self.CYAN, borderwidth=0, padding=6)
        s.configure("Treeview", background=self.PANEL, fieldbackground=self.PANEL, foreground=self.TEXT, rowheight=30, borderwidth=0)
        s.configure("Treeview.Heading", background=self.CARD, foreground=self.CYAN, borderwidth=0, relief="flat")
        s.map("Treeview", background=[("selected", "#1a2a3a")], foreground=[("selected", self.CYAN)])
        s.configure("TScrollbar", background=self.CARD, troughcolor=self.BG, borderwidth=0, arrowcolor=self.CYAN)

    def _build_title_bar(self, parent):
        bar = tk.Frame(parent, bg=self.PANEL, height=44)
        bar.pack(fill="x")
        bar.pack_propagate(False)
        bar.bind("<Button-1>", self._start_drag)
        bar.bind("<B1-Motion>", self._on_drag)
        title_frame = tk.Frame(bar, bg=self.PANEL)
        title_frame.pack(side="left", fill="y", padx=14)
        tk.Label(title_frame, text="OLTogether", font=(APP_FONT, 13, "bold"), bg=self.PANEL, fg=self.CYAN).pack(side="left")
        tk.Label(title_frame, text="  MULTIPLAYER", font=(APP_FONT, 9), bg=self.PANEL, fg=self.DIM).pack(side="left", padx=(4, 0))
        status_label = tk.Label(title_frame, textvariable=self.status_var, font=(APP_FONT, 9, "bold"), bg=self.PANEL, fg=self.GREEN)
        status_label.pack(side="left", padx=(16, 0))
        self._status_label = status_label
        btn_frame = tk.Frame(bar, bg=self.PANEL)
        btn_frame.pack(side="right", padx=8)
        self._make_title_btn(btn_frame, "\u2715", self._on_close, self.RED)
        self._make_title_btn(btn_frame, "\u2014", self._minimize, self.DIM)

    def _make_title_btn(self, parent, text, command, hover_color):
        btn = tk.Label(parent, text=text, font=(APP_FONT, 11, "bold"), bg=self.PANEL, fg=self.DIM, padx=12, pady=2, cursor="hand2")
        btn.pack(side="right", padx=2)
        btn.bind("<Enter>", lambda e, c=hover_color, l=btn: l.configure(fg=c))
        btn.bind("<Leave>", lambda e, l=btn: l.configure(fg=self.DIM))
        btn.bind("<Button-1>", lambda e, c=command: c())
        return btn

    def _start_drag(self, event):
        self._drag_data["x"] = event.x_root - self.winfo_x()
        self._drag_data["y"] = event.y_root - self.winfo_y()

    def _on_drag(self, event):
        self.geometry(f"+{event.x_root - self._drag_data['x']}+{event.y_root - self._drag_data['y']}")

    def _minimize(self):
        self.overrideredirect(False)
        self.after(50, lambda: self.iconify())
        self.after(400, self._restore_override)

    def _restore_override(self):
        def _do():
            if self.state() == "iconic":
                self.after(200, self._restore_override)
                return
            self.overrideredirect(True)
            self._apply_alt_tab_fix()
        self.after(100, _do)

    def _apply_alt_tab_fix(self):
        try:
            _enable_alt_tab(self.winfo_id())
        except Exception:
            pass

    def _window_size(self):
        # Cache the window's natural size (content-driven) so the animation
        # doesn't clip the footer by forcing a too-short height. Falls back to
        # the minsize if the layout hasn't been measured yet.
        cached = getattr(self, "_win_size", None)
        if cached:
            return cached
        try:
            self.update_idletasks()
            w = max(self.winfo_reqwidth(), self.winfo_width(), 1140)
            h = max(self.winfo_reqheight(), self.winfo_height(), 780)
        except Exception:
            w, h = 1140, 780
        self._win_size = (w, h)
        return self._win_size

    def _apply_window_geometry(self, x, y):
        w, h = self._window_size()
        try:
            self.geometry(f"{int(w)}x{int(h)}+{int(x)}+{int(y)}")
        except Exception:
            pass

    def _detect_frame_interval_ms(self):
        # Query the primary monitor's refresh rate so the animation redraw
        # cadence matches the display (e.g. ~6ms on 165Hz, ~16ms on 60Hz)
        # instead of a hard-coded 60fps. Falls back to 60Hz on any failure.
        hz = 60
        try:
            user32 = ctypes.windll.user32

            class DEVMODE(ctypes.Structure):
                _fields_ = [
                    ("dmDeviceName", ctypes.c_wchar * 32),
                    ("dmSpecVersion", ctypes.c_ushort),
                    ("dmDriverVersion", ctypes.c_ushort),
                    ("dmSize", ctypes.c_ushort),
                    ("dmDriverExtra", ctypes.c_ushort),
                    ("dmFields", ctypes.c_ulong),
                    ("dmPositionX", ctypes.c_long),
                    ("dmPositionY", ctypes.c_long),
                    ("dmDisplayOrientation", ctypes.c_ulong),
                    ("dmDisplayFixedOutput", ctypes.c_ulong),
                    ("dmColor", ctypes.c_short),
                    ("dmDuplex", ctypes.c_short),
                    ("dmYResolution", ctypes.c_short),
                    ("dmTTOption", ctypes.c_short),
                    ("dmCollate", ctypes.c_short),
                    ("dmFormName", ctypes.c_wchar * 32),
                    ("dmLogPixels", ctypes.c_ushort),
                    ("dmBitsPerPel", ctypes.c_ulong),
                    ("dmPelsWidth", ctypes.c_ulong),
                    ("dmPelsHeight", ctypes.c_ulong),
                    ("dmDisplayFlags", ctypes.c_ulong),
                    ("dmDisplayFrequency", ctypes.c_ulong),
                    ("dmICMMethod", ctypes.c_ulong),
                    ("dmICMIntent", ctypes.c_ulong),
                    ("dmMediaType", ctypes.c_ulong),
                    ("dmDitherType", ctypes.c_ulong),
                    ("dmReserved1", ctypes.c_ulong),
                    ("dmReserved2", ctypes.c_ulong),
                    ("dmPanningWidth", ctypes.c_ulong),
                    ("dmPanningHeight", ctypes.c_ulong),
                ]

            dm = DEVMODE()
            dm.dmSize = ctypes.sizeof(DEVMODE)
            ENUM_CURRENT_SETTINGS = -1
            if user32.EnumDisplaySettingsW(None, ENUM_CURRENT_SETTINGS, ctypes.byref(dm)):
                freq = int(dm.dmDisplayFrequency)
                # 0 or 1 means "hardware default"; ignore those.
                if freq > 1:
                    hz = freq
        except Exception:
            hz = 60
        hz = max(30, min(360, hz))
        return max(1, int(round(1000.0 / hz)))

    def _ease_out_cubic(self, t):
        t = max(0.0, min(1.0, t))
        return 1.0 - (1.0 - t) ** 3

    def _ease_out_quint(self, t):
        t = max(0.0, min(1.0, t))
        return 1.0 - (1.0 - t) ** 5

    def _window_center(self):
        sw = max(1, self.winfo_screenwidth())
        sh = max(1, self.winfo_screenheight())
        w, h = self._window_size()
        return (sw - w) / 2, (sh - h) / 2

    def _window_variants(self, mode):
        cx, cy = self._window_center()
        near = 180
        far = 360
        variants = [
            ("left_short", cx - near, cy),
            ("right_short", cx + near, cy),
            ("up_short", cx, cy - near),
            ("down_short", cx, cy + near),
            ("left_far", cx - far, cy),
            ("right_far", cx + far, cy),
            ("up_far", cx, cy - far),
            ("down_far", cx, cy + far),
            ("up_left", cx - near, cy - near),
            ("up_right", cx + near, cy - near),
            ("down_left", cx - near, cy + near),
            ("down_right", cx + near, cy + near),
            ("up_left_far", cx - far, cy - far),
            ("up_right_far", cx + far, cy - far),
            ("down_left_far", cx - far, cy + far),
            ("down_right_far", cx + far, cy + far),
        ]
        if mode == "boot":
            return [(name, sx, sy, cx, cy) for name, sx, sy in variants]
        return [(name, cx, cy, ex, ey) for name, ex, ey in variants]

    def _run_window_anim(self, mode="boot"):
        variants = self._window_variants(mode)
        easings = [self._ease_out_cubic, self._ease_out_quint]
        name, x0, y0, x1, y1 = random.choice(variants)
        ease = random.choice(easings)
        if mode == "boot":
            self._boot_anim_name = name
        else:
            self._close_anim_name = name
        self._animating_window = True
        start = time.perf_counter()
        duration = 0.42 if mode == "boot" else 0.30
        try:
            if mode == "boot":
                self._apply_window_geometry(x0, y0)
                self._apply_alt_tab_fix()
                self.deiconify()
        except Exception:
            pass

        def step():
            t = (time.perf_counter() - start) / duration
            if t >= 1.0:
                t = 1.0
            p = ease(t)
            x = x0 + (x1 - x0) * p
            y = y0 + (y1 - y0) * p
            self._apply_window_geometry(x, y)
            try:
                alpha = p if mode == "boot" else 1.0 - p
                self.attributes("-alpha", max(0.0, min(1.0, alpha)))
            except Exception:
                pass
            if t < 1.0:
                self._window_anim_job = self.after(self._anim_frame_ms, step)
                return
            self._animating_window = False
            self._window_anim_job = None
            if mode == "boot":
                try:
                    self.attributes("-alpha", 1.0)
                except Exception:
                    pass
                cx, cy = self._window_center()
                self._apply_window_geometry(cx, cy)
            else:
                self._destroy_safe()
        step()

    def _boot_slide_in(self):
        self._run_window_anim("boot")

    def _slide_out_and_close(self):
        if self._window_anim_job is not None:
            try:
                self.after_cancel(self._window_anim_job)
            except Exception:
                pass
            self._window_anim_job = None
        self._run_window_anim("close")

    def _destroy_safe(self):
        try:
            self.destroy()
        except Exception:
            pass

    def _pulse_widget(self, widget, base_bg, accent, steps=6, grow=0.18, delay=18):
        colors = []
        for i in range(steps):
            t = (i + 1) / steps
            colors.append(self._blend(base_bg, accent, grow * t))
        colors += list(reversed(colors[:-1]))

        def tick(idx=0):
            if idx >= len(colors):
                try:
                    widget.configure(bg=base_bg)
                except Exception:
                    pass
                return
            try:
                widget.configure(bg=colors[idx])
            except Exception:
                return
            self.after(delay, tick, idx + 1)
        tick()

    def _blend(self, c1, c2, t):
        try:
            r1, g1, b1 = int(c1[1:3], 16), int(c1[3:5], 16), int(c1[5:7], 16)
            r2, g2, b2 = int(c2[1:3], 16), int(c2[3:5], 16), int(c2[5:7], 16)
            r = int(r1 + (r2 - r1) * t)
            g = int(g1 + (g2 - g1) * t)
            b = int(b1 + (b2 - b1) * t)
            return f"#{r:02x}{g:02x}{b:02x}"
        except Exception:
            return c1

    def _neon_button(self, parent, text, command, color, **kw):
        frame = tk.Frame(parent, bg=self.BG)
        btn = tk.Label(frame, text=text, font=(APP_FONT, 9, "bold"), bg=self.CARD, fg=color, padx=14, pady=6, cursor="hand2", **kw)
        btn.pack(fill="x")
        btn.bind("<Enter>", lambda e: self._pulse_widget(btn, self.CARD, color, steps=5, grow=0.28, delay=16))
        btn.bind("<Leave>", lambda e: btn.configure(bg=self.CARD))
        btn.bind("<Button-1>", lambda e: command())
        frame._btn_label = btn
        return frame

    def _brighten(self, hex_color, amount):
        try:
            r = min(255, int(hex_color[1:3], 16) + int(255 * amount))
            g = min(255, int(hex_color[3:5], 16) + int(255 * amount))
            b = min(255, int(hex_color[5:7], 16) + int(255 * amount))
            return f"#{r:02x}{g:02x}{b:02x}"
        except Exception:
            return hex_color

    def _card(self, parent, title):
        wrapper = tk.Frame(parent, bg=self.BG, pady=6)
        wrapper.pack(fill="both", expand=True)
        header = tk.Label(wrapper, text=title, font=(APP_FONT, 11, "bold"), bg=self.BG, fg=self.CYAN, anchor="w")
        header.pack(fill="x", pady=(0, 6))
        body = tk.Frame(wrapper, bg=self.CARD, padx=12, pady=10)
        body.pack(fill="both", expand=True)
        return body

    def _field(self, parent, row, label, var):
        tk.Label(parent, text=label, font=(APP_FONT, 9), bg=self.CARD, fg=self.DIM, anchor="w").grid(row=row, column=0, sticky="w", pady=4, padx=(0, 8))
        entry = tk.Entry(parent, textvariable=var, bg=self.INPUT_BG, fg=self.TEXT, insertbackground=self.CYAN, font=(APP_FONT, 9), relief="flat", bd=0, highlightthickness=1, highlightbackground=self.BORDER, highlightcolor=self.CYAN)
        entry.grid(row=row, column=1, sticky="ew", pady=4, padx=(0, 4))
        entry.bind("<FocusIn>", lambda e: self._pulse_widget(entry, self.INPUT_BG, self.CYAN, steps=4, grow=0.12, delay=14))
        return entry

    def _checkbox(self, parent, row, col, text, var):
        cb = tk.Checkbutton(parent, text=text, variable=var, font=(APP_FONT, 9), bg=self.CARD, fg=self.TEXT, selectcolor=self.INPUT_BG, activebackground=self.CARD, activeforeground=self.CYAN, highlightthickness=0, bd=0)
        cb.grid(row=row, column=col, sticky="w", pady=2, padx=2)
        cb.bind("<Enter>", lambda e: self._pulse_widget(cb, self.CARD, self.CYAN, steps=4, grow=0.14, delay=18))
        cb.bind("<Leave>", lambda e: cb.configure(bg=self.CARD))
        cb.configure(command=lambda w=cb: self._pulse_widget(w, self.CARD, self.GREEN if var.get() else self.MAGENTA, steps=5, grow=0.2, delay=16))
        return cb

    def _build_host_card(self, parent):
        card = self._card(parent, "HOST")
        card.columnconfigure(1, weight=1)
        self._field(card, 0, "Room Name", self.room_name_var)
        self._field(card, 1, "Region", self.region_var)
        self._field(card, 2, "Player Limit", self.player_limit_var)
        self._checkbox(card, 3, 1, "Unlimited", self.unlimited_var)
        self._checkbox(card, 3, 2, "Allow Chat", self.allow_chat_var)
        self._checkbox(card, 3, 3, "Public", self.public_room_var)
        self._checkbox(card, 4, 1, "Speedrun Mode", self.speedrun_mode_var)
        self._checkbox(card, 4, 2, "Check Updates", self.check_updates_var)
        self._field(card, 5, "Room Code", self.room_code_var)
        self._field(card, 6, "Password", self.password_var)
        self._field(card, 7, "Host IP", self.host_var)
        self._field(card, 8, "Port", self.port_var)
        self._field(card, 9, "Game Folder", self.game_path_var)
        self._host_entry = card.grid_slaves(row=7, column=1)[0]
        self._host_entry.insert(0, "")
        self._host_entry.bind("<FocusIn>", self._reveal_host_ip)
        self._host_entry.bind("<Control-v>", self._reveal_host_ip)
        self._host_entry.bind("<Button-1>", self._reveal_host_ip)
        self._field(card, 11, "Player Name", self.name_var)
        extra_frame = tk.Frame(card, bg=self.CARD)
        extra_frame.grid(row=12, column=0, columnspan=4, sticky="ew", pady=(4, 0))
        extra_frame.columnconfigure(1, weight=1)
        tk.Label(extra_frame, text="Extra Launch Args", font=(APP_FONT, 9), bg=self.CARD,
                 fg=self.DIM, anchor="w").grid(row=0, column=0, sticky="w", padx=(0, 8))
        extra_entry = tk.Entry(extra_frame, textvariable=self.game_extra_args_var,
                               bg=self.INPUT_BG, fg=self.TEXT, insertbackground=self.CYAN,
                               font=(APP_FONT, 9), relief="flat", bd=0,
                               highlightthickness=1, highlightbackground=self.BORDER,
                               highlightcolor=self.CYAN)
        extra_entry.grid(row=0, column=1, sticky="ew")
        tk.Label(extra_frame, text="e.g. -dx11 -log ?Key=Val", font=(APP_FONT, 7),
                 bg=self.CARD, fg=self.DIM, anchor="w").grid(row=1, column=1, sticky="w")
        browse_row = tk.Frame(card, bg=self.CARD)
        browse_row.grid(row=13, column=0, columnspan=4, sticky="ew", pady=(6, 0))
        browse_row.columnconfigure(0, weight=1)
        browse = self._neon_button(browse_row, "Browse Folder...", self._browse_game, self.BLUE)
        browse.grid(row=0, column=0, sticky="ew")
        arch_frame = tk.Frame(browse_row, bg=self.CARD)
        arch_frame.grid(row=0, column=1, padx=(6, 0), sticky="e")
        tk.Label(arch_frame, text="Arch", font=(APP_FONT, 8), bg=self.CARD, fg=self.DIM).pack(side="left")
        # The arch_var stores the internal key ("Win64"/"Win32") used for exe
        # resolution; the OptionMenu maps to user-friendly labels ("64-bit",
        # "32-bit").  A reverse lookup translates the label back to the key.
        _ARCH_LABELS = {"Win64": "64-bit", "Win32": "32-bit"}
        _ARCH_KEYS  = {v: k for k, v in _ARCH_LABELS.items()}
        self._arch_labels = _ARCH_LABELS
        self._arch_keys  = _ARCH_KEYS
        _default_label = _ARCH_LABELS.get(self.game_arch_var.get(), "64-bit")
        arch_var_label = tk.StringVar(value=_default_label)
        self._arch_label_var = arch_var_label

        def _on_arch_change(_label):
            self.game_arch_var.set(_ARCH_KEYS.get(_label.get(), "Win64"))

        arch_var_label.trace_add("write", lambda *_: _on_arch_change(arch_var_label))
        arch_menu = tk.OptionMenu(arch_frame, arch_var_label, "64-bit", "32-bit")
        arch_menu.configure(bg=self.INPUT_BG, fg=self.TEXT, font=(APP_FONT, 9), highlightthickness=0, bd=0, activebackground=self.CYAN, activeforeground=self.BG)
        arch_menu["menu"].configure(bg=self.CARD, fg=self.TEXT, activebackground=self.CYAN, activeforeground=self.BG)
        arch_menu.pack(side="left", padx=(4, 0))
        self._game_status_label = tk.Label(card, text="", font=(APP_FONT, 8), bg=self.CARD, fg=self.DIM, anchor="w")
        self._game_status_label.grid(row=10, column=0, columnspan=4, sticky="ew")
        self.game_path_var.trace_add("write", lambda *_: self._update_game_status())
        self.game_arch_var.trace_add("write", lambda *_: self._update_game_status())
        tk.Label(card, text="Mic Device", font=(APP_FONT, 9), bg=card.cget("bg"), fg=self.DIM).grid(row=14, column=0, sticky="w", pady=(10, 4))
        mic_devices = _get_audio_devices()
        if self.mic_var.get() not in mic_devices:
            self.mic_var.set(mic_devices[0] if mic_devices else "Default")
        mic_main = tk.OptionMenu(card, self.mic_var, self.mic_var.get(), *mic_devices)
        mic_main.configure(bg=self.INPUT_BG, fg=self.TEXT, font=(APP_FONT, 9), highlightthickness=0, bd=0, activebackground=self.CYAN, activeforeground=self.BG)
        mic_main["menu"].configure(bg=self.CARD, fg=self.TEXT, activebackground=self.CYAN, activeforeground=self.BG)
        mic_main.grid(row=14, column=1, columnspan=3, sticky="ew", pady=(10, 4))
        self._mic_meter = MicMeter(card, bg=self.CARD)
        self._mic_meter.frame.grid(row=15, column=0, columnspan=4, sticky="ew", pady=(2, 4))
        self._mic_meter.set_color(self.GREEN)

        settings_row = tk.Frame(card, bg=self.CARD)
        settings_row.grid(row=16, column=0, columnspan=4, sticky="ew", pady=(0, 4))
        settings_row.columnconfigure(1, weight=1)
        tk.Label(settings_row, text="Input Gain", font=(APP_FONT, 8), bg=self.CARD, fg=self.DIM).grid(row=0, column=0, sticky="w")
        gain = tk.Scale(settings_row, from_=0.0, to=5.0, resolution=0.01, orient="horizontal", showvalue=True,
                        variable=self.voice_input_gain_var, bg=self.CARD, fg=self.TEXT, troughcolor=self.BG,
                        activebackground=self.GREEN, highlightthickness=0, borderwidth=0)
        gain.grid(row=0, column=1, sticky="ew", padx=(8, 0))
        tk.Label(settings_row, text="Noise Gate", font=(APP_FONT, 8), bg=self.CARD, fg=self.DIM).grid(row=1, column=0, sticky="w", pady=(6, 0))
        gate = tk.Scale(settings_row, from_=0.0, to=0.25, resolution=0.001, orient="horizontal", showvalue=True,
                        variable=self.voice_noise_gate_var, bg=self.CARD, fg=self.TEXT, troughcolor=self.BG,
                        activebackground=self.GREEN, highlightthickness=0, borderwidth=0)
        gate.grid(row=1, column=1, sticky="ew", padx=(8, 0), pady=(6, 0))
        tk.Label(settings_row, text="Output Volume", font=(APP_FONT, 8), bg=self.CARD, fg=self.DIM).grid(row=2, column=0, sticky="w", pady=(6, 0))
        outv = tk.Scale(settings_row, from_=0.0, to=5.0, resolution=0.01, orient="horizontal", showvalue=True,
                        variable=self.voice_output_volume_var, bg=self.CARD, fg=self.TEXT, troughcolor=self.BG,
                        activebackground=self.GREEN, highlightthickness=0, borderwidth=0)
        outv.grid(row=2, column=1, sticky="ew", padx=(8, 0), pady=(6, 0))

        self._mic_monitor = MicMonitor(self._mic_meter, lambda: self.mic_var.get(),
                                       lambda: VoiceSettings(
                                           input_gain=self.voice_input_gain_var.get(),
                                           noise_gate=self.voice_noise_gate_var.get(),
                                           output_volume=self.voice_output_volume_var.get()).clamp())
        self._mic_monitor.restart()
        self.mic_var.trace_add("write", lambda *_: self._mic_monitor.restart())
        self.voice_input_gain_var.trace_add("write", lambda *_: self._sync_voice_settings())
        self.voice_noise_gate_var.trace_add("write", lambda *_: self._sync_voice_settings())
        self.voice_output_volume_var.trace_add("write", lambda *_: self._sync_voice_settings())
        self.after(50, self._mic_meter_tick)
        btn_frame = tk.Frame(card, bg=self.CARD)
        btn_frame.grid(row=17, column=0, columnspan=4, sticky="ew", pady=(10, 0))
        btn_frame.columnconfigure((0, 1, 2, 3), weight=1)
        for col, (txt, cmd, clr) in enumerate([
            ("GENERATE CODE", self._generate_code, self.DIM),
            ("START HOST", self._start_host, self.GREEN),
            ("STOP", self._stop_host, self.RED),
            ("LAUNCH GAME", lambda: self._launch(0), self.CYAN),
        ]):
            btn = self._neon_button(btn_frame, txt, cmd, clr)
            btn.grid(row=0, column=col, padx=3, sticky="ew")

    def _build_join_card(self, parent):
        card = self._card(parent, "JOIN")
        card.columnconfigure(1, weight=1)
        card.rowconfigure(4, weight=1)
        row0 = tk.Frame(card, bg=self.CARD)
        row0.grid(row=0, column=0, columnspan=2, sticky="ew", pady=(0, 8))
        row0.columnconfigure(1, weight=1)
        tk.Label(row0, text="Search", font=(APP_FONT, 9), bg=self.CARD, fg=self.DIM).grid(row=0, column=0, padx=(0, 6))
        se = tk.Entry(row0, textvariable=self.search_var, bg=self.INPUT_BG, fg=self.TEXT, insertbackground=self.CYAN, font=(APP_FONT, 9), relief="flat", highlightthickness=1, highlightbackground=self.BORDER, highlightcolor=self.CYAN)
        se.grid(row=0, column=1, sticky="ew", padx=(0, 8))
        self.search_var.trace_add("write", lambda *_: self._refresh_browser())
        for col, (var, opts) in enumerate([
            (self.sort_var, ("Ping", "Players", "Name", "Region")),
            (self.filter_region_var, ("All",)),
            (self.filter_type_var, ("All", "Freeroam", "Speedrun")),
            (self.filter_players_var, ("All", "Open", "Nearly Full", "Full")),
        ]):
            var.trace_add("write", lambda *_: self._refresh_browser())
            om = tk.OptionMenu(row0, var, var.get(), *opts)
            om.configure(bg=self.CARD, fg=self.TEXT, activebackground=self.CYAN, activeforeground=self.BG, highlightthickness=0, bd=0, font=(APP_FONT, 9))
            om["menu"].configure(bg=self.CARD, fg=self.TEXT, activebackground=self.CYAN, activeforeground=self.BG)
            om.grid(row=0, column=col + 2, padx=3)
        refresh_btn = self._neon_button(row0, "REFRESH", self._refresh_browser, self.BLUE)
        refresh_btn.grid(row=0, column=6, padx=(8, 0))
        join_btn = self._neon_button(row0, "JOIN", self._join_selected, self.CYAN)
        join_btn.grid(row=0, column=7, padx=(4, 0))

        columns = ("name", "region", "players", "ping", "type", "code", "chat")
        tree_frame = tk.Frame(card, bg=self.CARD)
        tree_frame.grid(row=4, column=0, columnspan=2, sticky="nsew")
        tree_frame.columnconfigure(0, weight=1)
        tree_frame.rowconfigure(0, weight=1)
        self.rooms_tree = ttk.Treeview(tree_frame, columns=columns, show="headings", selectmode="browse")
        for col, heading, width in [
            ("name", "Room Name", 200), ("region", "Region", 80), ("players", "Players", 75), ("ping", "Ping", 60),
            ("type", "Mode", 80), ("code", "Code", 80), ("chat", "Chat", 55),
        ]:
            self.rooms_tree.heading(col, text=heading, anchor="w")
            self.rooms_tree.column(col, width=width, anchor="w", minwidth=50)
        self.rooms_tree.grid(row=0, column=0, sticky="nsew")
        self.rooms_tree.bind("<Double-1>", lambda _: self._join_selected())
        scroll = ttk.Scrollbar(tree_frame, orient="vertical", command=self.rooms_tree.yview)
        scroll.grid(row=0, column=1, sticky="ns")
        self.rooms_tree.configure(yscrollcommand=scroll.set)

        # ---- Master Servers panel (below room list) ----
        ms_header = tk.Frame(card, bg=self.CARD)
        ms_header.grid(row=5, column=0, columnspan=2, sticky="ew", pady=(10, 2))
        tk.Label(ms_header, text="MASTER SERVERS", font=(APP_FONT, 9, "bold"),
                 bg=self.CARD, fg=self.CYAN).pack(side="left")
        add_btn = tk.Label(ms_header, text="+ Add", font=(APP_FONT, 8), bg=self.CARD,
                           fg=self.GREEN, cursor="hand2", padx=6)
        add_btn.pack(side="right")
        add_btn.bind("<Button-1>", lambda _: self._ms_add())

        ms_list_frame = tk.Frame(card, bg=self.CARD)
        ms_list_frame.grid(row=6, column=0, columnspan=2, sticky="ew")
        self._ms_list_frame = ms_list_frame
        self._ms_rebuild_list()

    def _build_footer(self, parent):
        footer = tk.Frame(parent, bg=self.BG)
        footer.pack(fill="x", pady=(10, 0))
        tk.Label(footer, textvariable=self.stats_var, font=(APP_FONT, 9), bg=self.BG, fg=self.DIM, anchor="w").pack(fill="x")
        self.log_text = tk.Text(footer, height=7, bg=self.PANEL, fg=self.DIM, insertbackground=self.CYAN, font=(APP_FONT_MONO, 9), relief="flat", highlightthickness=1, highlightbackground=self.BORDER)
        self.log_text.pack(fill="x", pady=(6, 0))

    # -----------------------------------------------------------------------
    # Master-server management UI helpers
    # -----------------------------------------------------------------------

    def _ms_rebuild_list(self):
        """Rebuild the master-server row widgets from self.master_servers."""
        for w in self._ms_list_frame.winfo_children():
            w.destroy()
        for idx, srv in enumerate(self.master_servers):
            row = tk.Frame(self._ms_list_frame, bg=self.CARD)
            row.pack(fill="x", pady=1)
            # enabled checkbox
            var = tk.BooleanVar(value=srv.get("enabled", True))
            def _on_toggle(v=var, i=idx):
                self.master_servers[i]["enabled"] = v.get()
                self._save_settings()
            cb = tk.Checkbutton(row, variable=var, command=_on_toggle,
                                bg=self.CARD, activebackground=self.CARD,
                                selectcolor=self.INPUT_BG, highlightthickness=0, bd=0)
            cb.pack(side="left")
            label = f"{srv['name']}  {srv['host']}:{srv['port']}"
            tk.Label(row, text=label, font=(APP_FONT, 8), bg=self.CARD,
                     fg=self.TEXT, anchor="w").pack(side="left", fill="x", expand=True)
            # remove button
            rm = tk.Label(row, text="✕", font=(APP_FONT, 8), bg=self.CARD,
                          fg=self.DIM, cursor="hand2", padx=4)
            rm.pack(side="right")
            rm.bind("<Button-1>", lambda _, i=idx: self._ms_remove(i))
            rm.bind("<Enter>", lambda e, l=rm: l.configure(fg=self.RED))
            rm.bind("<Leave>", lambda e, l=rm: l.configure(fg=self.DIM))

    def _ms_add(self):
        """Open a small dialog to add a new master server entry."""
        dlg = tk.Toplevel(self)
        dlg.title("Add Master Server")
        dlg.configure(bg=self.BG)
        dlg.resizable(False, False)
        dlg.grab_set()
        fields = [("Name", "My Server"), ("Host / IP", ""), ("Port", str(MASTER_SERVER_PORT))]
        entries = {}
        for r, (lbl, default) in enumerate(fields):
            tk.Label(dlg, text=lbl, font=(APP_FONT, 9), bg=self.BG, fg=self.DIM).grid(
                row=r, column=0, sticky="w", padx=10, pady=4)
            e = tk.Entry(dlg, bg=self.INPUT_BG, fg=self.TEXT, insertbackground=self.CYAN,
                         font=(APP_FONT, 9), relief="flat", highlightthickness=1,
                         highlightbackground=self.BORDER, highlightcolor=self.CYAN, width=28)
            e.insert(0, default)
            e.grid(row=r, column=1, sticky="ew", padx=10, pady=4)
            entries[lbl] = e

        def _ok():
            name = entries["Name"].get().strip() or "Server"
            host = entries["Host / IP"].get().strip()
            port = _safe_int(entries["Port"].get().strip(), MASTER_SERVER_PORT)
            if not host:
                return
            self.master_servers.append({"name": name, "host": host, "port": port, "enabled": True})
            self._save_settings()
            self._ms_rebuild_list()
            dlg.destroy()

        btn_row = tk.Frame(dlg, bg=self.BG)
        btn_row.grid(row=len(fields), column=0, columnspan=2, pady=8)
        tk.Button(btn_row, text="Add", command=_ok, bg=self.GREEN, fg=self.BG,
                  font=(APP_FONT, 9, "bold"), relief="flat", padx=14, pady=4).pack(side="left", padx=4)
        tk.Button(btn_row, text="Cancel", command=dlg.destroy, bg=self.CARD, fg=self.TEXT,
                  font=(APP_FONT, 9), relief="flat", padx=10, pady=4).pack(side="left", padx=4)

    def _ms_remove(self, idx: int):
        try:
            self.master_servers.pop(idx)
        except IndexError:
            pass
        self._save_settings()
        self._ms_rebuild_list()

    def _ms_start_heartbeat(self):
        """Start heartbeat threads for all enabled master servers."""
        self._ms_stop_heartbeat()
        for srv in self.master_servers:
            if not srv.get("enabled", True):
                continue
            client = MasterServerClient(srv["host"], srv["port"])
            client.start_heartbeat(self.discovery_payload)
            self._master_clients.append(client)
            self.log(f"Registered with master server: {srv['name']} ({srv['host']}:{srv['port']})")

    def _ms_stop_heartbeat(self):
        """Stop all active master server heartbeats."""
        for c in self._master_clients:
            try:
                c.stop_heartbeat()
            except Exception:
                pass
        self._master_clients.clear()

    def _ms_fetch_rooms(self) -> list:
        """Fetch rooms from all enabled master servers (background-safe)."""
        rooms = []
        for srv in self.master_servers:
            if not srv.get("enabled", True):
                continue
            try:
                client = MasterServerClient(srv["host"], srv["port"])
                fetched = client.list_rooms()
                for r in fetched:
                    r["_source"] = srv["name"]
                rooms.extend(fetched)
            except Exception:
                pass
        return rooms

    def _generate_code(self):
        self.room_code_var.set(_generate_room_code())

    def _reveal_host_ip(self, event=None):
        try:
            if self.host_var.get().strip() == "":
                self.host_var.set(_detect_local_host())
        except Exception:
            pass
        return None

    def _browse_game(self):
        path = filedialog.askdirectory(title="Select Game Folder")
        if path:
            self.game_path_var.set(path)
            self._update_game_status()

    def _auto_detect_game_folder_if_needed(self):
        current = self.game_path_var.get().strip()
        if current:
            ok, _ = _validate_game_folder(current)
            if ok:
                return
        detected = _auto_detect_game_folder()
        if detected:
            self.game_path_var.set(detected)
            self._update_game_status()

    def _update_game_status(self):
        if not hasattr(self, "_game_status_label"):
            return
        folder = self.game_path_var.get().strip()
        if not folder:
            self._game_status_label.configure(text="", fg=self.DIM)
            return
        ok, missing = _validate_game_folder(folder)
        if not ok:
            self._game_status_label.configure(
                text=f"Missing folder(s): {', '.join(missing)}", fg=self.RED)
            return
        exe = _resolve_game_exe(folder, self.game_arch_var.get().strip() or "Win64")
        if exe:
            self._game_status_label.configure(text=f"Found: {exe}", fg=self.GREEN)
        else:
            self._game_status_label.configure(
                text="OLGame.exe not found in Binaries\\Win64 or Binaries\\Win32", fg=self.RED)

    def _room_config(self):
        return RoomConfig(
            room_name=self.room_name_var.get().strip() or "OLTogether Room",
            region=self.region_var.get().strip() or "Auto",
            player_limit=max(1, _safe_int(self.player_limit_var.get().strip(), 8)),
            unlimited=self.unlimited_var.get(),
            allow_chat=self.allow_chat_var.get(),
            public_room=self.public_room_var.get(),
            room_code=self.room_code_var.get().strip(),
            password=self.password_var.get().strip(),
            speedrun_mode=self.speedrun_mode_var.get(),
        )

    def _setup_autosave(self):
        vars_to_watch = [
            self.game_path_var, self.game_arch_var, self.game_extra_args_var,
            self.name_var, self.host_var, self.port_var, self.room_name_var,
            self.region_var, self.player_limit_var, self.unlimited_var,
            self.allow_chat_var, self.public_room_var, self.password_var,
            self.room_code_var, self.speedrun_mode_var, self.check_updates_var,
            self.mic_var, self.voice_input_gain_var, self.voice_noise_gate_var,
            self.voice_output_volume_var,
        ]
        for var in vars_to_watch:
            try:
                var.trace_add("write", lambda *_: self._schedule_save())
            except Exception:
                pass

    def _load_settings(self):
        if not os.path.exists(self.config_path):
            return
        try:
            with open(self.config_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            self.game_path_var.set(data.get("game_path", self.game_path_var.get()))
            self.game_arch_var.set(data.get("game_arch", self.game_arch_var.get()))
            self.game_extra_args_var.set(data.get("game_extra_args", self.game_extra_args_var.get()))
            # Sync the user-facing label after loading the internal key.
            if hasattr(self, "_arch_labels") and hasattr(self, "_arch_label_var"):
                lbl = self._arch_labels.get(self.game_arch_var.get(), "64-bit")
                self._arch_label_var.set(lbl)
            self.name_var.set(data.get("player_name", self.name_var.get()))
            self.host_var.set(data.get("host", self.host_var.get()))
            self.port_var.set(str(data.get("port", self.port_var.get())))
            room = data.get("room", {})
            if isinstance(room, dict):
                cfg = RoomConfig.from_dict(room)
                self.room_name_var.set(cfg.room_name)
                self.region_var.set(cfg.region)
                self.player_limit_var.set(str(cfg.player_limit))
                self.unlimited_var.set(cfg.unlimited)
                self.allow_chat_var.set(cfg.allow_chat)
                self.public_room_var.set(cfg.public_room)
                self.room_code_var.set(cfg.room_code)
                self.password_var.set(cfg.password)
                self.speedrun_mode_var.set(cfg.speedrun_mode)
            self.check_updates_var.set(data.get("check_updates", True))
            self._dismissed_update_version = str(data.get("dismissed_update_version", ""))
            # Load theme settings
            theme = data.get("theme", {})
            if isinstance(theme, dict):
                self.theme_var.set(theme.get("accent", "Cyan"))
                self.theme_dark_var.set(theme.get("dark_mode", True))
            # Load mic device
            mic = data.get("mic_device", "Default")
            self.mic_var.set(mic)
            # Load voice settings (gain / noise gate / output volume)
            voice = data.get("voice", {})
            if isinstance(voice, dict):
                self.voice_input_gain_var.set(float(voice.get("input_gain", 1.0)))
                self.voice_noise_gate_var.set(float(voice.get("noise_gate", 0.02)))
                self.voice_output_volume_var.set(float(voice.get("output_volume", 1.0)))
            # Load master servers list
            ms = data.get("master_servers", None)
            if isinstance(ms, list) and ms:
                # Validate each entry has required keys
                valid = []
                for s in ms:
                    if isinstance(s, dict) and "host" in s:
                        valid.append({
                            "name": str(s.get("name", s["host"])),
                            "host": str(s["host"]),
                            "port": _safe_int(str(s.get("port", MASTER_SERVER_PORT)), MASTER_SERVER_PORT),
                            "enabled": bool(s.get("enabled", True)),
                        })
                if valid:
                    self.master_servers = valid
                    if hasattr(self, "_ms_list_frame"):
                        self._ms_rebuild_list()
        except Exception:
            pass

    def _save_settings(self):
        data = {
            "game_path": self.game_path_var.get().strip(),
            "game_arch": self.game_arch_var.get().strip() or "Win64",
            "game_extra_args": self.game_extra_args_var.get().strip(),
            "player_name": self.name_var.get().strip(),
            "host": self.host_var.get().strip(),
            "port": self.port_var.get().strip(),
            "room": self._room_config().to_dict() | {"password": self.password_var.get().strip()},
            "check_updates": self.check_updates_var.get(),
            "dismissed_update_version": self._dismissed_update_version,
            "theme": {
                "accent": self.theme_var.get(),
                "dark_mode": self.theme_dark_var.get(),
            },
            "mic_device": self.mic_var.get(),
            "voice": {
                "input_gain": self.voice_input_gain_var.get(),
                "noise_gate": self.voice_noise_gate_var.get(),
                "output_volume": self.voice_output_volume_var.get(),
            },
            "master_servers": self.master_servers,
        }
        try:
            tmp = self.config_path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2)
                f.flush()
                os.fsync(f.fileno())
            if os.path.exists(self.config_path):
                os.replace(tmp, self.config_path)
            else:
                os.rename(tmp, self.config_path)
        except Exception:
            try:
                os.remove(tmp)
            except Exception:
                pass

    def _schedule_save(self):
        if self._save_after_id is not None:
            self.after_cancel(self._save_after_id)
        self._save_after_id = self.after(800, self._do_deferred_save)

    def _do_deferred_save(self):
        self._save_after_id = None
        self._save_settings()

    def discovery_payload(self):
        room = self._room_config()
        host = self.host_var.get().strip() or _detect_local_host()
        port = self.port_var.get().strip() or str(RELAY_PORT)
        clients = self._bridge_clients
        player_count = len(clients) if clients is not None else 0
        fields = [
            "ROOM", room.room_name, room.region, str(player_count),
            str(0 if room.unlimited else room.player_limit),
            "1" if room.unlimited else "0", "1" if room.public_room else "0",
            "1" if room.allow_chat else "0", "1" if room.password else "0",
            room.room_code, host, port,
            "1" if room.speedrun_mode else "0",
        ]
        return DISCOVERY_MAGIC.decode() + "," + ",".join(fields)

    def start_discovery_responder(self):
        self.responder.start()

    def stop_discovery_responder(self):
        self.responder.stop()

    def _start_host(self):
        host = self.host_var.get().strip() or _detect_local_host()
        if not self.host_var.get().strip():
            self.host_var.set(host)
        try:
            port = int(self.port_var.get().strip() or str(RELAY_PORT))
        except ValueError:
            return
        self.room = self._room_config()
        self._save_settings()
        if self.server_running:
            return
        self.server_running = True
        try:
            self._voice_relay = VoiceRelay(host="0.0.0.0", port=VOICE_PORT,
                                            position_lookup=lambda ip: self._voice_position_lookup(ip)
                                            if self._voice_position_lookup else None)
            self._voice_thread = threading.Thread(target=self._voice_relay.start, daemon=True)
            self._voice_thread.start()
        except Exception as exc:
            self.log(f"Voice relay failed to start: {exc}")
            self._voice_relay = None
        loop = asyncio.new_event_loop()
        self._bridge_loop = loop
        threading.Thread(target=lambda: loop.run_until_complete(_run_tcp_bridge(self, host, port, self.room)), daemon=True).start()
        # Register with enabled master servers so remote players can see the room
        self._ms_start_heartbeat()

    def _stop_host(self):
        if not self.server_running:
            return
        loop = self._bridge_loop
        shutdown = self._bridge_shutdown
        if loop is not None and shutdown is not None:
            try:
                if not shutdown.done():
                    loop.call_soon_threadsafe(shutdown.set_result, None)
            except Exception:
                pass
        self.server_running = False
        if self._voice_relay is not None:
            try:
                self._voice_relay.stop()
            except Exception:
                pass
            self._voice_relay = None
        self._voice_position_lookup = None
        self._ms_stop_heartbeat()

    def _launch(self, role):
        game_folder = self.game_path_var.get().strip()
        ok, missing = _validate_game_folder(game_folder)
        if not ok:
            self.log("Cannot launch: select a valid game folder containing Binaries, Engine, and OLGame.")
            messagebox.showwarning("Missing Game Folder", "Select a valid game folder containing Binaries, Engine, and OLGame.")
            return
        game_path = _resolve_game_exe(game_folder, self.game_arch_var.get().strip() or "Win64")
        if not game_path:
            self.log("Cannot launch: OLGame.exe was not found in Binaries\\Win64 or Binaries\\Win32.")
            messagebox.showwarning("Missing Game EXE", "OLGame.exe was not found in Binaries\\Win64 or Binaries\\Win32.")
            return
        player_name = self.name_var.get().strip() or ("HostPlayer" if role == 0 else "ClientPlayer")
        host = self.host_var.get().strip() or _detect_local_host()
        port = self.port_var.get().strip() or str(RELAY_PORT)
        room = self._room_config()
        self._save_settings()
        try:
            import socket
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.bind(('127.0.0.1', 0))
                control_port = s.getsockname()[1]
        except Exception:
            control_port = GAME_CONTROL_PORT

        url = f"Intro_Persistent?game=Multiplayer.OLTogetherGame?Role={role}?ServerIP={quote(host, safe='')}?ServerPort={port}?PlayerName={quote(player_name, safe='')}?VoiceHost={quote(host, safe='')}?VoicePort=7778?ControlPort={control_port}?QuickPlay"
        if room.password:
            url += f"?RoomToken={quote(_sha256(room.password), safe='')}"
        if room.speedrun_mode:
            url += "?SpeedrunMode=1"
        # Split extra args into URL fragment (?Key=Val) and engine flags (-flag)
        extra_raw = self.game_extra_args_var.get().strip()
        extra_url_parts = []   # appended to the Unreal URL string
        extra_flags = []       # passed as separate process arguments
        if extra_raw:
            for token in extra_raw.split():
                if token.startswith("-"):
                    extra_flags.append(token)
                elif "=" in token or token.startswith("?"):
                    extra_url_parts.append(token.lstrip("?"))
                else:
                    extra_flags.append(token)
        if extra_url_parts:
            url += "?" + "?".join(extra_url_parts)
        cmd = [game_path, url] + extra_flags
        self.log(f"Launching: {' '.join(cmd)}")
        try:
            subprocess.Popen(cmd)
        except Exception as exc:
            self.log(f"Launch failed: {exc}")
            return
        self._start_voice_client(host, control_port)

    def _current_voice_settings(self) -> VoiceSettings:
        return VoiceSettings(
            input_gain=self.voice_input_gain_var.get(),
            noise_gate=self.voice_noise_gate_var.get(),
            output_volume=self.voice_output_volume_var.get(),
        ).clamp()

    def _sync_voice_settings(self):
        if self._voice_client is not None:
            self._voice_client.voice_settings = self._current_voice_settings()

    def _start_voice_client(self, voice_host, control_port):
        if self._mic_monitor is not None:
            try:
                self._mic_monitor.stop()
            except Exception:
                pass
        if self._voice_client is not None:
            try:
                self._voice_client.stop()
            except Exception:
                pass
            self._voice_client = None
        mic = self.mic_var.get().strip() or "Default"
        try:
            self._voice_client = VoiceClient(mic_device=mic, control_host="127.0.0.1",
                                              control_port=control_port,
                                              voice_settings=self._current_voice_settings())
            self._voice_client.start(voice_host, VOICE_PORT)
        except Exception as exc:
            self.log(f"Voice client failed to start: {exc}")
            self._voice_client = None

    def _refresh_browser(self):
        rooms = self.browser.get_rooms()
        if self.server_running and self._bridge_clients is not None:
            room = self._room_config()
            rooms.append({
                "name": room.room_name, "region": room.region,
                "players": len(self._bridge_clients), "limit": 0 if room.unlimited else room.player_limit,
                "unlimited": room.unlimited, "public": room.public_room, "allow_chat": room.allow_chat,
                "password": bool(room.password),
                "code": room.room_code, "host": self.host_var.get().strip(),
                "port": _safe_int(self.port_var.get().strip(), RELAY_PORT), "ping": 0,
                "speedrun_mode": room.speedrun_mode,
                "player_display": f"{len(self._bridge_clients)}/{room.player_limit}" if not room.unlimited else f"{len(self._bridge_clients)}/\u221e",
            })
        # Merge rooms from WAN master servers in a background thread so the UI
        # isn't blocked by network calls.  Results are merged and re-rendered.
        def _fetch_and_merge(lan_rooms):
            wan = self._ms_fetch_rooms()
            # Deduplicate by (host, port): LAN takes priority
            seen = {(r.get("host"), r.get("port")) for r in lan_rooms}
            for r in wan:
                key = (r.get("host"), r.get("port"))
                if key not in seen:
                    lan_rooms.append(r)
                    seen.add(key)
            self.after(0, self._apply_browser_rooms, lan_rooms)
        threading.Thread(target=_fetch_and_merge, args=(rooms,), daemon=True).start()

    def _apply_browser_rooms(self, rooms):
        visible = _sorted_rooms(rooms, self.sort_var.get(), self.search_var.get(),
                                self.filter_region_var.get(), self.filter_type_var.get(),
                                self.filter_players_var.get())
        self.rooms_tree.delete(*self.rooms_tree.get_children())
        self._row_rooms = {}
        for room in visible:
            item = self.rooms_tree.insert("", "end", values=_room_to_row(room))
            self._row_rooms[item] = room

    def _selected_room(self):
        sel = self.rooms_tree.selection()
        if not sel:
            return None
        return self._row_rooms.get(sel[0])

    def _join_selected(self):
        room = self._selected_room()
        if not room:
            return
        self.host_var.set(str(room.get("host", self.host_var.get())))
        self.port_var.set(str(room.get("port", self.port_var.get())))
        self._launch(1)

    def log(self, message):
        LOG.info(message)
        self.after(0, self._append_log, message)

    def _append_log(self, message):
        stamp = time.strftime("%H:%M:%S")
        self.log_text.insert("end", f"[{stamp}] {message}\n")
        self.log_text.see("end")

    def refresh_clients(self, snapshot):
        self.after(0, self._refresh_clients, snapshot)

    def _refresh_clients(self, snapshot):
        parts = [f"{info['name']} ({info['address']}) {int(info['uptime'])}s" for info in snapshot]
        self.stats_var.set(" | ".join(parts) if parts else f"Room: {self.room.room_name}")

    def set_server_state(self, running):
        self.after(0, self._set_server_state, running)

    def _set_server_state(self, running):
        self.server_running = running
        if running:
            self.status_var.set("ONLINE")
            self._status_label.configure(fg=self.GREEN)
        else:
            self.status_var.set("OFFLINE")
            self._status_label.configure(fg=self.DIM)

    def set_server_info(self, clients, connections, relayed, started_at):
        def apply():
            up = int(_now() - started_at) if started_at else 0
            self.stats_var.set(f"Clients: {clients}  Connections: {connections}  Relayed: {relayed}  Uptime: {up // 60}m {up % 60}s")
        self.after(0, apply)

    def _mic_meter_tick(self):
        if self._mic_monitor is not None:
            self._mic_monitor.tick()
        self.after(50, self._mic_meter_tick)

    def _pulse_tick(self):
        self._pulse_phase += 0.04
        if self._pulse_phase > 6.28:
            self._pulse_phase -= 6.28
        intensity = int(40 + 25 * (0.5 + 0.5 * (self._pulse_phase % 6.28 - 3.14) / 3.14))
        r, g, b = max(0, intensity - 30), min(255, intensity + 40), min(255, intensity + 60)
        glow_color = f"#{r:02x}{g:02x}{b:02x}"
        self.configure(bg=glow_color)
        try:
            self._root_frame.configure(bg=self.BG)
        except Exception:
            pass
        self.after(40, self._pulse_tick)

    def _tick_stats(self):
        self.after(1500, self._tick_stats)

    def _check_for_updates(self):
        if not self.check_updates_var.get():
            return
        def check():
            try:
                import json
                req = urllib.request.Request(
                    "https://api.github.com/repos/MeinaWithAI/OutlastTogether/releases/latest",
                    headers={"User-Agent": "OLTogether"}
                )
                with urllib.request.urlopen(req, timeout=5) as resp:
                    data = json.loads(resp.read().decode())
                latest_version = data.get("tag_name", "").lstrip("v")
                current_version = APP_VERSION.lstrip("v")
                
                # Simple version comparison
                def parse_version(v):
                    return [int(x) if x.isdigit() else 0 for x in v.split(".")]
                
                if parse_version(latest_version) > parse_version(current_version):
                    if latest_version == self._dismissed_update_version:
                        return
                    self.after(0, self._prompt_update, latest_version)
            except Exception as e:
                if hasattr(e, "code") and e.code == 403:
                    pass
                else:
                    self.log(f"Failed to check for updates: {e}")
                
        threading.Thread(target=check, daemon=True).start()

    def _prompt_update(self, latest_version):
        msg = f"A new version of OutlastTogether ({latest_version}) is available!\n\nWould you like to download it now?"
        if messagebox.askyesno("Update Available", msg):
            webbrowser.open("https://github.com/MeinaWithAI/OutlastTogether/releases")
            # Remember this version so the prompt won't reappear until a newer
            # release comes out.
            self._dismissed_update_version = latest_version
            self._save_settings()

    def _on_close(self):
        if self._closing:
            return
        self._closing = True
        if self.server_running:
            self._stop_host()
        if self._voice_client is not None:
            try:
                self._voice_client.stop()
            except Exception:
                pass
            self._voice_client = None
        if self._mic_monitor is not None:
            try:
                self._mic_monitor.stop()
            except Exception:
                pass
            self._mic_monitor = None
        try:
            self.browser.stop()
        except Exception:
            pass
        try:
            self.responder.stop()
        except Exception:
            pass
        self._save_settings()
        self._slide_out_and_close()



class HeadlessRelay:
    def __init__(self, host, port, room, config_path):
        self.host = host
        self.port = port
        self.room = room
        self.config_path = config_path
        self._loop = None
        self._shutdown = None
        self._clients = None
        self._responder = None
        self._started_at = 0.0

    def discovery_payload(self):
        room = self.room
        host = self.host
        port = self.port
        clients = self._clients
        player_count = len(clients) if clients is not None else 0
        fields = [
            "ROOM", room.room_name, room.region, str(player_count),
            str(0 if room.unlimited else room.player_limit),
            "1" if room.unlimited else "0", "1" if room.public_room else "0",
            "1" if room.allow_chat else "0", "1" if room.password else "0",
            room.room_code, host, str(port),
            "1" if room.speedrun_mode else "0",
        ]
        return DISCOVERY_MAGIC.decode() + "," + ",".join(fields)

    def start(self):
        loop = asyncio.new_event_loop()
        self._loop = loop
        threading.Thread(target=lambda: loop.run_until_complete(self._run_bridge()), daemon=True).start()

    def stop(self):
        loop = self._loop
        shutdown = self._shutdown
        if loop is None or shutdown is None:
            return
        try:
            if not shutdown.done():
                loop.call_soon_threadsafe(shutdown.set_result, None)
        except Exception:
            pass

    async def _run_bridge(self):
        loop = asyncio.get_event_loop()
        clients = {}
        counters = {"next_id": 1, "connections": 0, "relayed": 0}
        self._started_at = _now()
        shutdown_future = loop.create_future()
        self._shutdown = shutdown_future
        self._clients = clients

        def wake(client):
            if client.wake is not None and not client.wake.is_set():
                client.wake.set()

        def enqueue(client, data):
            if client.closing:
                return
            if len(client.outbox) >= CLIENT_QUEUE_LIMIT:
                _make_room(client.outbox)
                client.dropped += 1
            client.outbox.append(data)
            wake(client)

        def broadcast(line, exclude=None):
            exclude_cid = exclude.cid if exclude else None
            counters["relayed"] += 1
            for client in clients.values():
                if client.cid == exclude_cid or client.closing:
                    continue
                if exclude_cid is not None:
                    data = f"FROM,{exclude_cid},{line.rstrip(chr(10))}\n".encode("utf-8")
                else:
                    data = (line.rstrip("\n") + "\n").encode("utf-8")
                enqueue(client, data)

        def send_to(client, line):
            enqueue(client, (line.rstrip("\n") + "\n").encode("utf-8"))

        def log_msg(fmt, *args):
            msg = fmt % args if args else fmt
            LOG.info(msg)
            print(f"[{time.strftime('%H:%M:%S')}] {msg}")

        def status():
            up = int(_now() - self._started_at) if self._started_at else 0
            log_msg("C:%d Conn:%d Rly:%d Up:%dm%ds", len(clients), counters["connections"], counters["relayed"], up // 60, up % 60)

        async def handle(reader, writer):
            peer = writer.get_extra_info("peername")
            address = f"{peer[0]}:{peer[1]}" if peer else "unknown"
            client = Client(cid=counters["next_id"], writer=writer, address=address)
            counters["next_id"] += 1
            client.wake = asyncio.Event()
            counters["connections"] += 1
            if not self.room.unlimited and len(clients) >= self.room.player_limit:
                enqueue(client, b"NOTIF,Room is full.\n")
                wake(client)
                await asyncio.sleep(0.1)
                client.closing = True
                try:
                    writer.close()
                except Exception:
                    pass
                return
            clients[client.cid] = client
            client.writer_task = loop.create_task(client_writer(client))
            log_msg("%s connected (assigned %s)", address, client.label)
            send_to(client, f"YOUR_CID,{client.cid}")
            status()
            buffer = b""
            try:
                while True:
                    chunk = await reader.read(READ_CHUNK)
                    if not chunk:
                        break
                    client.rx_bytes += len(chunk)
                    client.last_seen = _now()
                    buffer += chunk
                    if len(buffer) > MAX_LINE_BYTES * 4:
                        buffer = buffer[-MAX_LINE_BYTES:]
                    while b"\n" in buffer:
                        raw, buffer = buffer.split(b"\n", 1)
                        line = raw.decode("utf-8", "ignore").strip("\r").strip()
                        if line:
                            client.rx_msgs += 1
                            await process_line(line, client)
            except (ConnectionResetError, asyncio.IncompleteReadError):
                pass
            finally:
                await disconnect(client)

        async def client_writer(client):
            assert client.wake is not None
            try:
                while True:
                    if not client.outbox:
                        if client.closing:
                            break
                        await client.wake.wait()
                        client.wake.clear()
                        continue
                    data = client.outbox.popleft()
                    client.writer.write(data)
                    client.tx_bytes += len(data)
                    client.tx_msgs += 1
                    if not client.outbox:
                        await client.writer.drain()
            except Exception:
                pass

        async def disconnect(client):
            if client.cid not in clients:
                return
            clients.pop(client.cid, None)
            client.closing = True
            wake(client)
            if client.writer_task:
                client.writer_task.cancel()
            try:
                client.writer.close()
                await client.writer.wait_closed()
            except Exception:
                pass
            broadcast(f"LEFT,{client.cid}")
            broadcast(f"NOTIF,{client.label} left the room.")
            log_msg("%s disconnected", client.label)
            status()

        async def process_line(line, client):
            if line.startswith("AUTH,"):
                parts = line.split(",", 2)
                token = parts[1] if len(parts) > 1 else ""
                if self.room.password and token != _sha256(self.room.password):
                    send_to(client, "AUTH,FAIL")
                    client.closing = True
                    try:
                        client.writer.close()
                    except Exception:
                        pass
                    return
                client.authed = True
                send_to(client, "AUTH,OK")
                return
            if self.room.password and not client.authed and line.startswith(("LOC,", "CHAT,", "NAME,", "SMOVE,")):
                send_to(client, "AUTH,REQUIRED")
                return
            if line.startswith("NAME,"):
                new_name = line[5:].strip() or client.label
                old = client.label
                client.name = new_name
                broadcast(f"NAME,{new_name}", exclude=client)
                if old != new_name:
                    broadcast(f"NOTIF,{new_name} joined the room.", exclude=client)
                return
            if line.startswith("PING,"):
                send_to(client, "PONG," + line[5:])
                return
            if line.startswith("PONG,"):
                return
            if line.startswith("CHAT,"):
                if self.room.allow_chat:
                    broadcast(line, exclude=client)
                return
            broadcast(line, exclude=client)

        async def idle_monitor():
            try:
                while True:
                    await asyncio.sleep(IDLE_CHECK_INTERVAL)
                    now = _now()
                    stale = [c for c in clients.values() if not c.closing and now - c.last_seen > CLIENT_TIMEOUT]
                    for client in stale:
                        client.closing = True
                        wake(client)
                        try:
                            client.writer.close()
                        except Exception:
                            pass
            except asyncio.CancelledError:
                pass

        try:
            server = await asyncio.start_server(handle, self.host, self.port, limit=MAX_LINE_BYTES)
        except Exception as exc:
            log_msg("Failed to start server: %s", exc)
            return

        sock = server.sockets[0].getsockname()
        log_msg("Listening on %s:%d", sock[0], sock[1])

        self._responder = LANDiscoveryResponder(self.discovery_payload)
        self._responder.start()

        idle_task = loop.create_task(idle_monitor())
        try:
            async with server:
                await shutdown_future
        finally:
            idle_task.cancel()
            server.close()
            await server.wait_closed()
            for client in list(clients.values()):
                client.closing = True
                wake(client)
                try:
                    client.writer.close()
                except Exception:
                    pass
            for client in list(clients.values()):
                try:
                    await client.writer.wait_closed()
                except Exception:
                    pass
            clients.clear()
            if self._responder:
                self._responder.stop()
            log_msg("Server stopped.")


# ---------------------------------------------------------------------------
# Master-server relay  (run this on the VPS: python OutlastTogether.py --master-server)
# ---------------------------------------------------------------------------

class MasterServerRelay:
    """Simple room-directory server that runs on the VPS.

    Clients connect over TCP and send one command per connection:

      REGISTER,<CSV payload>   - announce / refresh a hosted room
      UNREGISTER               - remove the room for this source IP
      LIST                     - reply with all live rooms then END

    The CSV payload is identical to the LAN discovery broadcast:
      OLTG1,ROOM,<name>,<region>,<players>,<limit>,<unlimited>,<public>,
             <allow_chat>,<password>,<code>,<host>,<port>,<speedrun>

    Rooms expire automatically if not re-registered within ROOM_TTL seconds.
    """

    ROOM_TTL = MASTER_SERVER_HEARTBEAT * 3  # 90 s — three missed heartbeats

    def __init__(self, bind_host: str = "0.0.0.0", port: int = MASTER_SERVER_PORT):
        self.bind_host = bind_host
        self.port = port
        self._rooms: Dict[str, dict] = {}   # key = "host:port"
        self._lock = threading.Lock()
        self._server = None
        self._loop = None

    # ---- public ----

    def start(self):
        """Start the asyncio event loop (blocks until stopped)."""
        self._loop = asyncio.new_event_loop()
        self._loop.run_until_complete(self._run())

    def stop(self):
        if self._loop and self._server:
            self._loop.call_soon_threadsafe(self._server.close)

    # ---- internals ----

    async def _run(self):
        self._server = await asyncio.start_server(
            self._handle, self.bind_host, self.port)
        addr = self._server.sockets[0].getsockname()
        _ms_log(f"Master server listening on {addr[0]}:{addr[1]}")
        # Periodic expiry task
        expiry_task = asyncio.get_event_loop().create_task(self._expire_loop())
        async with self._server:
            await self._server.serve_forever()
        expiry_task.cancel()

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        peer = writer.get_extra_info("peername")
        src_ip = peer[0] if peer else "unknown"
        try:
            raw = await asyncio.wait_for(reader.readline(), timeout=MASTER_SERVER_TIMEOUT)
            line = raw.decode("utf-8", "ignore").strip()
            if not line:
                return
            if line == "LIST":
                await self._cmd_list(writer)
            elif line.startswith("REGISTER,"):
                self._cmd_register(line[9:], src_ip)
            elif line == "UNREGISTER":
                self._cmd_unregister(src_ip)
        except Exception:
            pass
        finally:
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass

    async def _cmd_list(self, writer: asyncio.StreamWriter):
        now = _now()
        with self._lock:
            live = [r for r in self._rooms.values()
                    if now - r["_seen"] < self.ROOM_TTL and r.get("public", True)]
        for room in live:
            line = room["_raw"] + "\n"
            writer.write(line.encode("utf-8"))
        writer.write(b"END\n")
        await writer.drain()
        _ms_log(f"LIST → {len(live)} room(s)")

    def _cmd_register(self, payload: str, src_ip: str):
        # payload starts after "REGISTER," — may or may not have the OLTG1 prefix
        if not payload.startswith("OLTG1,"):
            payload = "OLTG1," + payload
        fields = payload.split(",")
        # fields[0]=OLTG1, fields[1]=ROOM, fields[2]=name, ..., fields[11]=host, fields[12]=port
        # Override the host field with the actual source IP so NAT-ed hosts
        # are reachable by their public address, not their self-reported LAN IP.
        try:
            if len(fields) >= 13:
                fields[11] = src_ip
            room = _parse_room_payload(fields[1:])  # strip OLTG1
            if room is None:
                return
            room["_seen"] = _now()
            room["_raw"] = ",".join(fields)  # store corrected payload for LIST replies
            key = f"{src_ip}:{room.get('port', RELAY_PORT)}"
            with self._lock:
                self._rooms[key] = room
            _ms_log(f"REGISTER {key}  '{room.get('name', '?')}'")
        except Exception as exc:
            _ms_log(f"REGISTER parse error from {src_ip}: {exc}")

    def _cmd_unregister(self, src_ip: str):
        with self._lock:
            keys = [k for k in self._rooms if k.startswith(src_ip + ":")]
            for k in keys:
                self._rooms.pop(k, None)
        if keys:
            _ms_log(f"UNREGISTER {src_ip} ({len(keys)} room(s) removed)")

    async def _expire_loop(self):
        try:
            while True:
                await asyncio.sleep(30)
                now = _now()
                with self._lock:
                    stale = [k for k, r in self._rooms.items()
                             if now - r["_seen"] >= self.ROOM_TTL]
                    for k in stale:
                        _ms_log(f"EXPIRE {k}")
                        self._rooms.pop(k, None)
        except asyncio.CancelledError:
            pass


def _ms_log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] [master] {msg}", flush=True)


def _load_headless_config(path):
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        room = data.get("room", {})
        return {
            "host": data.get("host", "").strip(),
            "port": _safe_int(data.get("port", RELAY_PORT), RELAY_PORT),
            "room_name": room.get("room_name", "OLTogether Room"),
            "room_code": room.get("room_code", ""),
            "region": room.get("region", "Auto"),
            "player_limit": _safe_int(str(room.get("player_limit", 8)), 8),
            "unlimited": bool(room.get("unlimited", False)),
            "allow_chat": bool(room.get("allow_chat", True)),
            "public_room": bool(room.get("public_room", True)),
            "password": room.get("password", ""),
            "speedrun_mode": bool(room.get("speedrun_mode", False)),
        }
    except Exception:
        return None


def main():
    logging.basicConfig(level=logging.INFO, format="[%(asctime)s] %(message)s", datefmt="%H:%M:%S")
    host = _detect_local_host()
    port = RELAY_PORT
    headless = False
    docker_mode = False
    config_path = None
    room_name = "OLTogether Room"
    room_code = _generate_room_code()
    password = ""
    region = "Auto"
    player_limit = 8
    unlimited = False
    allow_chat = True
    public_room = True
    speedrun_mode = False
    host_arg_seen = False
    master_server_mode = False
    ms_bind = "0.0.0.0"
    ms_port = MASTER_SERVER_PORT

    i = 1
    while i < len(sys.argv):
        arg = sys.argv[i]
        if arg in ("--headless",):
            headless = True
        elif arg in ("--docker",):
            docker_mode = True
            headless = True
        elif arg in ("--master-server", "--master"):
            master_server_mode = True
        elif arg in ("--ms-bind",):
            i += 1
            if i < len(sys.argv):
                ms_bind = sys.argv[i]
        elif arg in ("--ms-port",):
            i += 1
            if i < len(sys.argv):
                ms_port = _safe_int(sys.argv[i], MASTER_SERVER_PORT)
        elif arg in ("--config",):
            i += 1
            if i < len(sys.argv):
                config_path = sys.argv[i]
        elif arg in ("--host", "-H"):
            i += 1
            if i < len(sys.argv):
                host = sys.argv[i]
        elif arg in ("--port", "-p"):
            i += 1
            if i < len(sys.argv):
                port = _safe_int(sys.argv[i], RELAY_PORT)
        elif arg in ("--room-name",):
            i += 1
            if i < len(sys.argv):
                room_name = sys.argv[i]
        elif arg in ("--room-code",):
            i += 1
            if i < len(sys.argv):
                room_code = sys.argv[i]
        elif arg in ("--password",):
            i += 1
            if i < len(sys.argv):
                password = sys.argv[i]
        elif arg in ("--region",):
            i += 1
            if i < len(sys.argv):
                region = sys.argv[i]
        elif arg in ("--player-limit",):
            i += 1
            if i < len(sys.argv):
                player_limit = _safe_int(sys.argv[i], 8)
        elif arg in ("--unlimited",):
            unlimited = True
        elif arg in ("--no-chat",):
            allow_chat = False
        elif arg in ("--private",):
            public_room = False
        elif arg in ("--speedrun",):
            speedrun_mode = True
        elif arg in ("--help", "-h"):
            print("OLTogether Multiplayer Server")
            print()
            print("GUI mode (default):")
            print("  python OutlastTogether.py")
            print()
            print("Master-server mode (run on VPS):")
            print("  python OutlastTogether.py --master-server [--ms-bind 0.0.0.0] [--ms-port 47778]")
            print()
            print("Headless relay mode (CLI only, no GUI):")
            print("  python OutlastTogether.py --headless [--host HOST] [--port PORT]")
            print("  python OutlastTogether.py --headless --config server_config.json")
            print()
            print("Docker mode (alias for --headless):")
            print("  python OutlastTogether.py --docker")
            print()
            print("Headless options:")
            print("  --config PATH          Load settings from JSON config")
            print("  --host HOST, -H HOST   Bind address (default: auto-detect)")
            print("  --port PORT, -p PORT   TCP port (default: 7777)")
            print("  --room-name NAME       Room name")
            print("  --room-code CODE       Room join code")
            print("  --password PWD         Room password")
            print("  --region REGION        Region tag (default: auto-detect)")
            print("  --player-limit N       Max players (default: 8)")
            print("  --unlimited            No player limit")
            print("  --no-chat              Disable chat")
            print("  --private              Not public in browser")
            print("  --speedrun             Speedrun mode")
            print("  --help, -h             Show this help")
            return
        elif not arg.startswith("-") and not host_arg_seen:
            host = arg
            host_arg_seen = True
        i += 1

    if config_path:
        cfg = _load_headless_config(config_path)
        if cfg:
            host = cfg["host"]
            port = cfg["port"]
            room_name = cfg["room_name"]
            room_code = cfg["room_code"]
            region = cfg["region"]
            player_limit = cfg["player_limit"]
            unlimited = cfg["unlimited"]
            allow_chat = cfg["allow_chat"]
            public_room = cfg["public_room"]
            password = cfg["password"]
            speedrun_mode = cfg["speedrun_mode"]

    # ---- Master-server mode (VPS directory service) ----
    if master_server_mode:
        _ms_log(f"Starting master server on {ms_bind}:{ms_port}")
        relay = MasterServerRelay(bind_host=ms_bind, port=ms_port)

        def _ms_signal(signum, frame):
            _ms_log("Shutting down...")
            relay.stop()
            sys.exit(0)

        signal.signal(signal.SIGINT, _ms_signal)
        if sys.platform != "win32":
            signal.signal(signal.SIGTERM, _ms_signal)

        relay.start()  # blocks until stopped
        return

    if headless or docker_mode:
        if not room_code.strip():
            room_code = _generate_room_code()

        room = RoomConfig(
            room_name=room_name,
            region=region,
            player_limit=player_limit,
            unlimited=unlimited,
            allow_chat=allow_chat,
            public_room=public_room,
            room_code=room_code,
            password=password,
            speedrun_mode=speedrun_mode,
        )

        if docker_mode:
            host = os.environ.get("OL_HOST", host)
            port = _safe_int(os.environ.get("OL_PORT", ""), port)
            room_name_env = os.environ.get("OL_ROOM_NAME", "")
            if room_name_env:
                room.room_name = room_name_env
            pw_env = os.environ.get("OL_PASSWORD", "")
            if pw_env:
                room.password = pw_env
            room_code_env = os.environ.get("OL_ROOM_CODE", "")
            if room_code_env:
                room.room_code = room_code_env
            limit_env = os.environ.get("OL_PLAYER_LIMIT", "")
            if limit_env:
                room.player_limit = _safe_int(limit_env, room.player_limit)
            if os.environ.get("OL_UNLIMITED", "") == "1":
                room.unlimited = True
            if os.environ.get("OL_NO_CHAT", "") == "1":
                room.allow_chat = False
            if os.environ.get("OL_PRIVATE", "") == "1":
                room.public_room = False
            if os.environ.get("OL_SPEEDRUN", "") == "1":
                room.speedrun_mode = True

        if not host or host == "127.0.0.1":
            host = _detect_local_host()

        shutdown_event = threading.Event()

        def _signal_handler(signum, frame):
            print(f"\nReceived signal {signum}, shutting down...")
            shutdown_event.set()

        signal.signal(signal.SIGINT, _signal_handler)
        if sys.platform != "win32":
            signal.signal(signal.SIGTERM, _signal_handler)

        relay = HeadlessRelay(host, port, room, config_path)
        relay.start()

        try:
            shutdown_event.wait()
        except KeyboardInterrupt:
            pass

        print("Shutting down...")
        relay.stop()
        time.sleep(0.3)
        return

    app = OLTogetherApp()
    app.host_var.set(host)
    app.port_var.set(str(port))
    app.mainloop()


if __name__ == "__main__":
    main()
