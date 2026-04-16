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
pcs               = set()
active_tasks      = {}           # pc → list[asyncio.Task]  — reconnection fix
model             = YOLO("yolov8n.pt")
model.to("mps")

latest_frame      = None
processed_frame   = None
navigation_data   = None
latest_detections = []           # raw YOLO detections shared with /scene
lock              = threading.Lock()
RUNNING           = True
stream_active     = False

# ── depth model (lazy-loaded on first /scene request) ─────────────────────────
depth_model  = None
depth_loaded = False
DEPTH_DEVICE = "mps"

# ── danger classes ─────────────────────────────────────────────────────────────
DANGER_CLASSES = {
    "person", "car", "truck", "bus", "motorcycle", "bicycle",
    "dog", "cat", "chair", "dining table", "couch", "bed",
    "potted plant", "bottle", "laptop", "backpack", "suitcase",
    "stairs", "door",
}

size_history = defaultdict(list)
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


# ── navigation helpers ─────────────────────────────────────────────────────────
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


def get_proximity(area, frame_area):
    ratio = area / frame_area
    if ratio > 0.25:  return "close"
    if ratio > 0.08:  return "medium"
    return "far"


# ── Depth Anything V2 (lazy-loaded for /scene) ────────────────────────────────
def ensure_depth_model():
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
        cfg = {"encoder": "vits", "features": 64, "out_channels": [48, 96, 192, 384]}
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
    h, w  = frame.shape[:2]
    scale = 308 / w
    small = cv2.resize(frame, (308, int(h * scale)))
    with torch.no_grad():
        depth = depth_model.infer_image(small)
    depth_resized = cv2.resize(depth, (w, h), interpolation=cv2.INTER_LINEAR)
    d_min, d_max  = depth_resized.min(), depth_resized.max()
    if d_max > d_min:
        return (depth_resized - d_min) / (d_max - d_min)
    return np.zeros_like(depth_resized)


def get_depth_for_box(depth_map, x1, y1, x2, y2):
    cx1 = x1 + (x2 - x1) // 4
    cy1 = y1 + (y2 - y1) // 4
    cx2 = x1 + 3 * (x2 - x1) // 4
    cy2 = y1 + 3 * (y2 - y1) // 4
    cx1, cx2 = max(0, cx1), min(depth_map.shape[1] - 1, cx2)
    cy1, cy2 = max(0, cy1), min(depth_map.shape[0] - 1, cy2)
    region = depth_map[cy1:cy2, cx1:cx2]
    if region.size == 0:
        return 0.5
    return 1.0 - float(np.median(region))   # invert: 1.0 = very close


def depth_to_proximity(dv):
    if dv > 0.72: return "close"
    if dv > 0.45: return "medium"
    return "far"


# def depth_to_meters_estimate(dv):
#     if dv > 0.85: return "under 1 metre"
#     if dv > 0.72: return "about 1 to 2 metres"
#     if dv > 0.55: return "about 2 to 4 metres"
#     if dv > 0.45: return "about 4 to 6 metres"
#     return "far away"
def depth_to_meters_estimate(dv, det, frame_w, frame_h):
    # Bounding box area ratio (0 → 1)
    box_area = (det["x2"] - det["x1"]) * (det["y2"] - det["y1"])
    area_ratio = box_area / (frame_w * frame_h)

    # 🔥 Combine depth + size
    if dv > 0.75 or area_ratio > 0.20:
        return "very close"            # ~0–1m
    elif dv > 0.55 or area_ratio > 0.10:
        return "within 1 metre"        # ~1m
    elif dv > 0.35 or area_ratio > 0.04:
        return "1 to 2 metres"         # ~2m
    else:
        return "more than 2 metres"    # far

# ── /scene — on-demand YOLO + Depth analysis ──────────────────────────────────
async def scene_analysis(request):
    """
    Called by Flutter on double-tap-hold gesture.
    Returns enriched detections with real depth distances for LLM input.
    """
    with lock:
        frame = latest_frame.copy()      if latest_frame      is not None else None
        dets  = [dict(d) for d in latest_detections]   # snapshot copy

    if frame is None or not dets:
        print("\n⚠️  /scene: no frame or detections available")
        return web.Response(
            content_type="application/json",
            text=json.dumps({
                "message":         "No frame available",
                "alerts":          [],
                "safe":            True,
                "timestamp":       time.time(),
                "depth_available": False,
            }),
        )

    h, w      = frame.shape[:2]
    has_depth = ensure_depth_model()

    # ── run depth ──────────────────────────────────────────────────────────
    if has_depth:
        try:
            depth_map = run_depth(frame)
            for det in dets:
                dv = get_depth_for_box(
                    depth_map,
                    det["x1"], det["y1"],
                    det["x2"], det["y2"],
                )
                det["depth"]           = round(dv, 3)
                det["depth_proximity"] = depth_to_proximity(dv)
                # det["distance_est"]    = depth_to_meters_estimate(dv)
                det["distance_est"] = depth_to_meters_estimate(dv, det, w, h)
        except Exception as e:
            print(f"❌ Depth inference error: {e}")
            has_depth = False

    # ── fallback: area-based proximity ────────────────────────────────────
    if not has_depth:
        for det in dets:
            ratio = det["area"] / (w * h)
            det["depth"]           = round(min(ratio * 4, 1.0), 3)
            det["depth_proximity"] = (
                "close"  if ratio > 0.25 else
                "medium" if ratio > 0.08 else "far"
            )
            det["distance_est"]    = ""

    # ── terminal summary ───────────────────────────────────────────────────
    print("\n" + "=" * 65)
    print("🔍 SCENE ANALYSIS  (YOLO + Depth Anything V2)")
    print("-" * 65)
    print(f"  {'Object':<15s} {'Zone':<8s} {'Depth':<8s} {'Proximity':<10s} Distance")
    print("-" * 65)
    for det in dets:
        zone = get_zone(det["cx"], w)
        print(f"  {det['label']:<15s} {zone:<8s} {det.get('depth', 0):<8.3f}"
              f" {det.get('depth_proximity','?'):<10s} {det.get('distance_est','')}")
    print("=" * 65)
    print(f"  Depth: {'✅ Active' if has_depth else '⚠️  Fallback'}  |  "
          f"Objects: {len(dets)}  |  Frame: {w}×{h}")
    print("=" * 65 + "\n")

    # ── build response ─────────────────────────────────────────────────────
    alerts = []
    for det in dets:
        zone = get_zone(det["cx"], w)
        alerts.append({
            "label":           det["label"],
            "conf":            round(det["conf"], 2),
            "x1":  det["x1"], "y1": det["y1"],
            "x2":  det["x2"], "y2": det["y2"],
            "zone":            zone,
            "depth":           det.get("depth", 0.5),
            "depth_proximity": det.get("depth_proximity", "medium"),
            "distance_est":    det.get("distance_est", ""),
            "danger":          det["label"] in DANGER_CLASSES,
        })

    # closest first
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


# ── navigation message builder ─────────────────────────────────────────────────
def generate_navigation_message(detections, frame_w, frame_h):
    if not detections:
        return {
            "message":   "Path clear",
            "alerts":    [],
            "safe":      True,
            "timestamp": time.time(),
        }

    frame_area   = frame_w * frame_h
    alerts       = []
    danger_found = False

    for det in detections:
        label    = det["label"]
        cx, cy   = det["cx"], det["cy"]
        area     = det["area"]
        conf     = det["conf"]

        zone      = get_zone(cx, frame_w)
        proximity = get_proximity(area, frame_area)
        approach  = get_approach_status(label, area)
        is_danger = label in DANGER_CLASSES

        if is_danger and proximity in ("close", "medium"):
            danger_found = True

        alerts.append({
            "label":    label,
            "zone":     zone,
            "proximity": proximity,
            "approach":  approach,
            "conf":      round(conf, 2),
            "danger":    is_danger,
        })

    alerts.sort(key=lambda a: (
        not a["danger"],
        {"close": 0, "medium": 1, "far": 2}[a["proximity"]]
    ))

    top   = alerts[0]
    parts = [top["label"].capitalize()]
    if top["approach"] == "approaching":
        parts.append("approaching")
    elif top["approach"] == "receding":
        parts.append("moving away")
    parts.append(f"on your {top['zone']}")
    parts.append(f"— {top['proximity']}")
    if top["danger"] and top["proximity"] in ("close", "medium"):
        parts.append("⚠ danger")

    message = " ".join(parts)
    if len(alerts) > 1:
        others   = ", ".join(f"{a['label']} {a['zone']}" for a in alerts[1:4])
        message += f". Also: {others}"

    return {
        "message":   message,
        "alerts":    alerts,
        "safe":      not danger_found,
        "timestamp": time.time(),
    }


# ── overlay drawing ────────────────────────────────────────────────────────────
def draw_navigation_overlay(frame, detections, nav):
    h, w = frame.shape[:2]

    cv2.line(frame, (w // 3, 0),     (w // 3, h),     (100, 100, 100), 1)
    cv2.line(frame, (2 * w // 3, 0), (2 * w // 3, h), (100, 100, 100), 1)
    cv2.putText(frame, "LEFT",   (10,        20), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (150,150,150), 1)
    cv2.putText(frame, "CENTER", (w//3 + 10, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (150,150,150), 1)
    cv2.putText(frame, "RIGHT",  (2*w//3+10, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (150,150,150), 1)

    for det in detections:
        x1, y1, x2, y2 = det["x1"], det["y1"], det["x2"], det["y2"]
        label    = det["label"]
        approach = det.get("approach", "stable")
        prox     = det.get("proximity", "far")

        if label in DANGER_CLASSES and prox == "close":
            color = (0, 0, 255)
        elif approach == "approaching":
            color = (0, 140, 255)
        else:
            color = (0, 220, 0)

        cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)
        tag = f"{label} | {prox}"
        if approach == "approaching": tag += " ▲"
        elif approach == "receding":  tag += " ▼"

        cv2.rectangle(frame, (x1, y1 - 18), (x1 + len(tag) * 8, y1), color, -1)
        cv2.putText(frame, tag, (x1 + 2, y1 - 4),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.45, (255, 255, 255), 1)

    bar_color = (0, 0, 180) if not nav["safe"] else (0, 120, 0)
    cv2.rectangle(frame, (0, h - 40), (w, h), bar_color, -1)
    cv2.putText(frame, nav["message"], (10, h - 12),
                cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 1)

    return frame


# ── YOLO inference thread ──────────────────────────────────────────────────────
def process_frames():
    global latest_frame, processed_frame, navigation_data, RUNNING
    global latest_detections   # ← required: this global is written here

    while RUNNING:
        if latest_frame is None:
            continue

        with lock:
            frame = latest_frame.copy()

        h, w    = frame.shape[:2]
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

                detections.append({
                    "label": label,
                    "conf":  conf,
                    "x1": x1, "y1": y1, "x2": x2, "y2": y2,
                    "cx": cx,  "cy": cy,
                    "area": area,
                })

        nav     = generate_navigation_message(detections, w, h)
        nav_map = {a["label"]: a for a in nav["alerts"]}
        for det in detections:
            if det["label"] in nav_map:
                det["approach"]  = nav_map[det["label"]]["approach"]
                det["proximity"] = nav_map[det["label"]]["proximity"]

        annotated = draw_navigation_overlay(result.plot(), detections, nav)

        with lock:
            processed_frame   = annotated
            navigation_data   = nav
            latest_detections = detections   # ← shared with /scene endpoint

        log_frame(detections, nav, w, h)


# ── stream state reset ─────────────────────────────────────────────────────────
def reset_stream_state():
    global stream_active, latest_frame, processed_frame, navigation_data
    global latest_detections
    stream_active = False
    with lock:
        latest_frame      = None
        processed_frame   = None
        navigation_data   = None
        latest_detections = []
    size_history.clear()
    print("[Fix] Stream state reset.")


async def close_pc(pc):
    tasks = active_tasks.pop(pc, [])
    for t in tasks:
        if not t.done():
            t.cancel()
            try:
                await asyncio.wait_for(asyncio.shield(t), timeout=1.0)
            except Exception:
                pass
    try:
        await pc.close()
    except Exception:
        pass
    pcs.discard(pc)
    print(f"[Fix] PC closed ({len(tasks)} tasks cancelled).")


async def close_all_pcs():
    stale = list(pcs)
    for pc in stale:
        await close_pc(pc)
    if stale:
        print(f"[Fix] Closed {len(stale)} stale connection(s).")


# ── HTTP routes ────────────────────────────────────────────────────────────────
async def index(request):
    return web.Response(text="WebRTC + YOLOv8 + DepthV2 Navigation Server")


async def nav_status(request):
    with lock:
        data = navigation_data
    if data is None:
        return web.Response(
            content_type="application/json",
            text=json.dumps({"message": "Waiting...", "safe": True, "alerts": []}),
        )
    return web.Response(content_type="application/json", text=json.dumps(data))


async def offer(request):
    global latest_frame, RUNNING, stream_active

    # close any leftover connections before accepting a new one
    await close_all_pcs()
    reset_stream_state()

    params = await request.json()
    sdp    = RTCSessionDescription(sdp=params["sdp"], type=params["type"])

    pc = RTCPeerConnection()
    pcs.add(pc)
    active_tasks[pc] = []

    @pc.on("icegatheringstatechange")
    def on_ice_gathering():
        print(f"ICE gathering state: {pc.iceGatheringState}")

    @pc.on("iceconnectionstatechange")
    def on_ice_connection():
        print(f"ICE connection state: {pc.iceConnectionState}")

    @pc.on("connectionstatechange")
    async def on_connectionstatechange():
        global stream_active
        print("Connection state:", pc.connectionState)

        if pc.connectionState == "connected":
            stream_active = True
            log_event("connected", "phone stream started")

        if pc.connectionState in ("failed", "closed", "disconnected"):
            log_event("disconnected", pc.connectionState)
            reset_stream_state()
            await close_pc(pc)

    @pc.on("track")
    def on_track(track):
        global stream_active
        if track.kind != "video":
            return
        print("Video track received")
        stream_active = True

        @track.on("ended")
        def on_ended():
            reset_stream_state()

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
                    reset_stream_state()
                    break

        task = asyncio.ensure_future(recv_loop())
        active_tasks.setdefault(pc, []).append(task)

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
    app.router.add_get("/scene",  scene_analysis)
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
threading.Thread(target=process_frames, daemon=True).start()
threading.Thread(target=run_server,     daemon=True).start()

# ── main thread → OpenCV display ──────────────────────────────────────────────
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
        write_summary()
        break

cv2.destroyAllWindows()
sys.exit(0)

# # ── Emergency System ──────────────────────────────────────────────────────────
# def emergency_system_ui():
#     """
#     Create the UI for the emergency system, including a side panel, emergency slider,
#     and contact management form.
#     """
#     # Placeholder for Flutter UI integration
#     print("Emergency system UI initialized.")

# def handle_sos_trigger():
#     """
#     Handle SOS trigger to send an emergency alert.
#     """
#     gps_location = get_gps_location()
#     timestamp = time.time()
#     message = f"User needs help. Location: {gps_location}. Timestamp: {timestamp}."
#     send_alert(message)

# def manage_contacts(action, contact=None):
#     """
#     Add, edit, or delete emergency contacts.
#     """
#     if action == "add" and contact:
#         print(f"Adding contact: {contact}")
#     elif action == "edit" and contact:
#         print(f"Editing contact: {contact}")
#     elif action == "delete" and contact:
#         print(f"Deleting contact: {contact}")
#     else:
#         print("Invalid action or contact.")


# # ── Accessibility-Focused Interaction ─────────────────────────────────────────
# def handle_gesture(gesture):
#     """
#     Handle gestures for accessibility-focused interaction.
#     """
#     if gesture == "single_tap":
#         print("Single tap detected. Triggering depth analysis.")
#         gesture_handler("single_tap")
#     elif gesture == "swipe":
#         print("Swipe detected. Activating exploration mode.")
#         gesture_handler("swipe")
#     elif gesture == "long_press":
#         print("Long press detected. Triggering SOS.")
#         handle_sos_trigger()
#     else:
#         print("Unknown gesture.")

# # Minimal UI placeholder for Flutter integration
# def minimal_ui():
#     """
#     Create a minimal UI for setup and backup triggers.
#     """
#     print("Minimal UI initialized for accessibility.")

# # ── Depth Analysis ────────────────────────────────────────────────────────────
# def depth_analysis(frame):
#     """
#     Perform depth analysis on the given frame using Depth Anything V2.
#     Returns a dictionary with object labels, distances, and directions.
#     """
#     # Integrate Depth Anything V2 model
#     depth_model = load_depth_model("models/yolov8n_float16.tflite")
#     depth_results = depth_model.analyze(frame)
#     return depth_results

# # ── Gesture Handler ───────────────────────────────────────────────────────────
# def gesture_handler(gesture):
#     """
#     Handle user gestures to trigger depth analysis or exploration mode.
#     """
#     if gesture == "single_tap":
#         with lock:
#             frame = latest_frame.copy() if latest_frame is not None else None
#         if frame is not None:
#             depth_results = depth_analysis(frame)
#             # Convert depth results to audio feedback
#             audio_feedback(depth_results)

#     elif gesture == "swipe":
#         exploration_mode()

# # ── Exploration Mode ──────────────────────────────────────────────────────────
# def exploration_mode():
#     """
#     Activate short exploration mode to describe surroundings with depth-based distances.
#     """
#     with lock:
#         frame = latest_frame.copy() if latest_frame is not None else None
#     if frame is not None:
#         depth_results = depth_analysis(frame)
#         # Convert depth results to audio feedback
#         audio_feedback(depth_results)

# # ── Audio Feedback ────────────────────────────────────────────────────────────
# def audio_feedback(depth_results):
#     """
#     Provide audio feedback for depth results.
#     """
#     for obj in depth_results["objects"]:
#         label = obj["label"]
#         distance = obj["distance"]
#         direction = obj["direction"]
#         text_to_speech(f"{label} detected {distance} meters away on your {direction}.")

# # ── Text-to-Speech (TTS) Integration ──────────────────────────────────────────
# def text_to_speech(message):
#     """
#     Convert the given message to speech using a TTS engine.
#     """
#     try:
#         import pyttsx3
#         tts_engine = pyttsx3.init()
#         tts_engine.say(message)
#         tts_engine.runAndWait()
#     except ImportError:
#         print("TTS engine not installed. Please install pyttsx3.")
#         print(message)


# # ── Telegram, WhatsApp, and SMS Alert Functions ───────────────────────────────
# def send_alert_via_telegram(contact, message):
#     """
#     Send an alert message via Telegram.
#     """
#     telegram_bot_token = "<YOUR_TELEGRAM_BOT_TOKEN>"
#     telegram_chat_id = contact  # Assuming contact is the chat ID
#     url = f"https://api.telegram.org/bot{telegram_bot_token}/sendMessage"
#     payload = {
#         "chat_id": telegram_chat_id,
#         "text": message
#     }
#     response = requests.post(url, json=payload)
#     if response.status_code == 200:
#         print(f"Message sent to Telegram contact {contact}")
#     else:
#         print(f"Failed to send message to Telegram contact {contact}: {response.text}")

# def send_alert_via_whatsapp(contact, message):
#     """
#     Send an alert message via WhatsApp using Twilio API.
#     """
#     from twilio.rest import Client

#     account_sid = "<YOUR_TWILIO_ACCOUNT_SID>"
#     auth_token = "<YOUR_TWILIO_AUTH_TOKEN>"
#     twilio_whatsapp_number = "whatsapp:+<YOUR_TWILIO_WHATSAPP_NUMBER>"

#     client = Client(account_sid, auth_token)
#     try:
#         client.messages.create(
#             body=message,
#             from_=twilio_whatsapp_number,
#             to=f"whatsapp:{contact}"
#         )
#         print(f"Message sent to WhatsApp contact {contact}")
#     except Exception as e:
#         print(f"Failed to send message to WhatsApp contact {contact}: {e}")

# def send_alert_via_sms(contact, message):
#     """
#     Send an alert message via SMS using Twilio API.
#     """
#     from twilio.rest import Client

#     account_sid = "<YOUR_TWILIO_ACCOUNT_SID>"
#     auth_token = "<YOUR_TWILIO_AUTH_TOKEN>"
#     twilio_phone_number = "<YOUR_TWILIO_PHONE_NUMBER>"

#     client = Client(account_sid, auth_token)
#     try:
#         client.messages.create(
#             body=message,
#             from_=twilio_phone_number,
#             to=contact
#         )
#         print(f"Message sent to SMS contact {contact}")
#     except Exception as e:
#         print(f"Failed to send message to SMS contact {contact}: {e}")

# def send_help_message_with_location(contacts, location):
#     """
#     Send help message with geological map location to all contacts.
#     """
#     message = f"User needs help. Location: {location}."
#     for contact in contacts:
#         if contact.startswith("telegram:"):
#             send_alert_via_telegram(contact.replace("telegram:", ""), message)
#         elif contact.startswith("whatsapp:"):
#             send_alert_via_whatsapp(contact.replace("whatsapp:", ""), message)
#         else:
#             send_alert_via_sms(contact, message)