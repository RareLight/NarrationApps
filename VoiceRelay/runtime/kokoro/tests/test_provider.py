"""CPU-only adapter tests; no model load, Metal inference, network or speech."""
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SOURCE))
import provider


class Pipeline:
    def __init__(self):
        self.voices = {}
        self.g2p = self.g2p_impl
        self.calls = []
        self.loaded = 0
        self.inferred = []

    def g2p_impl(self, text):
        self.calls.append((text, threading.get_ident()))
        return None, text.split('|')

    def en_tokenize(self, tokens):
        for value in tokens:
            yield '', value, []

    def load_voice(self, path):
        self.loaded += 1
        self.voices[path] = self.loaded
        return self.loaded

    def infer(self, model, ps, pack, speed):
        import numpy as np
        self.inferred.append((ps, pack, speed, threading.get_ident()))
        return SimpleNamespace(audio=np.array([[len(ps), speed]], dtype=np.float32))


class ProviderTests(unittest.TestCase):
    def test_same_splitting_order_empty_segments_and_510_limit(self):
        pipeline = Pipeline()
        parts, duration = provider.phonemes(pipeline, '\nhello||world\n\n' + 'a' * 520)
        self.assertEqual(parts, ['hello', 'world', 'a' * 510])
        self.assertGreaterEqual(duration, 0)

    def test_lookahead_is_reused_and_all_g2p_uses_one_cpu_thread(self):
        pipeline = Pipeline()
        ahead = provider.PronunciationAhead()
        self.addCleanup(ahead.close)
        current, _ = ahead.take(pipeline, 'one', 'a')
        ahead.schedule(pipeline, 'two|three', 'a')
        following, _ = ahead.take(pipeline, 'two|three', 'a')
        self.assertEqual(current + following, ['one', 'two', 'three'])
        self.assertEqual([text for text, _ in pipeline.calls], ['one', 'two|three'])
        self.assertEqual(len(set(thread for _, thread in pipeline.calls)), 1)
        self.assertNotEqual(pipeline.calls[0][1], threading.get_ident())
        self.assertIsNone(ahead.pending)

    def test_mismatched_lookahead_is_not_used(self):
        pipeline = Pipeline()
        ahead = provider.PronunciationAhead()
        self.addCleanup(ahead.close)
        ahead.schedule(pipeline, 'obsolete', 'a')
        self.assertEqual(ahead.take(pipeline, 'current', 'b')[0], ['current'])
        self.assertIsNone(ahead.pending)

    def test_g2p_error_surfaces_when_its_request_is_consumed(self):
        pipeline = Pipeline()
        pipeline.g2p = lambda _: (_ for _ in ()).throw(ValueError('missing_assets'))
        ahead = provider.PronunciationAhead()
        self.addCleanup(ahead.close)
        ahead.schedule(pipeline, 'one', 'a')
        with self.assertRaisesRegex(ValueError, 'missing_assets'):
            ahead.take(pipeline, 'one', 'a')

    def test_voice_reuse_rechecks_changed_manifest_and_voice(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            voice = root / 'af_heart.safetensors'
            voice.write_bytes(b'fixture voice')
            manifest = root / 'asset-manifest.json'
            value = {'revision': 'test', 'voices': {'af_heart': provider.setup.digest(voice)}}
            manifest.write_text(json.dumps(value))
            pipeline = Pipeline()
            cache = provider.VerifiedVoice()
            with patch.object(provider.setup, 'digest', wraps=provider.setup.digest) as digest:
                self.assertEqual(cache.load(pipeline, voice, manifest, {'revision': 'test'}, 'af_heart'), 1)
                self.assertEqual(cache.load(pipeline, voice, manifest, {'revision': 'test'}, 'af_heart'), 1)
                self.assertEqual(digest.call_count, 1)
                voice.write_bytes(b'changed voice')
                with self.assertRaisesRegex(ValueError, 'missing_assets'):
                    cache.load(pipeline, voice, manifest, {'revision': 'test'}, 'af_heart')
                value['voices']['af_heart'] = provider.setup.digest(voice)
                manifest.write_text(json.dumps(value))
                self.assertEqual(cache.load(pipeline, voice, manifest, {'revision': 'test'}, 'af_heart'), 2)
                value['revision'] = 'wrong'
                manifest.write_text(json.dumps(value))
                with self.assertRaisesRegex(ValueError, 'missing_assets'):
                    cache.load(pipeline, voice, manifest, {'revision': 'test'}, 'af_heart')

    def test_inference_stays_on_owner_and_preserves_order_pack_speed_and_samples(self):
        import numpy as np
        pipeline = Pipeline()
        samples, duration = provider.infer_segments(None, pipeline, 3, ['first', 'second'], 1.1, np)
        np.testing.assert_array_equal(samples, np.array([5, 1.1, 6, 1.1], dtype=np.float32))
        self.assertEqual(pipeline.inferred, [('first', 3, 1.1, threading.get_ident()), ('second', 3, 1.1, threading.get_ident())])
        self.assertGreaterEqual(duration, 0)
        self.assertEqual(samples.dtype, np.float32)

    def test_empty_and_nonfinite_audio_fail(self):
        import numpy as np
        pipeline = Pipeline()
        with self.assertRaisesRegex(ValueError, 'empty_audio'):
            provider.infer_segments(None, pipeline, 1, [], 1, np)
        pipeline.infer = lambda *args: SimpleNamespace(audio=np.array([[np.nan]], dtype=np.float32))
        with self.assertRaisesRegex(ValueError, 'invalid_audio'):
            provider.infer_segments(None, pipeline, 1, ['a'], 1, np)

    def test_next_pronunciation_can_overlap_current_owner_inference(self):
        import numpy as np
        pipeline = Pipeline()
        entered, release = threading.Event(), threading.Event()
        original = pipeline.g2p
        def blocked(text):
            entered.set()
            if not release.wait(2):
                raise RuntimeError('fixture timeout')
            return original(text)
        pipeline.g2p = blocked
        ahead = provider.PronunciationAhead()
        try:
            ahead.schedule(pipeline, 'next', 'a')
            self.assertTrue(entered.wait(2))
            samples, _ = provider.infer_segments(None, pipeline, 1, ['current'], 1, np)
            np.testing.assert_array_equal(samples, np.array([7, 1], dtype=np.float32))
            self.assertFalse(release.is_set())
            release.set()
            self.assertEqual(ahead.take(pipeline, 'next', 'a')[0], ['next'])
        finally:
            release.set()
            ahead.close()


if __name__ == '__main__':
    unittest.main()
