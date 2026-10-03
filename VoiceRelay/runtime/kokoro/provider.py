"""Protocol v1 local inference worker. Stdout contains control JSON only."""

import json
import os
from pathlib import Path
import re
import signal
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import runtime_setup as setup


def serve():
    owner = os.getppid()
    if owner <= 1:
        return  # The Swift parent disappeared before this worker completed startup.
    if os.getpgrp() != os.getpid():
        os.setsid()
    control = os.fdopen(os.dup(sys.stdout.fileno()), "w", buffering=1)
    with open(os.devnull, "w") as sink:
        os.dup2(sink.fileno(), 1)
        os.dup2(sink.fileno(), 2)

    def watch_owner():
        while True:
            if os.getppid() != owner:
                os.killpg(os.getpgrp(), signal.SIGKILL)
            time.sleep(0.2)

    threading.Thread(target=watch_owner, daemon=True).start()

    def reply(request_id, **body):
        control.write(json.dumps({"protocol": 1, "id": request_id, **body}) + "\n")
        control.flush()

    reply(0, kind="hello", pid=os.getpid())
    model = mx = None
    selected = setup.selection()
    for line in iter(lambda: sys.stdin.buffer.readline(1_048_577), b""):
        request_id = 0
        try:
            if len(line) > 1_048_576 or not line.endswith(b"\n"):
                raise ValueError("invalid_request")
            request = json.loads(line)
            request_id = request["id"]
            if request["protocol"] != 1 or not isinstance(request_id, int):
                raise ValueError("invalid_request")
            if request["command"] == "prepare":
                setup.validate_packages(selected)
                snapshot = setup.validate_assets(setup.PROJECT, selected)
                import spacy
                if not spacy.util.is_package("en_core_web_sm"):
                    raise ValueError("missing_assets")

                def refuse_download(*args, **kwargs):
                    raise ValueError("missing_assets")

                # Misaki can otherwise invoke spaCy's downloader lazily. Inference
                # must fail locally; explicit setup owns all asset acquisition.
                spacy.cli.download = refuse_download
                import mlx.core as mx
                from mlx_audio.tts.utils import load_model

                if model is None:
                    model = load_model(snapshot, model_type="kokoro")
                    mx.eval(model.parameters())
                reply(request_id, kind="ready")
            elif request["command"] == "synthesize":
                if model is None:
                    raise ValueError("not_prepared")
                text, voice, speed = request["text"], request["voice"], request["speed"]
                if not isinstance(text, str) or not text.strip() or len(text) > 200_000:
                    raise ValueError("invalid_request")
                if not isinstance(voice, str) or not re.fullmatch(r"[ab][fm]_[a-z0-9_]+", voice):
                    raise ValueError("invalid_voice")
                if request["language"] not in ["en", "en-US", "en-GB"] or not 0.25 <= speed <= 4:
                    raise ValueError("invalid_request")
                voice_file = setup.confined(setup.PROJECT, snapshot.relative_to(setup.PROJECT) / "voices" / (voice + ".safetensors"))
                if not voice_file.is_file():
                    raise ValueError("missing_assets")
                manifest = json.loads((snapshot / "asset-manifest.json").read_text())
                if manifest.get("revision") != selected["revision"] or manifest.get("voices", {}).get(voice) != setup.digest(voice_file):
                    raise ValueError("missing_assets")
                output = Path(request["directory"]).resolve()
                if not output.is_dir():
                    raise ValueError("invalid_request")
                import numpy as np
                import soundfile as sf

                language_code = "b" if voice.startswith("b") else "a"
                # This pinned runtime otherwise catches eSpeak initialization
                # errors and silently skips out-of-dictionary words.
                if model._get_pipeline(language_code).g2p.fallback is None:
                    raise ValueError("missing_assets")
                chunks = []
                for result in model.generate(text=text, voice=str(voice_file), speed=speed,
                                             lang_code=language_code):
                    mx.eval(result.audio)
                    samples = np.asarray(result.audio, dtype=np.float32).reshape(-1)
                    if result.sample_rate != 24000 or not np.isfinite(samples).all():
                        raise ValueError("invalid_audio")
                    if samples.size:
                        chunks.append(samples)
                if not chunks:
                    raise ValueError("empty_audio")
                # Engine chunks concatenate without extra gaps, matching the benchmark.
                # The Swift pipeline applies its own inter-request gaps and encoding.
                with tempfile.NamedTemporaryFile(prefix=".segment-", suffix=".wav", dir=output, delete=False) as handle:
                    temporary = Path(handle.name)
                try:
                    sf.write(temporary, np.concatenate(chunks), 24000, subtype="FLOAT", format="WAV")
                    with temporary.open("rb") as handle:
                        os.fsync(handle.fileno())
                    os.replace(temporary, output / "segment.wav")
                    descriptor = os.open(output, os.O_RDONLY)
                    try:
                        os.fsync(descriptor)
                    finally:
                        os.close(descriptor)
                finally:
                    temporary.unlink(missing_ok=True)
                reply(request_id, kind="result", article_id=request["article_id"],
                      chunk_index=request["chunk_index"], block_indices=request["block_indices"],
                      artifacts=[{"file": "segment.wav", "sample_rate": 24000, "channels": 1, "format": "wav"}])
            else:
                raise ValueError("invalid_request")
        except Exception as error:
            # Never emit text, voice paths, third-party messages, or tracebacks.
            code = str(error) if isinstance(error, ValueError) and str(error) in {
                "invalid_request", "invalid_voice", "not_prepared", "missing_assets", "invalid_audio", "empty_audio"
            } else ("setup_failed" if model is None else "synthesis_failed")
            reply(request_id, kind="error", code=code)


if __name__ == "__main__":
    serve()
