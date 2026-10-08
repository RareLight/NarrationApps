"""Protocol v1 local inference worker. Stdout contains control JSON only."""

from concurrent.futures import ThreadPoolExecutor
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


def phonemes(pipeline, text):
    """Same English splitting/G2P as pinned mlx-audio 0.5.7, on CPU only."""
    start = time.perf_counter()
    result = []
    for graphemes in re.split(r"\n+", text.strip()):
        if not graphemes.strip():
            continue
        _, tokens = pipeline.g2p(graphemes)
        for _, ps, _ in pipeline.en_tokenize(tokens):
            if ps:
                result.append(ps[:510])
    return result, time.perf_counter() - start


class PronunciationAhead:
    """One CPU G2P thread and at most one future request; never runs MLX."""
    def __init__(self):
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="pronunciation")
        self.pending = None

    def take(self, pipeline, text, language):
        key = (text, language)
        pending, self.pending = self.pending, None
        if pending is not None and pending[0] == key:
            return pending[1].result()
        if pending is not None:
            pending[1].cancel()
        return self.executor.submit(phonemes, pipeline, text).result()

    def schedule(self, pipeline, text, language):
        if self.pending is not None:
            self.pending[1].cancel()
        self.pending = ((text, language), self.executor.submit(phonemes, pipeline, text))

    def close(self):
        if self.pending is not None:
            self.pending[1].cancel()
        self.pending = None
        self.executor.shutdown(wait=True, cancel_futures=True)


class VerifiedVoice:
    """Keep one authenticated voice tensor; reverify changed files/manifests."""
    def __init__(self):
        self.key = self.pack = None

    @staticmethod
    def stamp(path):
        st = path.stat()
        return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)

    def load(self, pipeline, voice_file, manifest_file, selected, voice):
        key = (str(voice_file), self.stamp(voice_file), self.stamp(manifest_file))
        if key != self.key:
            manifest = json.loads(manifest_file.read_text())
            if manifest.get("revision") != selected["revision"] or manifest.get("voices", {}).get(voice) != setup.digest(voice_file):
                raise ValueError("missing_assets")
            pipeline.voices.clear()
            pack = pipeline.load_voice(str(voice_file))
            # Detect concurrent changes rather than caching unverifiable bytes.
            if key != (str(voice_file), self.stamp(voice_file), self.stamp(manifest_file)):
                raise ValueError("missing_assets")
            self.key, self.pack = key, pack
        return self.pack


def infer_segments(model, pipeline, pack, parts, speed, np):
    """Same model/voice/speed/math as generate(), without unused timestamps
    or its per-segment allocator/voice-cache resets."""
    start = time.perf_counter()
    chunks = []
    for ps in parts:
        output = pipeline.infer(model, ps, pack, speed)
        samples = np.asarray(output.audio[0], dtype=np.float32).reshape(-1)
        if not np.isfinite(samples).all():
            raise ValueError("invalid_audio")
        if samples.size:
            chunks.append(samples)
    if not chunks:
        raise ValueError("empty_audio")
    return np.concatenate(chunks), time.perf_counter() - start


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
    ahead = PronunciationAhead()
    verified_voice = VerifiedVoice()
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

                # Bound reusable allocator memory; active model tensors remain unchanged.
                mx.set_cache_limit(256 * 1024 * 1024)

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
                output = Path(request["directory"]).resolve()
                if not output.is_dir():
                    raise ValueError("invalid_request")
                import numpy as np
                import soundfile as sf

                language_code = "b" if voice.startswith("b") else "a"
                # This pinned runtime otherwise catches eSpeak initialization
                # errors and silently skips out-of-dictionary words.
                pipeline = model._get_pipeline(language_code)
                if pipeline.g2p.fallback is None:
                    raise ValueError("missing_assets")
                pack = verified_voice.load(pipeline, voice_file, snapshot / "asset-manifest.json", selected, voice)
                parts, pronunciation_seconds = ahead.take(pipeline, text, language_code)
                next_request = request.get("lookahead")
                if next_request is not None:
                    next_text = next_request.get("text")
                    next_voice = next_request.get("voice")
                    if (not isinstance(next_text, str) or not next_text.strip() or len(next_text) > 200_000
                            or not isinstance(next_voice, str) or not re.fullmatch(r"[ab][fm]_[a-z0-9_]+", next_voice)
                            or next_request.get("language") not in ["en", "en-US", "en-GB"]):
                        raise ValueError("invalid_request")
                    next_language = "b" if next_voice.startswith("b") else "a"
                    next_pipeline = model._get_pipeline(next_language)
                    if next_pipeline.g2p.fallback is None:
                        raise ValueError("missing_assets")
                    ahead.schedule(next_pipeline, next_text, next_language)
                samples, inference_seconds = infer_segments(model, pipeline, pack, parts, speed, np)
                if model.config.sample_rate != 24000:
                    raise ValueError("invalid_audio")
                # Engine chunks concatenate without extra gaps, matching the benchmark.
                # The Swift pipeline applies its own inter-request gaps and encoding.
                write_start = time.perf_counter()
                with tempfile.NamedTemporaryFile(prefix=".segment-", suffix=".wav", dir=output, delete=False) as handle:
                    temporary = Path(handle.name)
                try:
                    sf.write(temporary, samples, 24000, subtype="FLOAT", format="WAV")
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
                timings = ({"pronunciation": pronunciation_seconds, "inference": inference_seconds,
                            "WAV write": time.perf_counter() - write_start} if request.get("diagnostics") is True else {})
                reply(request_id, timings=timings, kind="result", article_id=request["article_id"],
                      chunk_index=request["chunk_index"], block_indices=request["block_indices"],
                      artifacts=[{"file": "segment.wav", "sample_rate": 24000, "channels": 1, "format": "wav"}])
            else:
                raise ValueError("invalid_request")
        except Exception as error:
            # Never emit text, voice paths, third-party messages, or tracebacks.
            code = str(error) if isinstance(error, ValueError) and str(error) in {
                "invalid_request", "invalid_voice", "not_prepared", "missing_assets", "invalid_audio", "empty_audio"
            } else ("setup_failed" if model is None else "synthesis_failed")
            detail = type(error).__name__
            if detail in {"MemoryError", "OSError", "RuntimeError", "TimeoutError", "OverflowError", "EOFError"}:
                reply(request_id, kind="error", code=code, detail=detail)
            else:
                reply(request_id, kind="error", code=code)
    ahead.close()


if __name__ == "__main__":
    serve()
