"""Live feed for the Pixel Live viewer: one snapshot per tool call that
actually changed the sprite, announced only after its files exist."""
import json
import os
import time

from conftest import BASE, run

from aseprite_mcp.core import live
from aseprite_mcp.core.captions import caption
from aseprite_mcp.tools import animation, canvas, drawing


def _events(timeout=10.0):
    path = os.path.join(BASE, ".live", "events.jsonl")
    deadline = time.time() + timeout
    while time.time() < deadline:
        if live.feed._queue.empty() and os.path.exists(path):
            time.sleep(0.3)
            with open(path, encoding="utf-8") as fh:
                return [json.loads(line) for line in fh]
        time.sleep(0.05)
    return []


def test_feed_records_changes_only(monkeypatch):
    monkeypatch.setenv("ASEPRITE_MCP_LIVE", "1")
    path = f"{BASE}/live.aseprite"
    run(canvas.create_canvas(8, 8, path))
    run(canvas.add_layer(path, "ink"))
    run(drawing.draw_rows(path, "ink", 1, 1, 1, ["RR", ".R"], {"R": "#ff0000"}))
    run(animation.get_sprite_info(path))  # read-only: no event

    events = [e for e in _events() if e["sprite"].endswith("live.aseprite")]
    assert [e["tool"] for e in events] == ["create_canvas", "add_layer", "draw_rows"]
    assert events[-1]["caption"] == "Pinta 3 píxeles en «ink», frame 1"
    assert events[-1]["frame"] == 1
    for e in events:
        assert os.path.exists(os.path.join(BASE, ".live", e["sheet"]))
        assert os.path.exists(os.path.join(BASE, ".live", e["data"]))
    assert not os.listdir(os.path.join(BASE, ".live", "pending"))


def test_feed_is_off_by_default(monkeypatch):
    monkeypatch.delenv("ASEPRITE_MCP_LIVE", raising=False)
    assert not live.enabled()


def test_unknown_tools_get_a_readable_caption():
    assert caption("some_new_tool", {}) == "Some new tool"
    assert caption("replace_color", {"from_color": "#000", "to_color": "#fff"}) == "Cambia #000 → #fff"
