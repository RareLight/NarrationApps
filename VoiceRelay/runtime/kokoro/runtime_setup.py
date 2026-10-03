"""Explicit, project-owned setup; no imports of MLX or the benchmark application."""

import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys


PROJECT = Path(__file__).resolve().parents[2]
SOURCE = PROJECT / "runtime" / "kokoro"


def confined(root, relative):
    root = Path(root).resolve()
    path = root / relative
    if not path.resolve().is_relative_to(root):
        raise ValueError("Runtime/model path escapes the project; remove the external symlink.")
    return path


def layout(root, revision):
    return {
        "python": confined(root, ".runtime/kokoro/.venv/bin/python"),
        "managed_python": confined(root, ".runtime/python"),
        "cache": confined(root, ".runtime/cache"),
        "temporary": confined(root, ".runtime/tmp"),
        "models": confined(root, "models"),
        "snapshot": confined(root, f"models/kokoro/{revision}"),
    }


def reject_external_links(root, directory):
    root = Path(root).resolve()
    confined(root, directory.relative_to(root))
    if directory.is_dir():
        for path in directory.rglob("*"):
            if path.is_symlink():
                confined(root, path.relative_to(root))


def environment(root, *, download=False, inherited=None):
    root = Path(root).resolve()
    env = dict(os.environ if inherited is None else inherited)
    for key in list(env):
        if key.startswith(("UV_", "PIP_")):
            env.pop(key)
    for key in ["PYTHONPATH", "PYTHONHOME", "VIRTUAL_ENV"]:
        env.pop(key, None)
    relative = {
        "UV_CACHE_DIR": ".runtime/cache/uv",
        "UV_PYTHON_INSTALL_DIR": ".runtime/python",
        "UV_PYTHON_BIN_DIR": ".runtime/bin",
        "PIP_CACHE_DIR": ".runtime/cache/pip",
        "XDG_CACHE_HOME": ".runtime/cache/xdg",
        "XDG_CONFIG_HOME": ".runtime/config",
        "XDG_DATA_HOME": ".runtime/data",
        "HF_HOME": ".runtime/cache/huggingface",
        "HF_HUB_CACHE": "models/huggingface/hub",
        "HUGGINGFACE_HUB_CACHE": "models/huggingface/hub",
        "HF_ASSETS_CACHE": ".runtime/cache/huggingface/assets",
        "HF_XET_CACHE": ".runtime/cache/huggingface/xet",
        "TRANSFORMERS_CACHE": "models/huggingface/hub",
        "NLTK_DATA": ".runtime/data/nltk",
        "TMPDIR": ".runtime/tmp",
    }
    env.update({key: str(confined(root, value)) for key, value in relative.items()})
    env.update({
        "PYTHONNOUSERSITE": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
        "UV_PYTHON_DOWNLOADS": "automatic" if download else "never",
        "HF_HUB_OFFLINE": "0" if download else "1",
        "TRANSFORMERS_OFFLINE": "0" if download else "1",
        "HF_HUB_DISABLE_TELEMETRY": "1",
        "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
    })
    return env


def selection():
    return json.loads((SOURCE / "selection.json").read_text())


def python_downloads_metadata(selected):
    """Use a checked-in catalog instead of the installed uv's frozen catalog."""
    path = confined(PROJECT, "runtime/kokoro/python-downloads.json")
    try:
        catalog = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise ValueError("Pinned Python download metadata missing or invalid; restore runtime/kokoro/python-downloads.json.") from error
    key = f"cpython-{selected['python']}-darwin-aarch64-none"
    entry = catalog.get(key) if isinstance(catalog, dict) else None
    if not isinstance(entry, dict):
        raise ValueError("Python download metadata does not match the selected Python pin.")
    expected = {
        "name": "cpython", "arch": {"family": "aarch64", "variant": None},
        "os": "darwin", "libc": "none", "prerelease": None, "variant": None,
        **dict(zip(["major", "minor", "patch"], map(int, selected["python"].split(".")))),
    }
    build = entry.get("build", "")
    checksum = entry.get("sha256", "")
    if (len(catalog) != 1 or any(entry.get(name) != value for name, value in expected.items())
            or not isinstance(build, str) or not re.fullmatch(r"[0-9]{8}", build)
            or not isinstance(checksum, str) or not re.fullmatch(r"[0-9a-f]{64}", checksum)):
        raise ValueError("Pinned Python download metadata has incompatible platform/version or missing SHA-256.")
    url = ("https://github.com/astral-sh/python-build-standalone/releases/download/"
           f"{build}/cpython-{selected['python']}%2B{build}-aarch64-apple-darwin-install_only_stripped.tar.gz")
    if entry.get("url") != url:
        raise ValueError("Pinned Python download URL does not match its release metadata.")
    return path


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def validate_assets(root, selected):
    paths = layout(root, selected["revision"])
    snapshot = paths["snapshot"]
    for name, expected in selected["sha256"].items():
        path = confined(root, snapshot.relative_to(root) / name)
        if not path.is_file() or digest(path) != expected:
            raise ValueError("Pinned model/config/voice missing or incompatible; run explicit setup.")
    with (snapshot / "kokoro-v1_0.safetensors").open("rb") as handle:
        prefix = handle.read(8)
        if len(prefix) != 8:
            raise ValueError("Invalid model header.")
        size = struct.unpack("<Q", prefix)[0]
        if size > 8 * 1024 * 1024:
            raise ValueError("Model header exceeds the inspection limit.")
        tensors = json.loads(handle.read(size))
    tensors.pop("__metadata__", None)
    if len(tensors) != selected["stored_tensor_count"] or any(
        value.get("dtype") != selected["stored_tensor_dtype"] for value in tensors.values()
    ):
        raise ValueError("Model tensors differ from the selected checkpoint; do not cast its weights.")
    return snapshot


def validate_packages(selected):
    if sys.version.split()[0] != selected["python"]:
        raise ValueError("Pinned Python version is required; rerun explicit setup.")
    for name, version in selected["packages"].items():
        if importlib.metadata.version(name) != version:
            raise ValueError("Pinned runtime package version mismatch; rerun explicit setup.")


def retain_notices(root):
    destination = confined(root, ".runtime/kokoro/notices")
    destination.mkdir(parents=True, exist_ok=True)
    inventory = []
    for distribution in sorted(importlib.metadata.distributions(), key=lambda d: d.metadata["Name"].lower()):
        name, version = distribution.metadata["Name"], distribution.version
        saved = []
        for file in distribution.files or []:
            if any(part.lower() in {"licenses", "license", "licence", "copying", "notice"}
                   or part.lower().startswith(("license.", "licence.", "copying.", "notice.")) for part in file.parts):
                source = Path(distribution.locate_file(file))
                if not source.is_file() or not source.resolve().is_relative_to(Path(root).resolve()):
                    continue
                target = confined(root, Path(".runtime/kokoro/notices") / name / version / file)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
                saved.append(str(target.relative_to(destination)))
        inventory.append({"name": name, "version": version, "license_files": saved,
                          "license_expression": distribution.metadata.get("License-Expression"),
                          "license": distribution.metadata.get("License")})
    (destination / "inventory.json").write_text(json.dumps(inventory, indent=2, sort_keys=True))


def asset_worker(download):
    selected = selection()
    validate_packages(selected)
    paths = layout(PROJECT, selected["revision"])
    if download:
        reject_external_links(PROJECT, paths["models"])
        from huggingface_hub import snapshot_download

        snapshot_download(
            repo_id=selected["model"], revision=selected["revision"],
            local_dir=paths["snapshot"], cache_dir=confined(PROJECT, "models/huggingface/hub"),
            allow_patterns=["config.json", "*.safetensors", "voices/*.safetensors", "README.md", "LICENSE*", "NOTICE*"],
            token=False,
        )
    snapshot = validate_assets(PROJECT, selected)
    manifest = confined(PROJECT, snapshot.relative_to(PROJECT) / "asset-manifest.json")
    if download:
        voices = {path.stem: digest(path) for path in sorted((snapshot / "voices").glob("*.safetensors"))}
        pending = snapshot / ".asset-manifest.pending"
        with pending.open("w") as handle:
            os.chmod(pending, 0o600)
            json.dump({"schema_version": 1, "revision": selected["revision"], "voices": voices}, handle, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(pending, manifest)
        retain_notices(PROJECT)
    if not manifest.is_file():
        raise ValueError("Pinned voice manifest missing; run explicit setup.")
    data = json.loads(manifest.read_text())
    if data.get("revision") != selected["revision"] or data.get("voices", {}).get("af_heart") != selected["sha256"]["voices/af_heart.safetensors"]:
        raise ValueError("Voice provenance manifest is incompatible; run explicit setup.")
    print(json.dumps({"ready": True, "model": selected["model"], "revision": selected["revision"],
                      "snapshot": str(snapshot), "tensor_dtype": selected["stored_tensor_dtype"]}))


def run(command, *, env, timeout, stage):
    try:
        subprocess.run(command, env=env, cwd=PROJECT, check=True, timeout=timeout)
    except subprocess.CalledProcessError as error:
        raise ValueError(f"{stage} failed (exit {error.returncode}); see the tool output above.") from error
    except subprocess.TimeoutExpired as error:
        raise ValueError(f"{stage} timed out after {timeout} seconds; rerun explicit setup/check.") from error


def main(argv=None):
    parser = argparse.ArgumentParser(description="Project-local Kokoro runtime preparation; no synthesis.")
    parser.add_argument("command", choices=["paths", "check", "setup", "_asset-check", "_asset-download"])
    parser.add_argument("--download", action="store_true")
    args = parser.parse_args(argv)
    if args.download and args.command != "setup":
        parser.error("--download is only valid with setup")
    selected = selection()
    paths = layout(PROJECT, selected["revision"])
    if args.command == "paths":
        print(json.dumps({key: str(value) for key, value in paths.items()}, indent=2))
        return 0
    if args.command in ["_asset-check", "_asset-download"]:
        if Path(sys.executable).resolve() != paths["python"].resolve() or not paths["python"].exists():
            raise ValueError("Asset operations require the project-owned virtual environment.")
        if args.command == "_asset-download" and os.environ.get("VOICERELAY_EXPLICIT_DOWNLOAD") != "1":
            raise ValueError("Downloads require the explicit setup --download flow.")
        asset_worker(args.command == "_asset-download")
        return 0
    if args.command == "check":
        if not paths["python"].is_file():
            raise ValueError("Project-local runtime missing. Run python3 runtime/kokoro/runtime_setup.py setup --download.")
        run([str(paths["python"]), "-I", "-B", str(Path(__file__).resolve()), "_asset-check"],
            env=environment(PROJECT), timeout=120, stage="Project-local runtime check")
        return 0
    if not args.download:
        raise ValueError("Setup requires --download; no runtime or model download was started.")
    if sys.platform != "darwin" or os.uname().machine != "arm64":
        raise ValueError("The selected runtime requires an Apple Silicon Mac.")
    uv = shutil.which("uv")
    if not uv:
        raise ValueError("uv is required for explicit setup; install it before continuing.")
    metadata = python_downloads_metadata(selected)
    env = environment(PROJECT, download=True)
    env["VOICERELAY_EXPLICIT_DOWNLOAD"] = "1"
    reject_external_links(PROJECT, confined(PROJECT, ".runtime"))
    reject_external_links(PROJECT, paths["models"])
    for name in ["cache", "temporary", "models", "managed_python"]:
        paths[name].mkdir(parents=True, exist_ok=True)
    run([uv, "--no-config", "python", "install", selected["python"], "--no-bin",
         "--python-downloads-json-url", str(metadata)], env=env, timeout=600,
        stage="Project-local Python installation")
    if not paths["python"].exists():
        run([uv, "--no-config", "venv", "--managed-python", "--no-python-downloads", "--python", selected["python"],
             str(paths["python"].parent.parent)], env=env, timeout=120, stage="Project-local virtual environment creation")
    # docopt 0.6.2 is source-only (via num2words). Keep all other packages
    # wheel-only and constrain its isolated build dependencies to the same pins.
    run([uv, "--no-config", "pip", "sync", "--python", str(paths["python"]), "--require-hashes", "--only-binary", ":all:",
         "--no-binary", "docopt", "--build-constraints", str(SOURCE / "requirements.lock"),
         str(SOURCE / "requirements.lock")], env=env, timeout=1800, stage="Pinned package installation")
    run([str(paths["python"]), "-I", "-B", str(Path(__file__).resolve()), "_asset-download"], env=env, timeout=1800,
        stage="Pinned model/voice preparation")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, subprocess.SubprocessError, importlib.metadata.PackageNotFoundError) as error:
        # Avoid third-party tracebacks/tokens; setup tools retain their own progress output.
        print(f"Kokoro setup unavailable: {error if isinstance(error, ValueError) else type(error).__name__}", file=sys.stderr)
        raise SystemExit(2)
