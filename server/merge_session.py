import os
import glob
import csv
import json
from collections import defaultdict

# ── config ─────────────────────────────────────────────
LOG_DIR     = "logs"
OUTPUT_DIR  = "merged_logs"

MERGED_DET  = os.path.join(OUTPUT_DIR, "detections.csv")
MERGED_NAV  = os.path.join(OUTPUT_DIR, "navigation.csv")
SUMMARY_OUT = os.path.join(OUTPUT_DIR, "summary.json")

os.makedirs(OUTPUT_DIR, exist_ok=True)

# ── find sessions ──────────────────────────────────────
sessions = sorted(glob.glob(os.path.join(LOG_DIR, "*/")))
print(f"Found {len(sessions)} sessions")

if not sessions:
    print("❌ No sessions found")
    exit()

# ── helpers ────────────────────────────────────────────
def safe_int(x, default=0):
    try:
        return int(x)
    except:
        return default

def safe_float(x, default=0.0):
    try:
        return float(x)
    except:
        return default

# ── merge process ──────────────────────────────────────
frame_offset = 0

det_header_written = False
nav_header_written = False

# clear old merged files
open(MERGED_DET, "w").close()
open(MERGED_NAV, "w").close()

for session_id, session in enumerate(sessions):
    det_path = os.path.join(session, "detections.csv")
    nav_path = os.path.join(session, "navigation.csv")

    print(f"→ Processing: {session}")

    # ── detections ─────────────────────
    if os.path.exists(det_path):
        with open(det_path) as f:
            reader = csv.DictReader(f)

            with open(MERGED_DET, "a", newline="") as out:
                writer = None

                for row in reader:
                    # skip corrupted/header rows
                    if row.get("frame_id") == "frame_id":
                        continue

                    if not det_header_written:
                        writer = csv.DictWriter(out, fieldnames=row.keys())
                        writer.writeheader()
                        det_header_written = True
                    else:
                        writer = csv.DictWriter(out, fieldnames=row.keys())

                    row["frame_id"] = safe_int(row["frame_id"]) + frame_offset
                    row["session_id"] = session_id

                    writer.writerow(row)

    # ── navigation ─────────────────────
    last_frame_in_session = 0

    if os.path.exists(nav_path):
        with open(nav_path) as f:
            reader = csv.DictReader(f)

            with open(MERGED_NAV, "a", newline="") as out:
                writer = None

                for row in reader:
                    # skip corrupted/header rows
                    if row.get("fps") == "fps":
                        continue

                    if not nav_header_written:
                        writer = csv.DictWriter(out, fieldnames=row.keys())
                        writer.writeheader()
                        nav_header_written = True
                    else:
                        writer = csv.DictWriter(out, fieldnames=row.keys())

                    frame_id = safe_int(row["frame_id"])
                    row["frame_id"] = frame_id + frame_offset
                    row["session_id"] = session_id

                    last_frame_in_session = max(last_frame_in_session, frame_id)

                    writer.writerow(row)

    # update offset AFTER full session
    frame_offset += last_frame_in_session

print("\n✅ Merging complete")

# ── aggregation (summary) ─────────────────────────────
print("📊 Generating summary...")

label_counts = defaultdict(int)
danger_count = 0
fps_vals = []
det_counts = []

# detections aggregation
with open(MERGED_DET) as f:
    reader = csv.DictReader(f)
    for row in reader:
        label = row.get("label", "unknown")
        label_counts[label] += 1

        if row.get("is_danger") == "True":
            danger_count += 1

# navigation aggregation
with open(MERGED_NAV) as f:
    reader = csv.DictReader(f)
    for row in reader:
        fps_vals.append(safe_float(row.get("fps")))
        det_counts.append(safe_int(row.get("num_detections")))

total_frames = len(det_counts)

summary = {
    "session_id": "merged",
    "num_sessions": len(sessions),
    "total_frames": total_frames,
    "total_detections": sum(det_counts),
    "total_danger_events": danger_count,
    "avg_fps": round(sum(fps_vals) / max(total_frames, 1), 2),
    "avg_detections_per_frame": round(sum(det_counts) / max(total_frames, 1), 2),
    "top_labels": dict(sorted(label_counts.items(), key=lambda x: x[1], reverse=True)[:15])
}

with open(SUMMARY_OUT, "w") as f:
    json.dump(summary, f, indent=2)

print("✅ summary.json created")
print("📁 Output:", OUTPUT_DIR)