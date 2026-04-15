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


# ── globals ────────────────────────────────────────────────────────────────────
pcs           = set()
model         = YOLO("yolov8n.pt")
model.to("mps")  # uncomment for Apple Silicon GPU

latest_frame    = None
processed_frame = None
navigation_data = None   # sent to phone as JSON over HTTP polling
lock            = threading.Lock()
RUNNING         = True
stream_active   = False

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
