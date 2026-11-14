"""Regression tests for the fork's hardening: each one replays an attack
from the security audit and checks it no longer works.

Payloads try to create MARKER; a test fails if it appears.
"""
import os
import shutil

import pytest
from conftest import BASE, run

import aseprite_mcp
from aseprite_mcp.tools import animation, drawing, pixel_read, quality

MARKER = f"{BASE}/pwned"


@pytest.fixture(autouse=True)
def no_marker():
    if os.path.exists(MARKER):
        os.remove(MARKER)
    yield
    assert not os.path.exists(MARKER), "payload executed"


def test_draw_pixels_rejects_code_in_coordinates(sprite):
    payload = f"0,0,0) os.execute('touch {MARKER}') img:putPixel(0"
    out = run(drawing.draw_pixels(sprite, [{"x": payload, "y": 0, "color": "#000000"}]))
    assert out.startswith("Invalid pixel coordinates")
    out = run(drawing.draw_pixels_at(sprite, "body", 1, [{"x": 0, "y": payload, "color": "#000000"}]))
    assert out.startswith("Invalid pixel coordinates")


def test_draw_pixels_still_accepts_integral_numbers(sprite):
    out = run(drawing.draw_pixels(sprite, [{"x": 1, "y": 2.0, "color": "#ffffff"}]))
    assert "successfully" in out


def test_audit_animation_escapes_layer_names(sprite):
    breakout = f'x"}}}} os.execute("touch {MARKER}") local _={{{{"'
    run(quality.audit_animation(sprite, overlap_pairs=[f"{breakout},y"]))
    run(quality.audit_animation(
        sprite, layer_frame_ranges=[f'X"..(function() os.execute("touch {MARKER}") return "" end)()..":1-1']))


def test_reports_stay_valid_json_with_hostile_layer_names(sprite):
    out = run(quality.validate_scene(sprite, required_layers=['quote"name', "line\nbreak"]))
    assert "quote" in out and "\n" not in out.split("{", 1)[-1].split("missing_layers")[-1][:40]


def test_paths_outside_the_workspace_are_refused():
    out = run(animation.get_sprite_info("/etc/hosts"))
    assert "outside the allowed workspace" in out
    out = run(animation.get_sprite_info(f"{BASE}/../../etc/hosts"))
    assert "outside the allowed workspace" in out


def test_symlinks_cannot_escape_the_workspace():
    link = f"{BASE}/escape.png"
    if os.path.lexists(link):
        os.remove(link)
    os.symlink("/System/Library/Desktop Pictures", link)
    try:
        assert "outside the allowed workspace" in run(animation.get_sprite_info(link))
    finally:
        os.remove(link)


def test_filenames_cannot_become_cli_options(sprite):
    script = f"{BASE}/payload.lua"
    with open(script, "w") as fh:
        fh.write(f'os.execute("touch {MARKER}")\n')
    decoy = f"{BASE}/--script=payload.lua"
    shutil.copy(sprite, decoy)
    try:
        # Relative names resolve inside the root and reach Aseprite absolute.
        run(animation.get_sprite_info("--script=payload.lua"))
    finally:
        os.remove(decoy)
        os.remove(script)


def test_oversized_work_is_rejected_before_it_starts(sprite):
    out = run(drawing.draw_iso_box(sprite, "body", 1, 0, 0, 0, 100000, 100000, 1, "#fff", "#ccc", "#999"))
    assert out.startswith("Invalid argument")
    out = run(pixel_read.get_pixels_rect(sprite, 0, 0, 4096, 4096))
    assert out.startswith("Invalid argument")
    out = run(drawing.draw_iso_box(sprite, "body", 1, 0, 0, 0, float("nan"), 1, 1, "#fff", "#ccc", "#999"))
    assert out.startswith("Invalid argument")


def test_dangerous_tools_are_not_registered():
    names = {tool.name for tool in aseprite_mcp.mcp._tool_manager.list_tools()}
    assert "run_lua_script" not in names
    assert "start_preview_server" not in names
    assert "draw_pixels" in names


def test_missing_workspace_refuses_everything(monkeypatch):
    monkeypatch.delenv("ASEPRITE_MCP_ROOTS")
    assert "No workspace configured" in run(animation.get_sprite_info(f"{BASE}/x.aseprite"))
