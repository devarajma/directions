import cv2
from ultralytics import YOLO
import threading

# Load lightweight model
model = YOLO("yolov8n.pt")

url = "http://10.211.150.186:8080/video"
cap = cv2.VideoCapture(url)

if not cap.isOpened():
    print("Cannot open stream")
    exit()

# Shared frame (latest only)
latest_frame = None
processed_frame = None
lock = threading.Lock()

# -------------------------------
# THREAD 1 → CAPTURE (FAST)
# -------------------------------
def capture_frames():
    global latest_frame
    while True:
        ret, frame = cap.read()
        if not ret:
            continue

        frame = cv2.resize(frame, (640, 480))  # small = fast

        with lock:
            latest_frame = frame


# -------------------------------
# THREAD 2 → INFERENCE
# -------------------------------
def process_frames():
    global latest_frame, processed_frame

    while True:
        if latest_frame is None:
            continue

        with lock:
            frame = latest_frame.copy()

        # FAST inference
        results = model(frame, imgsz=320, conf=0.4)

        annotated = results[0].plot()

        with lock:
            processed_frame = annotated


# -------------------------------
# START THREADS
# -------------------------------
threading.Thread(target=capture_frames, daemon=True).start()
threading.Thread(target=process_frames, daemon=True).start()

# -------------------------------
# MAIN THREAD → DISPLAY
# -------------------------------
while True:
    if processed_frame is not None:
        cv2.imshow("High FPS Detection", processed_frame)

    if cv2.waitKey(1) == 27:
        break

cap.release()
cv2.destroyAllWindows()