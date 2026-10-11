#!/usr/bin/env python3
"""Install an already verified staged macOS app, preserving the old app on failure."""
import ctypes
import os
from pathlib import Path
import sys


def install(staged: Path, destination: Path) -> None:
    if staged.is_symlink() or not staged.is_dir() or destination.is_symlink():
        raise ValueError("Packaging requires ordinary app directories")
    if staged.stat().st_dev != destination.parent.stat().st_dev:
        raise ValueError("Packaging requires the same filesystem")
    if destination.exists():
        if not destination.is_dir():
            raise ValueError("The package destination is not an app directory")
        rename = ctypes.CDLL(None, use_errno=True).renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        # Darwin RENAME_SWAP: failure changes neither bundle.
        if rename(os.fsencode(staged), os.fsencode(destination), 2) != 0:
            raise OSError(ctypes.get_errno(), "Atomic app package exchange failed")
    else:
        os.rename(staged, destination)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: install-app.py staged.app destination.app")
    install(Path(sys.argv[1]), Path(sys.argv[2]))
