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
from logger import log_frame, log_event, write_summary

import torch
import traceback


# ── globals ────────────────────────────────────────────────────────────────────
pcs           = set()
model         = YOLO("yolov8n.pt")
model.to("mps")  # uncomment for Apple Silicon GPU

latest_frame    = None
processed_frame = None
navigation_data = None   # sent to phone as JSON over HTTP polling
latest_detections = []   # raw YOLO detections with bounding boxes
lock            = threading.Lock()
RUNNING         = True
stream_active   = False

# ── depth model (lazy-loaded on first /scene request) ─────────────────────────
depth_model  = None
depth_loaded = False
DEPTH_DEVICE = "cpu"

# ── danger classes (COCO labels that matter for navigation) ───────────────────
DANGER_CLASSES = {
    "person", "car", "truck", "bus", "motorcycle", "bicycle",
    "dog", "cat", "chair", "dining table", "couch", "bed",
    "potted plant", "bottle", "laptop", "backpack", "suitcase",
    "stairs", "door",
}

# ── object size history for approach detection ────────────────────────────────
size_history = defaultdict(list)   # label → [area, area, ...]
HISTORY_LEN  = 6


# ── ICE gather wait ────────────────────────────────────────────────────────────
async def wait_for_ice(pc, timeout=10):
    gathered = asyncio.Event()

    @pc.on("icegatheringstatechange")
    def on_ice_state():
        print("ICE gathering state:", pc.iceGatheringState)
        if pc.iceGatheringState == "complete":
            gathered.set()

    if pc.iceGatheringState == "complete":
        return
    try:
        await asyncio.wait_for(gathered.wait(), timeout=timeout)
    except asyncio.TimeoutError:
        print("ICE gathering timed out — sending SDP anyway")


# ── navigation logic ───────────────────────────────────────────────────────────
def get_zone(cx, frame_w):
    """Divide frame into left / center / right thirds."""
    third = frame_w / 3
    if cx < third:
        return "left"
    elif cx < 2 * third:
        return "center"
    else:
        return "right"


def get_approach_status(label, area):
    """
    Returns 'approaching', 'receding', or 'stable'
    based on bounding-box area growth over recent frames.
    """
    history = size_history[label]
    history.append(area)
    if len(history) > HISTORY_LEN:
        history.pop(0)

    if len(history) < 3:
        return "stable"

    delta = history[-1] - history[0]
    ratio = delta / max(history[0], 1)

    if ratio > 0.15:
        return "approaching"
    elif ratio < -0.15:
        return "receding"
    return "stable"


def get_proximity(area, frame_area):
    """Returns 'close', 'medium', or 'far' based on box-to-frame area ratio."""
    ratio = area / frame_area
    if ratio > 0.25:
        return "close"
    elif ratio > 0.08:
        return "medium"
    return "far"


# ── Depth Anything V2 (on-demand for /scene endpoint) ─────────────────────────
def ensure_depth_model():
    """Lazy-load Depth Anything V2 on first /scene request."""
    global depth_model, depth_loaded, DEPTH_DEVICE
    if depth_loaded:
        return depth_model is not None
    depth_loaded = True
    try:
        from depth_anything_v2.dpt import DepthAnythingV2
        print("\n🔄 Loading Depth Anything V2 (ViT-Small)...")
        DEPTH_DEVICE = (
            "mps"   if torch.backends.mps.is_available()  else
            "cuda"  if torch.cuda.is_available()           else
            "cpu"
        )
        print(f"   Device: {DEPTH_DEVICE}")
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
        depth_model = depth_model.to(DEPTH_DEVICE).eval()
        print("✅ Depth model loaded.")
        return True
    except Exception as e:
        print(f"❌ Failed to load depth model: {e}")
        traceback.print_exc()
        return False


def run_depth(frame):
    """Run Depth Anything V2 on a frame. Returns normalised depth map (0-1)."""
    h, w = frame.shape[:2]
    scale = 308 / w
    small = cv2.resize(frame, (308, int(h * scale)))
    with torch.no_grad():
        depth = depth_model.infer_image(small)
    depth_resized = cv2.resize(depth, (w, h), interpolation=cv2.INTER_LINEAR)
    d_min, d_max = depth_resized.min(), depth_resized.max()
    if d_max > d_min:
        return (depth_resized - d_min) / (d_max - d_min)
    return np.zeros_like(depth_resized)


def get_depth_for_box(depth_map, x1, y1, x2, y2):
    """Median depth in centre 50% of a bounding box. 1.0 = closest."""
    cx1 = x1 + (x2 - x1) // 4
    cy1 = y1 + (y2 - y1) // 4
    cx2 = x1 + 3 * (x2 - x1) // 4
    cy2 = y1 + 3 * (y2 - y1) // 4
    cx1, cx2 = max(0, cx1), min(depth_map.shape[1] - 1, cx2)
    cy1, cy2 = max(0, cy1), min(depth_map.shape[0] - 1, cy2)
    region = depth_map[cy1:cy2, cx1:cx2]
    if region.size == 0:
        return 0.5
    return 1.0 - float(np.median(region))  # invert: 1.0 = very close


def depth_to_proximity(depth_val):
    if depth_val > 0.72:  return "close"
    if depth_val > 0.45:  return "medium"
    return "far"


def depth_to_meters_estimate(depth_val):
    if depth_val > 0.85:  return "under 1 metre"
    if depth_val > 0.72:  return "about 1 to 2 metres"
    if depth_val > 0.55:  return "about 2 to 4 metres"
    if depth_val > 0.45:  return "about 4 to 6 metres"
    return "far away"


def generate_navigation_message(detections, frame_w, frame_h):
    """
    Returns a dict:
      {
        "message":   "Person approaching on your left — danger",
        "alerts":    [{"label": ..., "zone": ..., "proximity": ..., "approach": ...}],
        "safe":      True/False,
        "timestamp": float
      }
    """
    if not detections:
        return {
            "message":   "Path clear",
            "alerts":    [],
            "safe":      True,
            "timestamp": time.time(),
        }

    frame_area = frame_w * frame_h
    alerts     = []
    danger_found = False

    for det in detections:
        label    = det["label"]
        cx, cy   = det["cx"], det["cy"]
        area     = det["area"]
        conf     = det["conf"]

        zone     = get_zone(cx, frame_w)
        proximity = get_proximity(area, frame_area)
        approach  = get_approach_status(label, area)
        is_danger = label in DANGER_CLASSES

        if is_danger and proximity in ("close", "medium"):
            danger_found = True

        alerts.append({
            "label":     label,
            "zone":      zone,
            "proximity": proximity,
            "approach":  approach,
            "conf":      round(conf, 2),
            "danger":    is_danger,
        })

    # sort by priority: danger + close first
    alerts.sort(key=lambda a: (
        not a["danger"],
        {"close": 0, "medium": 1, "far": 2}[a["proximity"]]
    ))

    # build human-readable message from top alert
    top    = alerts[0]
    parts  = []
    parts.append(top["label"].capitalize())
    if top["approach"] == "approaching":
        parts.append("approaching")
    elif top["approach"] == "receding":
        parts.append("moving away")
    parts.append(f"on your {top['zone']}")
    parts.append(f"— {top['proximity']}")
    if top["danger"] and top["proximity"] in ("close", "medium"):
        parts.append("⚠ danger")

    message = " ".join(parts)

    # append secondary objects briefly
    if len(alerts) > 1:
        others = ", ".join(
            f"{a['label']} {a['zone']}" for a in alerts[1:4]
        )
        message += f". Also: {others}"

    return {
        "message":   message,
        "alerts":    alerts,
        "safe":      not danger_found,
        "timestamp": time.time(),
    }


def draw_navigation_overlay(frame, detections, nav):
    """Draw bounding boxes with zone lines and navigation info on frame."""
    h, w = frame.shape[:2]

    # zone dividers
    cv2.line(frame, (w // 3, 0),     (w // 3, h),     (100, 100, 100), 1)
    cv2.line(frame, (2 * w // 3, 0), (2 * w // 3, h), (100, 100, 100), 1)
    cv2.putText(frame, "LEFT",   (10,        20), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (150,150,150), 1)
    cv2.putText(frame, "CENTER", (w//3 + 10, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (150,150,150), 1)
    cv2.putText(frame, "RIGHT",  (2*w//3+10, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (150,150,150), 1)

    # per-detection overlays
    for det in detections:
        x1, y1, x2, y2 = det["x1"], det["y1"], det["x2"], det["y2"]
        label    = det["label"]
        approach = det["approach"] if "approach" in det else "stable"
        prox     = det["proximity"] if "proximity" in det else "far"

        # box colour: red=danger close, orange=approaching, green=safe
        if label in DANGER_CLASSES and prox == "close":
            color = (0, 0, 255)
        elif approach == "approaching":
            color = (0, 140, 255)
        else:
            color = (0, 220, 0)

        cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)

        tag = f"{label} | {prox}"
        if approach == "approaching":
            tag += " ▲"
        elif approach == "receding":
            tag += " ▼"

        cv2.rectangle(frame, (x1, y1 - 18), (x1 + len(tag) * 8, y1), color, -1)
        cv2.putText(frame, tag, (x1 + 2, y1 - 4),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.45, (255, 255, 255), 1)

    # navigation message bar at bottom
    bar_color = (0, 0, 180) if not nav["safe"] else (0, 120, 0)
    cv2.rectangle(frame, (0, h - 40), (w, h), bar_color, -1)
    cv2.putText(frame, nav["message"], (10, h - 12),
                cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 1)

    return frame


# ── YOLO inference thread ──────────────────────────────────────────────────────
def process_frames():
    global latest_frame, processed_frame, navigation_data, RUNNING

    while RUNNING:
        if latest_frame is None:
            continue

        with lock:
            frame = latest_frame.copy()

        h, w   = frame.shape[:2]
        results = model(frame, imgsz=640, conf=0.4)
        result  = results[0]

        # extract detections
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

                detections.append({
                    "label": label,
                    "conf":  conf,
                    "x1": x1, "y1": y1, "x2": x2, "y2": y2,
                    "cx": cx, "cy": cy,
                    "area": area,
                })

        # navigation logic
        nav = generate_navigation_message(detections, w, h)

        # enrich detections with nav metadata for overlay
        nav_map = {a["label"]: a for a in nav["alerts"]}
        for det in detections:
            if det["label"] in nav_map:
                det["approach"] = nav_map[det["label"]]["approach"]
                det["proximity"] = nav_map[det["label"]]["proximity"]

        # draw
        annotated = draw_navigation_overlay(result.plot(), detections, nav)

        with lock:
            processed_frame = annotated
            navigation_data = nav
            latest_detections = detections   # store raw detections for /scene

        log_frame(detections, nav, w, h)


# ── routes ─────────────────────────────────────────────────────────────────────
async def index(request):
    return web.Response(text="WebRTC + YOLOv8 Navigation Server")


async def nav_status(request):
    """Phone polls this endpoint to get navigation JSON for audio feedback."""
    with lock:
        data = navigation_data
    if data is None:
        return web.Response(
            content_type="application/json",
            text=json.dumps({"message": "Waiting...", "safe": True, "alerts": []}),
        )
    return web.Response(
        content_type="application/json",
        text=json.dumps(data),
    )


async def scene_analysis(request):
    """On-demand YOLO + Depth Anything V2 analysis for double-tap gesture."""
    with lock:
        frame = latest_frame.copy() if latest_frame is not None else None
        dets  = [dict(d) for d in latest_detections]  # deep copy

    if frame is None or not dets:
        print("\n⚠️  /scene called but no frame or detections available")
        return web.Response(
            content_type="application/json",
            text=json.dumps({
                "message": "No frame available",
                "alerts":  [],
                "safe":    True,
                "timestamp": time.time(),
                "depth_available": False,
            }),
        )

    h, w = frame.shape[:2]
    has_depth = ensure_depth_model()

    # ── Run depth analysis ──────────────────────────────────────────────────
    if has_depth:
        try:
            depth_map = run_depth(frame)
            for det in dets:
                dv = get_depth_for_box(depth_map,
                                      det["x1"], det["y1"],
                                      det["x2"], det["y2"])
                det["depth"]           = round(dv, 3)
                det["depth_proximity"] = depth_to_proximity(dv)
                det["distance_est"]    = depth_to_meters_estimate(dv)
        except Exception as e:
            print(f"❌ Depth inference error: {e}")
            has_depth = False

    # Fallback: area-based depth if model unavailable
    if not has_depth:
        for det in dets:
            ratio = det["area"] / (w * h)
            det["depth"]           = round(min(ratio * 4, 1.0), 3)
            det["depth_proximity"] = (
                "close"  if ratio > 0.25 else
                "medium" if ratio > 0.08 else "far"
            )
            det["distance_est"]    = ""

    # ── Print to terminal ───────────────────────────────────────────────────
    print("\n" + "=" * 65)
    print("🔍 SCENE ANALYSIS (YOLO + Depth Anything V2)")
    print("-" * 65)
    print(f"  {'Object':<15s} {'Zone':<8s} {'Depth':<8s} {'Proximity':<10s} {'Distance'}")
    print("-" * 65)
    for det in dets:
        zone = get_zone(det["cx"], w)
        print(f"  {det['label']:<15s} {zone:<8s} {det.get('depth', 0):<8.3f} "
              f"{det.get('depth_proximity', '?'):<10s} {det.get('distance_est', '')}")
    print("=" * 65)
    print(f"  Depth model: {'✅ Active' if has_depth else '⚠️  Fallback (area-based)'}")
    print(f"  Objects: {len(dets)}, Frame: {w}x{h}")
    print("=" * 65 + "\n")

    # ── Build response ──────────────────────────────────────────────────────
    alerts = []
    for det in dets:
        zone = get_zone(det["cx"], w)
        alerts.append({
            "label":          det["label"],
            "conf":           round(det["conf"], 2),
            "x1": det["x1"], "y1": det["y1"],
            "x2": det["x2"], "y2": det["y2"],
            "zone":           zone,
            "depth":          det.get("depth", 0.5),
            "depth_proximity": det.get("depth_proximity", "medium"),
            "distance_est":   det.get("distance_est", ""),
            "danger":         det["label"] in DANGER_CLASSES,
        })

    # Sort by depth (closest first)
    alerts.sort(key=lambda a: a["depth"], reverse=True)

    safe = not any(
        a["danger"] and a["depth_proximity"] in ("close", "medium")
        for a in alerts
    )

    return web.Response(
        content_type="application/json",
        text=json.dumps({
            "message":         "Scene analysis complete",
            "alerts":          alerts,
            "safe":            safe,
            "timestamp":       time.time(),
            "depth_available": has_depth,
        }),
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


        if pc.connectionState == "connected":
            stream_active = True
            log_event("connected", "phone stream started")   # ← ADD

        elif pc.connectionState in ("failed", "closed", "disconnected"):
            log_event("disconnected", pc.connectionState)


        print("Connection state:", pc.connectionState)
        if pc.connectionState in ("failed", "closed", "disconnected"):
            stream_active = False
            with lock:
                latest_frame    = None
                processed_frame = None
                navigation_data = None
            size_history.clear()
            print("Stream stopped — cleared")
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
    app.router.add_get("/",      index)
    app.router.add_get("/nav",   nav_status)
    app.router.add_get("/scene", scene_analysis)
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


# ── start threads ──────────────────────────────────────────────────────────────
threading.Thread(target=process_frames, daemon=True).start()
threading.Thread(target=run_server,     daemon=True).start()

# ── MAIN THREAD → OpenCV display ──────────────────────────────────────────────
while True:
    with lock:
        frame = processed_frame.copy() if processed_frame is not None else None
        nav   = navigation_data

    if frame is not None:
        cv2.imshow("WebRTC — YOLOv8 Navigation", frame)
    else:
        blank = np.zeros((480, 640, 3), dtype="uint8")
        msg   = "Waiting for phone..." if not stream_active else "Waiting for first frame..."
        cv2.putText(blank, msg, (80, 240),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 0), 2)
        cv2.imshow("WebRTC — YOLOv8 Navigation", blank)

    if nav:
        print(f"\r🧭 {nav['message']}", end="", flush=True)


    if cv2.waitKey(1) & 0xFF == ord('q'):
        RUNNING = False
        write_summary()       # ← ADD
        break

cv2.destroyAllWindows()
sys.exit(0)
