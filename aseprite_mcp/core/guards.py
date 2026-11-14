"""Argument guards applied to every tool before it runs.

* Path parameters are confined to ASEPRITE_MCP_ROOTS (see paths.py).
* Size parameters are bounded, so one call cannot make the server build a
  gigantic pixel set in Python (outside the Aseprite timeout), allocate a
  huge canvas, or return megabytes of text into the model's context.
"""
import functools
import inspect
import math

from . import live
from .paths import PATH_PARAMS, PathError, confine

MAX_SIDE = 4096
MAX_READ_AREA = 16384  # same budget read_rows already enforces

# tool name -> {parameter: maximum}. Lower bounds are left to each tool,
# which already reports its own message for them.
LIMITS: dict[str, dict[str, float]] = {
    "create_canvas": {"width": MAX_SIDE, "height": MAX_SIDE},
    "resize_canvas": {"width": MAX_SIDE, "height": MAX_SIDE},
    "crop_canvas": {"width": MAX_SIDE, "height": MAX_SIDE},
    "add_frames": {"count": 1000},
    "duplicate_frame_range": {"times": 100},
    "draw_iso_box": {"w": 512, "d": 512, "h": 512},
    "measure_text": {"size": 512, "bold": 8, "letter_spacing": 64},
    "draw_text": {"size": 512, "bold": 8, "letter_spacing": 64,
                  "outline_width": 8, "shadow_dx": 64, "shadow_dy": 64},
    "get_pixels_rect": {"width": MAX_SIDE, "height": MAX_SIDE},
    "get_composite_rect": {"width": MAX_SIDE, "height": MAX_SIDE},
    "tween_cel_scale_eased": {"start_scale": 64, "end_scale": 64},
}

# tools whose width*height is read back pixel by pixel
AREA_LIMITED = frozenset({"get_pixels_rect", "get_composite_rect"})


def _check_limits(tool: str, arguments: dict) -> str | None:
    for name, hi in LIMITS.get(tool, {}).items():
        value = arguments.get(name)
        if value is None or isinstance(value, bool):
            continue
        if isinstance(value, (int, float)) and not (math.isfinite(value) and abs(value) <= hi):
            return f"{name} must be a finite number no larger than {hi} in magnitude (got {value})"
    if tool in AREA_LIMITED:
        w, h = arguments.get("width"), arguments.get("height")
        if isinstance(w, int) and isinstance(h, int) and w * h > MAX_READ_AREA:
            return (f"Region {w}x{h} is {w * h} pixels; read at most {MAX_READ_AREA} per call "
                    f"(split it into smaller regions)")
    return None


def guard_tool(fn):
    """Wrap a tool so its arguments are checked before it runs.

    functools.wraps sets __wrapped__, which inspect.signature follows, so the
    MCP schema generated from the signature is unchanged. Empty path strings
    pass through: several tools use "" to mean "derive the path".
    """
    sig = inspect.signature(fn)
    path_names = [n for n in sig.parameters if n in PATH_PARAMS]
    if not path_names and fn.__name__ not in LIMITS:
        return fn

    @functools.wraps(fn)
    async def wrapper(*args, **kwargs):
        bound = sig.bind(*args, **kwargs)
        bound.apply_defaults()
        error = _check_limits(fn.__name__, bound.arguments)
        if error:
            return f"Invalid argument: {error}"
        for name in path_names:
            value = bound.arguments.get(name)
            if isinstance(value, str) and value:
                try:
                    bound.arguments[name] = confine(value)
                except PathError as exc:
                    return f"Invalid {name}: {exc}"
        target = bound.arguments.get("target_filename") or bound.arguments.get("filename")
        watch = live.enabled() and isinstance(target, str) and bool(target)
        before = live.fingerprint(target) if watch else None
        result = await fn(*bound.args, **bound.kwargs)
        if watch:
            try:
                live.feed.record(fn.__name__, dict(bound.arguments), target, before)
            except OSError:
                pass  # the live feed must never break a tool
        return result

    return wrapper
