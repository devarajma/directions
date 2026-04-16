"""
Usage:
  python plot_session.py                        # latest session
  python plot_session.py logs/20240101_120000   # specific session
"""

import sys
import os
import json
import csv
import glob
from collections import defaultdict
from datetime import datetime

# graceful matplotlib import
try:
    import matplotlib
    matplotlib.use("Agg")   # no display needed
    import matplotlib.pyplot as plt
    import matplotlib.ticker as ticker
    HAS_MPL = True
except ImportError:
    HAS_MPL = False
    print("Install matplotlib:  pip install matplotlib")
    sys.exit(1)


# ── find session ───────────────────────────────────────────────────────────────
def find_session(path=None):
    if path and os.path.isdir(path):
        return path
    sessions = sorted(glob.glob("logs/*/"))
    if not sessions:
        print("No sessions found in logs/")
        sys.exit(1)
    return sessions[-1].rstrip("/")


# session_dir = find_session(sys.argv[1] if len(sys.argv) > 1 else None)
session_dir = "merged_logs"
print(f"Plotting session: {session_dir}")

PLOTS_DIR = os.path.join(session_dir, "plots")
os.makedirs(PLOTS_DIR, exist_ok=True)

# ── load files ─────────────────────────────────────────────────────────────────
def load_csv(path):
    rows = []
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)
    return rows


def load_json(path):
    with open(path) as f:
        return json.load(f)


det_rows  = load_csv(os.path.join(session_dir, "detections.csv"))
nav_rows  = load_csv(os.path.join(session_dir, "navigation.csv"))
summary   = load_json(os.path.join(session_dir, "summary.json"))

COLORS = {
    "primary":  "#4A90D9",
    "danger":   "#E74C3C",
    "safe":     "#2ECC71",
    "warning":  "#F39C12",
    "purple":   "#9B59B6",
    "gray":     "#95A5A6",
}


def save(fig, name):
    path = os.path.join(PLOTS_DIR, name)
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  saved → {path}")


# ── 1. FPS over time ───────────────────────────────────────────────────────────
def plot_fps():
    fps_vals   = [float(r["fps"])       for r in nav_rows]
    timestamps = [float(r["timestamp"]) for r in nav_rows]
    t0         = timestamps[0] if timestamps else 0
    elapsed    = [t - t0 for t in timestamps]

    fig, ax = plt.subplots(figsize=(12, 4))
    ax.plot(elapsed, fps_vals, color=COLORS["primary"], linewidth=0.8, alpha=0.7)

    # rolling average
    window = 30
    if len(fps_vals) >= window:
        rolling = [
            sum(fps_vals[max(0, i - window):i]) / min(i, window)
            for i in range(1, len(fps_vals) + 1)
        ]
        ax.plot(elapsed, rolling, color=COLORS["warning"],
                linewidth=1.8, label=f"{window}-frame avg")

    ax.set_title("FPS over Session", fontsize=14, fontweight="bold")
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("FPS")
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    save(fig, "01_fps_over_time.png")


# ── 2. Detections per frame ────────────────────────────────────────────────────
def plot_detections_per_frame():
    counts     = [int(r["num_detections"]) for r in nav_rows]
    timestamps = [float(r["timestamp"])    for r in nav_rows]
    t0         = timestamps[0] if timestamps else 0
    elapsed    = [t - t0 for t in timestamps]

    fig, ax = plt.subplots(figsize=(12, 4))
    ax.fill_between(elapsed, counts, color=COLORS["primary"], alpha=0.4)
    ax.plot(elapsed, counts, color=COLORS["primary"], linewidth=0.8)
    ax.set_title("Detections per Frame", fontsize=14, fontweight="bold")
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("Object count")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    save(fig, "02_detections_per_frame.png")


# ── 3. Top object labels (bar chart) ──────────────────────────────────────────
def plot_top_labels():
    label_counts = defaultdict(int)
    for row in det_rows:
        label_counts[row["label"]] += 1

    top = sorted(label_counts.items(), key=lambda x: x[1], reverse=True)[:15]
    labels, counts = zip(*top) if top else ([], [])

    fig, ax = plt.subplots(figsize=(10, 5))
    bars = ax.barh(labels, counts, color=COLORS["primary"])
    ax.bar_label(bars, padding=4, fontsize=9)
    ax.invert_yaxis()
    ax.set_title("Top Detected Objects", fontsize=14, fontweight="bold")
    ax.set_xlabel("Total detections")
    ax.grid(True, axis="x", alpha=0.3)
    fig.tight_layout()
    save(fig, "03_top_labels.png")


# ── 4. Zone distribution (pie) ────────────────────────────────────────────────
def plot_zone_distribution():
    zone_counts = defaultdict(int)
    for row in det_rows:
        zone_counts[row["zone"]] += 1

    zones  = list(zone_counts.keys())
    counts = [zone_counts[z] for z in zones]
    colors = [COLORS["primary"], COLORS["warning"], COLORS["purple"]][:len(zones)]

    fig, ax = plt.subplots(figsize=(6, 6))
    wedges, texts, autotexts = ax.pie(
        counts, labels=zones, autopct="%1.1f%%",
        colors=colors, startangle=90,
        wedgeprops={"edgecolor": "white", "linewidth": 2}
    )
    for at in autotexts:
        at.set_fontsize(11)
    ax.set_title("Object Zone Distribution\n(Left / Center / Right)",
                 fontsize=14, fontweight="bold")
    fig.tight_layout()
    save(fig, "04_zone_distribution.png")


# ── 5. Proximity distribution (bar) ───────────────────────────────────────────
def plot_proximity():
    prox_counts = defaultdict(int)
    for row in det_rows:
        prox_counts[row["proximity"]] += 1

    order  = ["close", "medium", "far"]
    labels = [p for p in order if p in prox_counts]
    counts = [prox_counts[p] for p in labels]
    colors = [COLORS["danger"], COLORS["warning"], COLORS["safe"]][:len(labels)]

    fig, ax = plt.subplots(figsize=(6, 4))
    bars = ax.bar(labels, counts, color=colors, edgecolor="white", linewidth=1.5)
    ax.bar_label(bars, padding=4)
    ax.set_title("Object Proximity Distribution", fontsize=14, fontweight="bold")
    ax.set_ylabel("Count")
    ax.grid(True, axis="y", alpha=0.3)
    fig.tight_layout()
    save(fig, "05_proximity_distribution.png")


# ── 6. Approach status (bar) ──────────────────────────────────────────────────
def plot_approach():
    app_counts = defaultdict(int)
    for row in det_rows:
        app_counts[row["approach"]] += 1

    labels = list(app_counts.keys())
    counts = [app_counts[l] for l in labels]
    colors = [COLORS["danger"] if l == "approaching"
              else COLORS["safe"] if l == "receding"
              else COLORS["gray"] for l in labels]

    fig, ax = plt.subplots(figsize=(6, 4))
    bars = ax.bar(labels, counts, color=colors, edgecolor="white", linewidth=1.5)
    ax.bar_label(bars, padding=4)
    ax.set_title("Object Approach Status", fontsize=14, fontweight="bold")
    ax.set_ylabel("Count")
    ax.grid(True, axis="y", alpha=0.3)
    fig.tight_layout()
    save(fig, "06_approach_status.png")


# ── 7. Safe vs danger timeline ────────────────────────────────────────────────
def plot_safety_timeline():
    timestamps = [float(r["timestamp"]) for r in nav_rows]
    safe_vals  = [1 if r["is_safe"] == "True" else 0 for r in nav_rows]
    t0         = timestamps[0] if timestamps else 0
    elapsed    = [t - t0 for t in timestamps]

    fig, ax = plt.subplots(figsize=(12, 3))
    ax.fill_between(elapsed, safe_vals, step="post",
                    color=COLORS["safe"], alpha=0.5, label="Safe")
    ax.fill_between(elapsed, [1 - s for s in safe_vals], step="post",
                    color=COLORS["danger"], alpha=0.5, label="Danger")
    ax.set_title("Safety Timeline", fontsize=14, fontweight="bold")
    ax.set_xlabel("Time (s)")
    ax.set_yticks([0, 1])
    ax.set_yticklabels(["Danger", "Safe"])
    ax.legend()
    ax.grid(True, alpha=0.2)
    fig.tight_layout()
    save(fig, "07_safety_timeline.png")


# ── 8. Confidence distribution (histogram) ────────────────────────────────────
def plot_confidence():
    confs = [float(r["confidence"]) for r in det_rows]
    if not confs:
        return

    fig, ax = plt.subplots(figsize=(8, 4))
    ax.hist(confs, bins=20, color=COLORS["primary"],
            edgecolor="white", linewidth=0.8)
    ax.axvline(sum(confs) / len(confs), color=COLORS["danger"],
               linestyle="--", linewidth=1.5, label=f"Mean: {sum(confs)/len(confs):.2f}")
    ax.set_title("Detection Confidence Distribution", fontsize=14, fontweight="bold")
    ax.set_xlabel("Confidence")
    ax.set_ylabel("Count")
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    save(fig, "08_confidence_distribution.png")


# ── 9. Summary card ────────────────────────────────────────────────────────────
def plot_summary_card():
    fig, ax = plt.subplots(figsize=(8, 5))
    ax.axis("off")

    title = f"Session Report — {summary.get('session_id', '')}"
    ax.text(0.5, 0.95, title, ha="center", va="top",
            fontsize=14, fontweight="bold", transform=ax.transAxes)

    rows = [
        ("Duration",              f"{summary.get('duration_seconds', 0):.1f} s"),
        ("Total frames",          str(summary.get("total_frames", 0))),
        ("Average FPS",           str(summary.get("avg_fps", 0))),
        ("Total detections",      str(summary.get("total_detections", 0))),
        ("Avg detections/frame",  str(summary.get("avg_detections_per_frame", 0))),
        ("Danger events",         str(summary.get("total_danger_events", 0))),
        ("Top object",            next(iter(summary.get("top_labels", {"none": 0})), "none")),
    ]

    y = 0.80
    for label, value in rows:
        ax.text(0.15, y, label + ":", fontsize=11,
                transform=ax.transAxes, color="#555")
        ax.text(0.55, y, value, fontsize=11, fontweight="bold",
                transform=ax.transAxes, color="#222")
        y -= 0.10

    ax.set_facecolor("#F8F9FA")
    fig.patch.set_facecolor("#F8F9FA")
    fig.tight_layout()
    save(fig, "00_summary_card.png")


# ── run all plots ──────────────────────────────────────────────────────────────
print("\nGenerating plots...")
plot_fps()
plot_detections_per_frame()
plot_top_labels()
plot_zone_distribution()
plot_proximity()
plot_approach()
plot_safety_timeline()
plot_confidence()
plot_summary_card()

print(f"\nAll plots saved to: {PLOTS_DIR}/")
print("Files:")
for f in sorted(os.listdir(PLOTS_DIR)):
    print(f"  {f}")