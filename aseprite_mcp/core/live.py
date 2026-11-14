"""Live feed for the Pixel Live viewer (opt-in with ASEPRITE_MCP_LIVE=1).

After a tool changes a sprite file, the file is copied right away (so the
next tool cannot race the snapshot) and a single background worker renders
the copy to a horizontal sprite sheet of every frame. Each snapshot is
announced by one JSON line in <first root>/.live/events.jsonl:

    {"seq": 12, "ts": 1731567000.12, "tool": "draw_rows", "sprite": "/abs/ho-oh.aseprite",
     "frame": 2, "caption": "Pinta 14 filas en «alas», frame 2",
     "sheet": "frames/000012.png", "data": "frames/000012.json"}

The viewer only reads PNG/JSON files; nothing in here executes input.
"""
import hashlib
import json
import os
import queue
import shutil
import subprocess
import threading
import time

from .captions import caption
from .paths import roots

LIVE_ENV = "ASEPRITE_MCP_LIVE"
KEEP_SNAPSHOTS = 2000


def enabled() -> bool:
    return os.getenv(LIVE_ENV) == "1" and bool(roots())


def live_dir() -> str:
    return os.path.join(roots()[0], ".live")


def fingerprint(path: str | None) -> str | None:
    if not path or not os.path.isfile(path):
        return None
    digest = hashlib.blake2b(digest_size=16)
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


class _Feed:
    def __init__(self):
        self._queue: queue.Queue = queue.Queue()
        self._lock = threading.Lock()
        self._seq = None
        self._worker = None

    def _next_seq(self, base: str) -> int:
        with self._lock:
            if self._seq is None:
                self._seq = 0
                events = os.path.join(base, "events.jsonl")
                if os.path.exists(events):
                    with open(events, "rb") as fh:
                        for line in fh:
                            try:
                                self._seq = max(self._seq, int(json.loads(line)["seq"]))
                            except (ValueError, KeyError):
                                continue
            self._seq += 1
            return self._seq

    def record(self, tool: str, arguments: dict, path: str, before: str | None) -> None:
        if not path.lower().endswith((".aseprite", ".ase")):
            return
        after = fingerprint(path)
        if after is None or after == before:
            return
        base = live_dir()
        os.makedirs(os.path.join(base, "frames"), exist_ok=True)
        os.makedirs(os.path.join(base, "pending"), exist_ok=True)
        seq = self._next_seq(base)
        copy = os.path.join(base, "pending", f"{seq:06d}.aseprite")
        shutil.copyfile(path, copy)
        frame = arguments.get("frame_index") or arguments.get("source_frame") or arguments.get("start_frame")
        event = {
            "seq": seq,
            "ts": round(time.time(), 3),
            "tool": tool,
            "sprite": path,
            "frame": frame if isinstance(frame, int) else None,
            "caption": caption(tool, arguments),
            "sheet": f"frames/{seq:06d}.png",
            "data": f"frames/{seq:06d}.json",
        }
        self._queue.put((base, copy, event))
        if self._worker is None or not self._worker.is_alive():
            self._worker = threading.Thread(target=self._run, name="live-feed", daemon=True)
            self._worker.start()

    def _run(self) -> None:
        while True:
            base, copy, event = self._queue.get()
            try:
                self._render(base, copy, event)
            except Exception:
                pass
            finally:
                if os.path.exists(copy):
                    os.remove(copy)

    def _render(self, base: str, copy: str, event: dict) -> None:
        exe = os.getenv("ASEPRITE_PATH", "")
        sheet = os.path.join(base, event["sheet"])
        data = os.path.join(base, event["data"])
        subprocess.run(
            [exe, "--batch", copy, "--sheet", sheet, "--data", data,
             "--sheet-type", "horizontal", "--format", "json-array"],
            check=True, capture_output=True, stdin=subprocess.DEVNULL, timeout=30,
        )
        # Announce only once both files exist, so the viewer never reads half a snapshot.
        with open(os.path.join(base, "events.jsonl"), "a", encoding="utf-8") as fh:
            fh.write(json.dumps(event, ensure_ascii=False) + "\n")
        self._prune(base, event["seq"])

    @staticmethod
    def _prune(base: str, seq: int) -> None:
        cutoff = seq - KEEP_SNAPSHOTS
        if cutoff <= 0 or seq % 100:
            return
        frames = os.path.join(base, "frames")
        for name in os.listdir(frames):
            stem = name.split(".", 1)[0]
            if stem.isdigit() and int(stem) <= cutoff:
                os.remove(os.path.join(frames, name))


feed = _Feed()
