import math
import subprocess
import tempfile
import os


def lua_escape(s: str) -> str:
    """Escape a string for safe embedding inside a Lua double-quoted string literal."""
    return (
        s.replace("\\", "\\\\")
         .replace('"', '\\"')
         .replace("\n", "\\n")
         .replace("\r", "\\r")
         .replace("\0", "\\0")
    )


def reject_traversal(path: str) -> str | None:
    """Reject parent-directory traversal in a user-supplied path.

    Returns an error message string when the path contains a `..`
    component, or None when the path looks safe.

    The check works on normalized path components, so it does not
    false-positive on filenames like `foo..bar.aseprite` (the previous
    `'..' in path` substring check did). Absolute paths and tilde
    expansion are not rejected here: this function targets traversal
    only, not access scoping.
    """
    parts = os.path.normpath(path).replace("\\", "/").split("/")
    if ".." in parts:
        return "Invalid filename: parent directory traversal not allowed"
    return None


DEFAULT_TIMEOUT_SECONDS = 60.0

# Every Aseprite CLI option the tools pass. Anything else starting with "-"
# (for instance a file literally named "--script=x.lua") is refused.
_ALLOWED_OPTIONS = frozenset({
    "--all-layers",
    "--batch",
    "--data",
    "--format",
    "--frame-range",
    "--layer",
    "--list-layers",
    "--list-tags",
    "--save-as",
    "--scale",
    "--script",
    "--shape-padding",
    "--sheet",
    "--sheet-type",
    "--split-layers",
    "--tag",
})


def command_timeout() -> float:
    """Seconds an Aseprite run may take, from ASEPRITE_TIMEOUT_SECONDS.

    A missing, non-numeric, non-finite or non-positive value falls back to the
    default.
    """
    try:
        timeout = float(os.getenv("ASEPRITE_TIMEOUT_SECONDS", DEFAULT_TIMEOUT_SECONDS))
    except ValueError:
        return DEFAULT_TIMEOUT_SECONDS
    return timeout if math.isfinite(timeout) and timeout > 0 else DEFAULT_TIMEOUT_SECONDS


class AsepriteCommand:
    """Helper class for running Aseprite commands."""

    @staticmethod
    def run_command(args):
        """Run an Aseprite command with proper error handling.

        The run is killed after ASEPRITE_TIMEOUT_SECONDS (60 by default), so one
        stuck Aseprite process cannot block the server forever. It never reads
        stdin: the server's own stdin is the MCP stdio pipe.

        Args:
            args: List of command arguments

        Returns:
            tuple: (success, output) where success is a boolean and output is the command output
        """
        timeout = command_timeout()
        exe = os.getenv("ASEPRITE_PATH", "")
        if not os.path.isabs(exe) or not os.access(exe, os.X_OK):
            return False, "ASEPRITE_PATH must be the absolute path of the Aseprite executable"
        for arg in args:
            if arg.startswith("-") and arg not in _ALLOWED_OPTIONS:
                return False, f"Refusing unexpected Aseprite option {arg!r}"
        try:
            cmd = [exe] + args
            result = subprocess.run(
                cmd,
                check=True,
                capture_output=True,
                text=True,
                stdin=subprocess.DEVNULL,
                timeout=timeout,
            )
            return True, result.stdout
        except subprocess.CalledProcessError as e:
            return False, e.stderr
        except subprocess.TimeoutExpired:
            return False, (
                f"Aseprite did not finish within {timeout:g}s and was stopped. "
                "Output files may already have been written. "
                "Set ASEPRITE_TIMEOUT_SECONDS to allow longer runs."
            )
    
    @staticmethod
    def execute_lua_script(script_content, filename=None):
        """Execute a Lua script in Aseprite.
        
        Args:
            script_content: Lua script code to execute
            filename: Optional filename to open before executing script
            
        Returns:
            tuple: (success, output)
        """
        # Create a temporary file for the script
        with tempfile.NamedTemporaryFile(suffix='.lua', delete=False, mode='w') as tmp:
            tmp.write(script_content)
            script_path = tmp.name
        
        try:
            args = ["--batch"]
            if filename and os.path.exists(filename):
                args.append(os.path.abspath(filename))
            args.extend(["--script", script_path])
            
            success, output = AsepriteCommand.run_command(args)
            return success, output
        finally:
            # Clean up the temporary script file
            os.remove(script_path)

    @staticmethod
    def execute_lua_script_checked(script_content, filename=None):
        """Execute a Lua script and surface in-script errors.

        Scripts using this helper signal failure by printing a line
        starting with "ERROR:" (batch-mode scripts cannot affect the
        process exit code from Lua).

        Returns:
            tuple: (success, output) where output is the error message
            when an ERROR: line was printed, or the raw stdout otherwise.
        """
        success, output = AsepriteCommand.execute_lua_script(script_content, filename)
        if not success:
            return False, output
        for line in output.splitlines():
            if line.startswith("ERROR:"):
                return False, line[len("ERROR:"):]
        return True, output
