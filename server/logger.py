import csv
import json
import os
import time
import threading
from datetime import datetime
from collections import defaultdict

# ── config ─────────────────────────────────────────────────────────────────────
LOG_DIR      = "logs"
SESSION_TIME = datetime.now().strftime("%Y%m%d_%H%M%S")
SESSION_DIR  = os.path.join(LOG_DIR, SESSION_TIME)

os.makedirs(SESSION_DIR, exist_ok=True)

# ── file paths ─────────────────────────────────────────────────────────────────
DETECTION_LOG  = os.path.join(SESSION_DIR, "detections.csv")
NAV_LOG        = os.path.join(SESSION_DIR, "navigation.csv")
SESSION_LOG    = os.path.join(SESSION_DIR, "session.json")
SUMMARY_LOG    = os.path.join(SESSION_DIR, "summary.json")

# ── internal state ─────────────────────────────────────────────────────────────
_lock              = threading.Lock()
_session_start     = time.time()
_frame_count       = 0
_total_detections  = 0
_danger_count      = 0
_label_counts      = defaultdict(int)
_zone_counts       = defaultdict(int)
_proximity_counts  = defaultdict(int)
_approach_counts   = defaultdict(int)
_fps_samples       = []
_last_frame_time   = time.time()
_nav_messages      = []


# ── CSV headers ────────────────────────────────────────────────────────────────
def _init_csv_files():
    with open(DETECTION_LOG, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow([
            "timestamp", "frame_id", "label", "confidence",
            "zone", "proximity", "approach", "is_danger",
            "x1", "y1", "x2", "y2", "area", "frame_w", "frame_h"
        ])

    with open(NAV_LOG, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow([
            "timestamp", "frame_id", "message",
            "is_safe", "num_detections", "fps"
        ])


_init_csv_files()


# ── write session metadata ─────────────────────────────────────────────────────
def _write_session_meta():
    meta = {
        "session_id":   SESSION_TIME,
        "start_time":   datetime.now().isoformat(),
        "log_dir":      SESSION_DIR,
        "detection_log": DETECTION_LOG,
        "nav_log":       NAV_LOG,
    }
    with open(SESSION_LOG, "w") as f:
        json.dump(meta, f, indent=2)


_write_session_meta()


# ── public API ─────────────────────────────────────────────────────────────────

def log_frame(detections: list, nav: dict, frame_w: int, frame_h: int):
    """
    Call this once per processed frame.

    detections: list of dicts from process_frames()
    nav:        navigation_data dict from generate_navigation_message()
    frame_w/h:  frame dimensions
    """
    global _frame_count, _total_detections, _danger_count
    global _last_frame_time

    now       = time.time()
    timestamp = round(now, 4)

    # fps
    elapsed   = now - _last_frame_time
    fps       = round(1.0 / elapsed, 2) if elapsed > 0 else 0.0
    _last_frame_time = now

    with _lock:
        _frame_count      += 1
        frame_id           = _frame_count
        _fps_samples.append(fps)
        if len(_fps_samples) > 500:        # keep last 500 samples
            _fps_samples.pop(0)

        _total_detections += len(detections)

        # write detection rows
        with open(DETECTION_LOG, "a", newline="") as f:
            writer = csv.writer(f)
            for det in detections:
                label    = det.get("label",    "unknown")
                conf     = round(det.get("conf",     0.0), 4)
                zone     = det.get("zone",     "unknown")
                prox     = det.get("proximity","unknown")
                approach = det.get("approach", "stable")
                danger   = det.get("danger",   False)
                x1       = det.get("x1", 0)
                y1       = det.get("y1", 0)
                x2       = det.get("x2", 0)
                y2       = det.get("y2", 0)
                area     = det.get("area", 0)

                _label_counts[label]    += 1
                _zone_counts[zone]      += 1
                _proximity_counts[prox] += 1
                _approach_counts[approach] += 1
                if danger:
                    _danger_count += 1

                writer.writerow([
                    timestamp, frame_id, label, conf,
                    zone, prox, approach, danger,
                    x1, y1, x2, y2, area, frame_w, frame_h
                ])

        # write nav row
        with open(NAV_LOG, "a", newline="") as f:
            writer = csv.writer(f)
            writer.writerow([
                timestamp,
                frame_id,
                nav.get("message", ""),
                nav.get("safe", True),
                len(detections),
                fps,
            ])

        # keep last 200 nav messages for summary
        _nav_messages.append({
            "t":       timestamp,
            "message": nav.get("message", ""),
            "safe":    nav.get("safe", True),
        })
        if len(_nav_messages) > 200:
            _nav_messages.pop(0)


def log_event(event_type: str, detail: str = ""):
    """
    Log a one-off event (connection, disconnection, error, etc.)
    Appended to session.json under 'events'.
    """
    entry = {
        "time":    datetime.now().isoformat(),
        "elapsed": round(time.time() - _session_start, 2),
        "type":    event_type,
        "detail":  detail,
    }
    with _lock:
        try:
            with open(SESSION_LOG, "r") as f:
                data = json.load(f)
        except Exception:
            data = {}

        data.setdefault("events", []).append(entry)

        with open(SESSION_LOG, "w") as f:
            json.dump(data, f, indent=2)

    print(f"[EVENT] {event_type}: {detail}")


def write_summary():
    """
    Call this when the session ends (on Q press or disconnect).
    Writes a human-readable + machine-readable summary JSON.
    """
    duration = round(time.time() - _session_start, 2)

    with _lock:
        avg_fps    = round(sum(_fps_samples) / max(len(_fps_samples), 1), 2)
        avg_dets   = round(_total_detections / max(_frame_count, 1), 2)

        summary = {
            "session_id":          SESSION_TIME,
            "start_time":          datetime.fromtimestamp(_session_start).isoformat(),
            "end_time":            datetime.now().isoformat(),
            "duration_seconds":    duration,
            "total_frames":        _frame_count,
            "total_detections":    _total_detections,
            "total_danger_events": _danger_count,
            "avg_fps":             avg_fps,
            "avg_detections_per_frame": avg_dets,

            "top_labels": dict(
                sorted(_label_counts.items(), key=lambda x: x[1], reverse=True)
            ),
            "zone_distribution":     dict(_zone_counts),
            "proximity_distribution": dict(_proximity_counts),
            "approach_distribution":  dict(_approach_counts),

            "recent_nav_messages": _nav_messages[-20:],
        }

    with open(SUMMARY_LOG, "w") as f:
        json.dump(summary, f, indent=2)

    # pretty print to terminal
    print("\n" + "=" * 55)
    print(f"  SESSION SUMMARY  —  {SESSION_TIME}")
    print("=" * 55)
    print(f"  Duration        : {duration:.1f}s")
    print(f"  Total frames    : {_frame_count}")
    print(f"  Avg FPS         : {avg_fps}")
    print(f"  Total detections: {_total_detections}")
    print(f"  Danger events   : {_danger_count}")
    print(f"  Avg dets/frame  : {avg_dets}")
    print(f"\n  Top objects detected:")
    for label, count in list(summary["top_labels"].items())[:8]:
        bar = "█" * min(count // 5 + 1, 30)
        print(f"    {label:<18} {bar} {count}")
    print(f"\n  Logs saved to: {SESSION_DIR}")
    print("=" * 55)

    return summary