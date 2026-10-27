#!/usr/bin/env python3
"""Refuse to overwrite a linked or active native build output; never stop processes."""
import subprocess
import sys
from pathlib import Path


def main():
    app = Path(sys.argv[1]).absolute()
    if app.is_symlink() or app.parent.is_symlink():
        raise SystemExit("Build output must not be a symbolic link.")
    executable = app / "Contents/MacOS/PinPin"
    if executable.is_symlink():
        raise SystemExit("Build executable must not be a symbolic link.")
    if not executable.exists():
        return
    actual = str(executable.resolve())
    opened = subprocess.run(["/usr/sbin/lsof", "-t", actual], capture_output=True, text=True)
    if opened.returncode == 0 and opened.stdout.strip():
        raise SystemExit("Exit the App running from backend/dist/PinPin.app before rebuilding.")
    processes = subprocess.check_output(["/bin/ps", "-axo", "command="], text=True)
    if any(line == actual or line.startswith(actual + " ") for line in processes.splitlines()):
        raise SystemExit("Exit the App running from backend/dist/PinPin.app before rebuilding.")


if __name__ == "__main__":
    main()
