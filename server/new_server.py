import asyncio
import json
import cv2
import threading
import sys
import numpy as np
import time
from collections import defaultdict

from aiohttp import web
from aiortc import RTCPeerConnection, RTCSessionDescription
from ultralytics import YOLO

import torch
from depth_anything_v2.dpt import DepthAnythingV2

# ── globals ────────────────────────────────────────────────────────────────────
pcs             = set()
model           = YOLO("yolov8n.pt")
model.to("mps")

latest_frame    = None
processed_frame = None
navigation_data = None
lock            = threading.Lock()
RUNNING         = True
stream_active   = False

# ── depth globals ──────────────────────────────────────────────────────────────
depth_model       = None
latest_depth_map  = None          # cached depth map
depth_frame_count = 0             # counts frames to skip
DEPTH_EVERY_N     = 5             # run depth every N frames only

# ── preprocessing globals ──────────────────────────────────────────────────────
clahe = cv2.createCLAHE(clipLimit=2.5, tileGridSize=(8, 8))

DANGER_CLASSES = {
    "person", "car", "truck", "bus", "motorcycle", "bicycle",
    "dog", "cat", "chair", "dining table", "couch", "bed",
    "potted plant", "bottle", "laptop", "backpack", "suitcase",
}

size_history = defaultdict(list)
HISTORY_LEN  = 6


# ── load depth model ───────────────────────────────────────────────────────────
def load_depth_model():
    global depth_model
    print("Loading Depth Anything V2 (ViT-Small)...")
    device = (
        "mps"   if torch.backends.mps.is_available()  else
        "cuda"  if torch.cuda.is_available()           else
        "cpu"
    )
    print(f"Depth model device: {device}")

    cfg = {
        "encoder":       "vits",
        "features":      64,
        "out_channels":  [48, 96, 192, 384],
    }
    depth_model = DepthAnythingV2(**cfg)
    depth_model.load_state_dict(
        torch.load(
            "checkpoints/depth_anything_v2_vits.pth",
            map_location="cpu",
            weights_only=True,
        )
    )
    depth_model = depth_model.to(device).eval()
    print("Depth model loaded.")
    return device


# ── preprocessing ──────────────────────────────────────────────────────────────
def is_night_mode(frame: np.ndarray) -> bool:
    """Returns True if average brightness is below threshold."""
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    return gray.mean() < 60.0


def apply_night_mode(frame: np.ndarray) -> np.ndarray:
    """
    CLAHE on L channel of LAB — boosts contrast without washing out colours.
    Only applied when scene is dark.
    """
    lab        = cv2.cvtColor(frame, cv2.COLOR_BGR2LAB)
    l, a, b    = cv2.split(lab)
    l_eq       = clahe.apply(l)
    lab_eq     = cv2.merge([l_eq, a, b])
    return cv2.cvtColor(lab_eq, cv2.COLOR_LAB2BGR)


def blur_score(frame: np.ndarray) -> float:
    """Laplacian variance — low value = blurry frame."""
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    return cv2.Laplacian(gray, cv2.CV_64F).var()


def apply_sharpen(frame: np.ndarray) -> np.ndarray:
    """Unsharp mask sharpening — recovers motion blur detail."""
    blur      = cv2.GaussianBlur(frame, (0, 0), 3)
    sharpened = cv2.addWeighted(frame, 1.5, blur, -0.5, 0)
    return sharpened


def preprocess_frame(frame: np.ndarray) -> tuple[np.ndarray, dict]:
    """
    Apply night mode and/or sharpening as needed.
    Returns (processed_frame, flags_dict).
    """
    flags = {"night": False, "sharpened": False}

    # night mode — run first so sharpening works on enhanced image
    if is_night_mode(frame):
        frame          = apply_night_mode(frame)
        flags["night"] = True

    # motion blur — sharpen if score below threshold
    score = blur_score(frame)
    if score < 80.0:
        frame               = apply_sharpen(frame)
        flags["sharpened"]  = True

    return frame, flags


# ── depth estimation ───────────────────────────────────────────────────────────
DEPTH_DEVICE = "cpu"   # updated after load

def run_depth(frame: np.ndarray) -> np.ndarray:
    """
    Run Depth Anything V2 on a downscaled frame.
    Returns a depth map (H x W float32), higher value = further away.
    """
    # downscale to 308px wide for speed — depth is smooth, doesn't need full res
    h, w   = frame.shape[:2]
    scale  = 308 / w
    small  = cv2.resize(frame, (308, int(h * scale)))

    with torch.no_grad():
        depth = depth_model.infer_image(small)   # returns HxW numpy float32

    # resize depth map back to original frame size
    depth_resized = cv2.resize(depth, (w, h), interpolation=cv2.INTER_LINEAR)

    # normalise to 0-1 for easy use
    d_min, d_max  = depth_resized.min(), depth_resized.max()
    if d_max > d_min:
        depth_norm = (depth_resized - d_min) / (d_max - d_min)
    else:
        depth_norm = np.zeros_like(depth_resized)

    return depth_norm


def get_depth_for_box(depth_map: np.ndarray,
                      x1: int, y1: int,
                      x2: int, y2: int) -> float:
    """
    Returns median depth value in the centre 50% of a bounding box.
    Centre crop avoids background bleed at box edges.
    Depth Anything V2: higher value = further. We invert so 1.0 = closest.
    """
    cx1 = x1 + (x2 - x1) // 4
    cy1 = y1 + (y2 - y1) // 4
    cx2 = x1 + 3 * (x2 - x1) // 4
    cy2 = y1 + 3 * (y2 - y1) // 4

    cx1, cx2 = max(0, cx1), min(depth_map.shape[1] - 1, cx2)
    cy1, cy2 = max(0, cy1), min(depth_map.shape[0] - 1, cy2)

    region = depth_map[cy1:cy2, cx1:cx2]
    if region.size == 0:
        return 0.5

    raw = float(np.median(region))
    return 1.0 - raw    # invert: 1.0 = very close, 0.0 = far


def depth_to_proximity(depth_val: float) -> str:
    """
    Convert 0-1 depth score to proximity label.
    Tuned for ViT-Small output range.
    """
    if depth_val > 0.72:   return "close"
    if depth_val > 0.45:   return "medium"
    return "far"


def depth_to_meters_estimate(depth_val: float) -> str:
    """
    Rough metric estimate for speech output.
    Not calibrated — relative guidance only.
    """
    if depth_val > 0.85:  return "under 1 metre"
    if depth_val > 0.72:  return "about 1 to 2 metres"
    if depth_val > 0.55:  return "about 2 to 4 metres"
    if depth_val > 0.45:  return "about 4 to 6 metres"
    return "far away"


# ── ICE gather wait ────────────────────────────────────────────────────────────
async def wait_for_ice(pc, timeout=10):
    gathered = asyncio.Event()

    @pc.on("icegatheringstatechange")
    def on_ice_state():
        if pc.iceGatheringState == "complete":
            gathered.set()

    if pc.iceGatheringState == "complete":
        return
    try:
        await asyncio.wait_for(gathered.wait(), timeout=timeout)
    except asyncio.TimeoutError:
        print("ICE timeout — sending SDP anyway")


# ── navigation logic ───────────────────────────────────────────────────────────
def get_zone(cx, frame_w):
    third = frame_w / 3
    if cx < third:        return "left"
    if cx < 2 * third:    return "center"
    return "right"


def get_approach_status(label, area):
    history = size_history[label]
    history.append(area)
    if len(history) > HISTORY_LEN:
        history.pop(0)
    if len(history) < 3:
        return "stable"
    delta = history[-1] - history[0]
    ratio = delta / max(history[0], 1)
    if ratio > 0.15:   return "approaching"
    if ratio < -0.15:  return "receding"
    return "stable"


def generate_navigation_message(detections, frame_w, frame_h):
    if not detections:
        return {
            "message":   "Path clear",
            "alerts":    [],
            "safe":      True,
            "timestamp": time.time(),
        }

    alerts      = []
    danger_found = False

    for det in detections:
        label    = det["label"]
        cx       = det["cx"]
        area     = det["area"]
        conf     = det["conf"]
        depth_v  = det.get("depth", 0.5)

        zone      = get_zone(cx, frame_w)
        proximity = det.get("depth_proximity", "medium")  # depth-based if available
        approach  = get_approach_status(label, area)
        is_danger = label in DANGER_CLASSES

        if is_danger and proximity in ("close", "medium"):
            danger_found = True

        alerts.append({
            "label":          label,
            "zone":           zone,
            "proximity":      proximity,
            "approach":       approach,
            "conf":           round(conf, 2),
            "danger":         is_danger,
            "depth":          round(depth_v, 3),
            "distance_est":   det.get("distance_est", ""),
        })

    alerts.sort(key=lambda a: (
        not a["danger"],
        {"close": 0, "medium": 1, "far": 2}[a["proximity"]]
    ))

    top   = alerts[0]
    parts = []

    if top["danger"] and top["proximity"] in ("close", "medium"):
        parts.append("Warning.")

    parts.append(top["label"].capitalize())
    if top["approach"] == "approaching":
        parts.append("approaching")
    parts.append(f"on your {top['zone']}")
    if top["distance_est"]:
        parts.append(f"— {top['distance_est']}")

    message = " ".join(parts)

    if len(alerts) > 1:
        others = ", ".join(
            f"{a['label']} {a['zone']}" for a in alerts[1:3]
        )
        message += f". Also: {others}"

    return {
        "message":   message,
        "alerts":    alerts,
        "safe":      not danger_found,
        "timestamp": time.time(),
    }


# ── overlay drawing ────────────────────────────────────────────────────────────
def draw_overlay(frame, detections, nav, depth_map, flags):
    h, w = frame.shape[:2]

    # zone lines
    cv2.line(frame, (w // 3, 0),     (w // 3, h),     (80, 80, 80), 1)
    cv2.line(frame, (2 * w // 3, 0), (2 * w // 3, h), (80, 80, 80), 1)

    # preprocessing flags
    flag_text = []
    if flags.get("night"):      flag_text.append("NIGHT")
    if flags.get("sharpened"):  flag_text.append("SHARP")
    if flag_text:
        cv2.putText(frame, " | ".join(flag_text),
                    (w - 120, 20), cv2.FONT_HERSHEY_SIMPLEX,
                    0.45, (0, 220, 255), 1)

    # depth map overlay (subtle, top-right corner)
    if depth_map is not None:
        dm_vis  = (depth_map * 255).astype(np.uint8)
        dm_col  = cv2.applyColorMap(dm_vis, cv2.COLORMAP_INFERNO)
        thumb_w = w // 5
        thumb_h = h // 5
        thumb   = cv2.resize(dm_col, (thumb_w, thumb_h))
        frame[10:10 + thumb_h, w - thumb_w - 10:w - 10] = (
            cv2.addWeighted(
                frame[10:10 + thumb_h, w - thumb_w - 10:w - 10],
                0.3, thumb, 0.7, 0
            )
        )
        cv2.putText(frame, "depth", (w - thumb_w - 6, thumb_h + 22),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.38, (150, 150, 150), 1)

    # bounding boxes
    for det in detections:
        x1, y1, x2, y2 = det["x1"], det["y1"], det["x2"], det["y2"]
        label    = det["label"]
        approach = det.get("approach", "stable")
        prox     = det.get("depth_proximity", "far")
        depth_v  = det.get("depth", 0.5)
        dist_est = det.get("distance_est", "")

        if label in DANGER_CLASSES and prox == "close":
            color = (0, 0, 255)
        elif approach == "approaching":
            color = (0, 140, 255)
        else:
            color = (0, 200, 60)

        cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)

        tag = f"{label}"
        if dist_est:  tag += f" {dist_est}"
        if approach == "approaching":  tag += " ▲"

        cv2.rectangle(frame, (x1, y1 - 20),
                      (x1 + len(tag) * 8, y1), color, -1)
        cv2.putText(frame, tag, (x1 + 2, y1 - 5),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.45,
                    (255, 255, 255), 1)

    # nav bar
    bar_color = (0, 0, 160) if not nav["safe"] else (0, 100, 0)
    cv2.rectangle(frame, (0, h - 44), (w, h), bar_color, -1)
    cv2.putText(frame, nav["message"], (10, h - 14),
                cv2.FONT_HERSHEY_SIMPLEX, 0.52,
                (255, 255, 255), 1)

    return frame


# ── YOLO + depth inference thread ──────────────────────────────────────────────
def process_frames():
    global latest_frame, processed_frame, navigation_data
    global latest_depth_map, depth_frame_count, RUNNING

    while RUNNING:
        if latest_frame is None:
            continue

        with lock:
            frame = latest_frame.copy()

        # ── 1. preprocess ──────────────────────────────────────────────────
        frame, flags = preprocess_frame(frame)
        h, w         = frame.shape[:2]

        # ── 2. depth (every N frames) ──────────────────────────────────────
        depth_frame_count += 1
        if depth_frame_count % DEPTH_EVERY_N == 0 and depth_model is not None:
            try:
                dm = run_depth(frame)
                with lock:
                    latest_depth_map = dm
            except Exception as e:
                print("Depth error:", e)

        with lock:
            depth_map = latest_depth_map.copy() \
                if latest_depth_map is not None else None

        # ── 3. YOLO ────────────────────────────────────────────────────────
        results = model(frame, imgsz=640, conf=0.4)
        result  = results[0]

        detections = []
        if result.boxes is not None:
            for box in result.boxes:
                x1, y1, x2, y2 = map(int, box.xyxy[0].tolist())
                conf  = float(box.conf[0])
                cls   = int(box.cls[0])
                label = model.names[cls]
                cx    = (x1 + x2) // 2
                cy    = (y1 + y2) // 2
                area  = (x2 - x1) * (y2 - y1)

                # depth for this box
                if depth_map is not None:
                    dv   = get_depth_for_box(depth_map, x1, y1, x2, y2)
                    prox = depth_to_proximity(dv)
                    dist = depth_to_meters_estimate(dv)
                else:
                    # fallback: use bounding box area ratio
                    ratio = area / (w * h)
                    dv    = min(ratio * 4, 1.0)
                    prox  = ("close"  if ratio > 0.25 else
                             "medium" if ratio > 0.08 else "far")
                    dist  = ""

                detections.append({
                    "label":           label,
                    "conf":            conf,
                    "x1": x1, "y1": y1, "x2": x2, "y2": y2,
                    "cx": cx,  "cy": cy,
                    "area":            area,
                    "depth":           dv,
                    "depth_proximity": prox,
                    "distance_est":    dist,
                })

        # ── 4. navigation ──────────────────────────────────────────────────
        nav = generate_navigation_message(detections, w, h)

        # enrich detections with approach status for overlay
        nav_map = {a["label"]: a for a in nav["alerts"]}
        for det in detections:
            if det["label"] in nav_map:
                det["approach"] = nav_map[det["label"]]["approach"]

        # ── 5. draw ────────────────────────────────────────────────────────
        annotated = draw_overlay(result.plot(), detections, nav, depth_map, flags)

        with lock:
            processed_frame = annotated
            navigation_data = nav


# ── routes ─────────────────────────────────────────────────────────────────────
async def index(request):
    return web.Response(text="WebRTC + YOLOv8 + DepthV2 Navigation Server")


async def nav_status(request):
    with lock:
        data = navigation_data
    if data is None:
        return web.Response(
            content_type="application/json",
            text=json.dumps({
                "message": "Waiting...",
                "safe":    True,
                "alerts":  [],
            }),
        )
    return web.Response(
        content_type="application/json",
        text=json.dumps(data),
    )


async def offer(request):
    global latest_frame, RUNNING, stream_active

    params = await request.json()
    sdp    = RTCSessionDescription(sdp=params["sdp"], type=params["type"])

    pc = RTCPeerConnection()
    pcs.add(pc)

    @pc.on("connectionstatechange")
    async def on_connectionstatechange():
        global stream_active, latest_frame, processed_frame, navigation_data
        print("Connection state:", pc.connectionState)
        if pc.connectionState in ("failed", "closed", "disconnected"):
            stream_active = False
            with lock:
                latest_frame    = None
                processed_frame = None
                navigation_data = None
            size_history.clear()
            await pc.close()
            pcs.discard(pc)

    @pc.on("track")
    def on_track(track):
        global stream_active
        if track.kind != "video":
            return
        print("Video track received")
        stream_active = True

        @track.on("ended")
        def on_ended():
            global stream_active, latest_frame, processed_frame, navigation_data
            stream_active = False
            with lock:
                latest_frame    = None
                processed_frame = None
                navigation_data = None
            size_history.clear()

        async def recv_loop():
            global latest_frame, stream_active
            while RUNNING:
                try:
                    frame = await track.recv()
                    img   = frame.to_ndarray(format="bgr24")
                    h, w  = img.shape[:2]
                    if w > 1280:
                        img = cv2.resize(img, (1280, 720))
                    with lock:
                        latest_frame = img
                except Exception as e:
                    print("recv ended:", e)
                    stream_active = False
                    with lock:
                        latest_frame    = None
                        processed_frame = None
                        navigation_data = None
                    break

        asyncio.ensure_future(recv_loop())

    await pc.setRemoteDescription(sdp)
    answer = await pc.createAnswer()
    await pc.setLocalDescription(answer)
    await wait_for_ice(pc)

    return web.Response(
        content_type="application/json",
        text=json.dumps({
            "sdp":  pc.localDescription.sdp,
            "type": pc.localDescription.type,
        }),
    )


# ── server runner ──────────────────────────────────────────────────────────────
async def run_server_async():
    app = web.Application()
    app.router.add_get("/",       index)
    app.router.add_get("/nav",    nav_status)
    app.router.add_post("/offer", offer)

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, host="0.0.0.0", port=8080)
    await site.start()
    print("Server running on http://0.0.0.0:8080")

    while RUNNING:
        await asyncio.sleep(0.1)
    await runner.cleanup()


def run_server():
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    loop.run_until_complete(run_server_async())


# ── start ──────────────────────────────────────────────────────────────────────
DEPTH_DEVICE = load_depth_model()

threading.Thread(target=process_frames, daemon=True).start()
threading.Thread(target=run_server,     daemon=True).start()

# ── main thread → display ──────────────────────────────────────────────────────
while True:
    with lock:
        frame = processed_frame.copy() if processed_frame is not None else None
        nav   = navigation_data

    if frame is not None:
        cv2.imshow("WebRTC — YOLOv8 + Depth Navigation", frame)
    else:
        blank = np.zeros((480, 640, 3), dtype="uint8")
        msg   = "Waiting for phone..." if not stream_active \
                else "Waiting for first frame..."
        cv2.putText(blank, msg, (80, 240),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 0), 2)
        cv2.imshow("WebRTC — YOLOv8 + Depth Navigation", blank)

    if nav:
        print(f"\r{nav['message']}", end="", flush=True)

    if cv2.waitKey(1) & 0xFF == ord('q'):
        RUNNING = False
        break

cv2.destroyAllWindows()
sys.exit(0)