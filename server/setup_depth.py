"""
setup_depth.py
──────────────
Run this ONCE before starting t_server.py, or simply run:

    python setup_depth.py

It fixes two structural mismatches between your folder layout and
what t_server.py expects — without touching t_server.py at all.

What it does
────────────
1. Creates  server/checkpoints/  and symlinks (or copies) the weights file
   from  server/depth_anything_v2_vits.pth
   to    server/checkpoints/depth_anything_v2_vits.pth
   (t_server.py loads from "checkpoints/depth_anything_v2_vits.pth")

2. Ensures  server/depth_anything_v2/__init__.py  exists so that
   `from depth_anything_v2.dpt import DepthAnythingV2` works as a
   proper Python package import.

3. Checks that dinov2.py is present inside depth_anything_v2/ because
   dpt.py imports it internally.

Run from inside the server/ folder:
    cd server
    python setup_depth.py
"""

import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def check(condition: bool, msg: str):
    if not condition:
        print(f"[ERROR] {msg}")
        sys.exit(1)


def info(msg: str):
    print(f"[OK]    {msg}")


def warn(msg: str):
    print(f"[WARN]  {msg}")


# ── 1. verify source weights file ─────────────────────────────────────────────
src_weights = os.path.join(HERE, "depth_anything_v2_vits.pth")
check(
    os.path.isfile(src_weights),
    f"Weights file not found at: {src_weights}\n"
    f"       Please place depth_anything_v2_vits.pth directly in the server/ folder."
)
info(f"Weights found: {src_weights}")


# ── 2. create checkpoints/ folder and link/copy weights ───────────────────────
ckpt_dir  = os.path.join(HERE, "checkpoints")
dst_weights = os.path.join(ckpt_dir, "depth_anything_v2_vits.pth")

os.makedirs(ckpt_dir, exist_ok=True)

if os.path.exists(dst_weights):
    info(f"checkpoints/depth_anything_v2_vits.pth already exists — skipping.")
else:
    # prefer symlink (saves disk space); fall back to copy on Windows
    try:
        os.symlink(src_weights, dst_weights)
        info(f"Symlink created: checkpoints/depth_anything_v2_vits.pth → {src_weights}")
    except (OSError, NotImplementedError):
        shutil.copy2(src_weights, dst_weights)
        info(f"Copied weights to: {dst_weights}")


# ── 3. verify depth_anything_v2/ subfolder ────────────────────────────────────
pkg_dir = os.path.join(HERE, "depth_anything_v2")
check(
    os.path.isdir(pkg_dir),
    f"Folder not found: {pkg_dir}\n"
    f"       Please place dpt.py and dinov2.py inside server/depth_anything_v2/"
)
info(f"Package folder found: {pkg_dir}")


# ── 4. check dpt.py and dinov2.py are present ─────────────────────────────────
for fname in ("dpt.py", "dinov2.py"):
    fpath = os.path.join(pkg_dir, fname)
    check(
        os.path.isfile(fpath),
        f"{fname} not found in depth_anything_v2/\n"
        f"       Please add it to: {fpath}"
    )
    info(f"Found: depth_anything_v2/{fname}")


# ── 5. create __init__.py so it's a proper Python package ─────────────────────
init_path = os.path.join(pkg_dir, "__init__.py")
if os.path.exists(init_path):
    info("depth_anything_v2/__init__.py already exists — skipping.")
else:
    with open(init_path, "w") as f:
        f.write('# depth_anything_v2 package\n')
    info("Created depth_anything_v2/__init__.py")


# ── 6. quick import test ───────────────────────────────────────────────────────
print("\nTesting import...")
try:
    sys.path.insert(0, HERE)
    from depth_anything_v2.dpt import DepthAnythingV2
    info("from depth_anything_v2.dpt import DepthAnythingV2  ✓")
except Exception as e:
    print(f"[ERROR] Import failed: {e}")
    print("        Check that dpt.py and dinov2.py are correct and complete.")
    sys.exit(1)


# ── 7. quick weights load test ────────────────────────────────────────────────
print("\nTesting weights load...")
try:
    import torch
    state = torch.load(dst_weights, map_location="cpu", weights_only=True)
    info(f"Weights loaded successfully ({len(state)} keys)")
except Exception as e:
    print(f"[ERROR] Failed to load weights: {e}")
    sys.exit(1)


print("\n" + "─" * 50)
print("  All checks passed. You can now run:")
print("  python t_server.py")
print("─" * 50)