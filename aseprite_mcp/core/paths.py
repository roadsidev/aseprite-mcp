"""Confine every file path a tool receives to the configured workspace roots.

ASEPRITE_MCP_ROOTS is an os.pathsep-separated list of directories. A path is
accepted only when its fully resolved location (symlinks followed, including
the final component when it exists) lies inside one of those roots. Relative
paths resolve against the first root. Accepted paths come back absolute, so
nothing handed to the Aseprite CLI can be parsed as an option.

With no roots configured every path is refused: the server never touches the
filesystem outside a directory the user chose.
"""
import os

ROOTS_ENV = "ASEPRITE_MCP_ROOTS"

# Tool parameters that name files or directories.
PATH_PARAMS = frozenset({
    "filename",
    "data_filename",
    "image_path",
    "output_directory",
    "output_filename",
    "source_filename",
    "target_filename",
})


class PathError(ValueError):
    pass


def roots() -> list[str]:
    raw = os.getenv(ROOTS_ENV, "")
    return [os.path.realpath(os.path.expanduser(r)) for r in raw.split(os.pathsep) if r.strip()]


def is_within(path: str, allowed: list[str]) -> bool:
    for root in allowed:
        try:
            if os.path.commonpath([path, root]) == root:
                return True
        except ValueError:
            continue
    return False


def confine(path: str, extra_roots: tuple[str, ...] = ()) -> str:
    """Return the resolved absolute path, or raise PathError if it escapes."""
    allowed = roots()
    if not allowed and not extra_roots:
        raise PathError(f"No workspace configured: set {ROOTS_ENV} to the directory sprites live in")
    if "\0" in path:
        raise PathError("Invalid path")
    expanded = os.path.expanduser(path)
    if not os.path.isabs(expanded):
        if not allowed:
            raise PathError(f"Relative path {path!r} needs {ROOTS_ENV}")
        expanded = os.path.join(allowed[0], expanded)
    resolved = os.path.realpath(expanded)
    extra = [os.path.realpath(r) for r in extra_roots]
    if not is_within(resolved, allowed + extra):
        raise PathError(f"Path {path!r} is outside the allowed workspace ({os.pathsep.join(allowed)})")
    return resolved
