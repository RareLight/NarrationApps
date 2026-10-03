"""Small, offline setup checks: no model, package, Metal, or network execution."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('runtime_setup', SOURCE/'runtime_setup.py')
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


def source_only_fixture(directory, name):
    """Synthetic sdist with a stdlib-only backend; never fetch third-party code."""
    metadata = f'Metadata-Version: 2.2\nName: {name}\nVersion: 0.6.2\n'
    backend = f'''from pathlib import Path
import zipfile

def build_wheel(wheel_directory, config_settings=None, metadata_directory=None):
    name = {name!r}
    info = name + '-0.6.2.dist-info/'
    filename = name + '-0.6.2-py3-none-any.whl'
    files = {{name + '.py': 'SYNTHETIC_BUILD = True\\n',
             info + 'METADATA': {metadata!r},
             info + 'WHEEL': 'Wheel-Version: 1.0\\nRoot-Is-Purelib: true\\nTag: py3-none-any\\n'}}
    files[info + 'RECORD'] = ''.join(path + ',,\\n' for path in [*files, info + 'RECORD'])
    with zipfile.ZipFile(Path(wheel_directory)/filename, 'w') as wheel:
        for path, value in files.items(): wheel.writestr(path, value)
    return filename
'''
    archive = directory/f'{name}-0.6.2.tar.gz'
    files = {'PKG-INFO': metadata, 'fixture_backend.py': backend,
             'pyproject.toml': '[build-system]\nrequires = []\nbuild-backend = "fixture_backend"\nbackend-path = ["."]\n'}
    with tarfile.open(archive, 'w:gz') as tar:
        for filename, value in files.items():
            data = value.encode(); entry = tarfile.TarInfo(f'{name}-0.6.2/{filename}')
            entry.size = len(data); tar.addfile(entry, io.BytesIO(data))
    return archive


class RuntimeSetupTests(unittest.TestCase):
    def test_every_download_and_cache_path_is_project_local(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            env = setup.environment(root, inherited={'HOME': '/unchanged', 'HF_HOME': '/external',
                'UV_CACHE_DIR': '/external', 'PYTHONPATH': '/external', 'UV_INDEX': 'private', 'PIP_INDEX_URL': 'private',
                'UV_PYTHON_PREFERENCE': 'system', 'UV_NO_MANAGED_PYTHON': '1'})
            self.assertEqual(env['HOME'], '/unchanged')
            self.assertNotIn('PYTHONPATH', env)
            self.assertNotIn('UV_INDEX', env)
            self.assertNotIn('PIP_INDEX_URL', env)
            self.assertNotIn('UV_PYTHON_PREFERENCE', env)
            self.assertNotIn('UV_NO_MANAGED_PYTHON', env)
            for name in ['UV_CACHE_DIR', 'UV_PYTHON_INSTALL_DIR', 'UV_PYTHON_BIN_DIR', 'PIP_CACHE_DIR',
                         'HF_HOME', 'HF_HUB_CACHE', 'HF_XET_CACHE', 'HF_ASSETS_CACHE', 'TRANSFORMERS_CACHE',
                         'XDG_CACHE_HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'NLTK_DATA', 'TMPDIR']:
                self.assertTrue(Path(env[name]).is_relative_to(root), name)
            self.assertEqual(env['HF_HUB_OFFLINE'], '1')
            self.assertEqual(env['UV_PYTHON_DOWNLOADS'], 'never')
            online = setup.environment(root, download=True, inherited={})
            self.assertEqual(online['HF_HUB_OFFLINE'], '0')
            self.assertEqual(online['UV_PYTHON_DOWNLOADS'], 'automatic')
            self.assertEqual(list(root.iterdir()), [])

    def test_confinement_rejects_external_symlinks_and_traversal(self):
        with tempfile.TemporaryDirectory() as folder, tempfile.TemporaryDirectory() as outside:
            root = Path(folder).resolve()
            (root/'models').symlink_to(outside, target_is_directory=True)
            with self.assertRaises(ValueError): setup.layout(root, 'revision')
            with self.assertRaises(ValueError): setup.confined(root, '../escape')

    def test_download_preflight_rejects_nested_external_links(self):
        with tempfile.TemporaryDirectory() as folder, tempfile.TemporaryDirectory() as outside:
            root = Path(folder).resolve()
            models = root/'models'; models.mkdir()
            (models/'voices').symlink_to(outside, target_is_directory=True)
            with self.assertRaises(ValueError): setup.reject_external_links(root, models)
            (models/'voices').unlink()
            (models/'local').mkdir()
            (models/'voices').symlink_to(models/'local', target_is_directory=True)
            setup.reject_external_links(root, models)

    def test_setup_and_check_do_not_implicitly_download(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(setup, 'PROJECT', Path(folder).resolve()):
            with patch.object(setup, 'run') as run:
                with self.assertRaisesRegex(ValueError, 'requires --download'): setup.main(['setup'])
                with self.assertRaisesRegex(ValueError, 'runtime missing'): setup.main(['check'])
                self.assertEqual(run.call_count, 0)
                with contextlib.redirect_stdout(io.StringIO()): setup.main(['paths'])
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_checkpoint_hash_and_stored_dtype_are_both_verified(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            snapshot = setup.layout(root, 'test')['snapshot']; snapshot.mkdir(parents=True)
            header = json.dumps({'weight': {'dtype': 'F32', 'shape': [1], 'data_offsets': [0, 4]}}).encode()
            file = snapshot/'kokoro-v1_0.safetensors'
            file.write_bytes(struct.pack('<Q', len(header))+header+struct.pack('<f', 1))
            selection = {'revision': 'test', 'sha256': {file.name: setup.digest(file)},
                         'stored_tensor_count': 1, 'stored_tensor_dtype': 'F32'}
            self.assertEqual(setup.validate_assets(root, selection), snapshot)
            selection['stored_tensor_dtype'] = 'BF16'
            with self.assertRaisesRegex(ValueError, 'tensors differ'): setup.validate_assets(root, selection)
            selection['stored_tensor_dtype'] = 'F32'; file.write_bytes(b'corrupt')
            with self.assertRaisesRegex(ValueError, 'incompatible'): setup.validate_assets(root, selection)

    def test_selected_pins_are_present_in_the_standalone_lock(self):
        selected = setup.selection(); lock = (SOURCE/'requirements.lock').read_text()
        self.assertEqual(selected['revision'], 'a71e4d38b236d968966a2002c4c895dbd12b1c3c')
        for name, version in selected['packages'].items():
            if name == 'en-core-web-sm': self.assertIn('en_core_web_sm-'+version+'-', lock)
            else: self.assertIn(name+'=='+version, lock)
        self.assertNotIn('/tts-bench', lock)
        self.assertNotIn('-e ', lock)
        self.assertIn('--hash=sha256:', lock)

    def test_existing_uv_finds_pinned_python_in_local_catalog_offline(self):
        uv = setup.shutil.which('uv')
        if not uv or sys.platform != 'darwin' or os.uname().machine != 'arm64':
            self.skipTest('Requires uv on an Apple Silicon Mac; performs no download')
        selected = setup.selection()
        metadata = setup.python_downloads_metadata(selected)
        with tempfile.TemporaryDirectory() as folder:
            process = subprocess.run([uv, '--no-config', '--offline', 'python', 'list', selected['python'],
                '--only-downloads', '--show-urls', '--output-format', 'json',
                '--python-downloads-json-url', str(metadata)],
                env=setup.environment(Path(folder).resolve()), text=True, capture_output=True, timeout=10, check=True)
        downloads = json.loads(process.stdout)
        self.assertEqual(len(downloads), 1)
        self.assertEqual(downloads[0]['version'], selected['python'])
        url = next(iter(json.loads(metadata.read_text()).values()))['url']
        # uv may route the same release archive through Astral's official mirror.
        self.assertIn(downloads[0]['url'], [url, url.replace('https://github.com/astral-sh/',
                                                           'https://releases.astral.sh/github/')])

    def test_download_metadata_rejects_pin_platform_checksum_and_url_changes(self):
        selected = setup.selection()
        catalog = json.loads((SOURCE/'python-downloads.json').read_text())
        key = next(iter(catalog))
        with tempfile.TemporaryDirectory() as folder, patch.object(setup, 'PROJECT', Path(folder).resolve()):
            metadata = Path(folder)/'runtime/kokoro/python-downloads.json'
            metadata.parent.mkdir(parents=True)
            for field, value in [('patch', 14), ('os', 'linux'), ('sha256', None), ('sha256', 'bad'),
                                 ('url', 'https://example.invalid/python.tar.gz')]:
                with self.subTest(field=field, value=value):
                    changed = json.loads(json.dumps(catalog)); changed[key][field] = value
                    metadata.write_text(json.dumps(changed))
                    with self.assertRaises(ValueError): setup.python_downloads_metadata(selected)
            metadata.write_text(json.dumps(catalog))
            with self.assertRaisesRegex(ValueError, 'does not match'):
                setup.python_downloads_metadata({**selected, 'python': '3.12.14'})

    def test_explicit_setup_uses_local_catalog_and_only_owned_runtime(self):
        selected = setup.selection()
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve(); source = root/'runtime/kokoro'; source.mkdir(parents=True)
            (source/'selection.json').write_text(json.dumps(selected))
            (source/'python-downloads.json').write_text((SOURCE/'python-downloads.json').read_text())
            with patch.object(setup, 'PROJECT', root), patch.object(setup, 'SOURCE', source), \
                 patch.object(setup.sys, 'platform', 'darwin'), \
                 patch.object(setup.os, 'uname', return_value=os.uname_result(('Darwin', '', '', '', 'arm64'))), \
                 patch.object(setup.shutil, 'which', return_value='/test-tools/uv'), patch.object(setup, 'run') as run:
                self.assertEqual(setup.main(['setup', '--download']), 0)
            self.assertEqual(run.call_count, 4)
            install, venv, packages, assets = run.call_args_list
            self.assertEqual(install.args[0], ['/test-tools/uv', '--no-config', 'python', 'install', selected['python'],
                '--no-bin', '--python-downloads-json-url', str(source/'python-downloads.json')])
            own_python = root/'.runtime/kokoro/.venv/bin/python'
            self.assertIn('--managed-python', venv.args[0]); self.assertIn('--no-python-downloads', venv.args[0])
            self.assertEqual(venv.args[0][-1], str(own_python.parent.parent))
            self.assertEqual(packages.args[0][packages.args[0].index('--python')+1], str(own_python))
            self.assertIn('--require-hashes', packages.args[0])
            self.assertEqual(packages.args[0][packages.args[0].index('--only-binary')+1], ':all:')
            self.assertEqual(packages.args[0][packages.args[0].index('--no-binary')+1], 'docopt')
            self.assertEqual(packages.args[0][packages.args[0].index('--build-constraints')+1], str(source/'requirements.lock'))
            self.assertEqual(assets.args[0][0], str(own_python))
            for call in run.call_args_list:
                env = call.kwargs['env']
                self.assertEqual(env['UV_PYTHON_INSTALL_DIR'], str(root/'.runtime/python'))
                self.assertEqual(env['UV_CACHE_DIR'], str(root/'.runtime/cache/uv'))
                self.assertEqual(env['VOICERELAY_EXPLICIT_DOWNLOAD'], '1')
                self.assertNotIn('UV_PYTHON_PREFERENCE', env)

    def test_existing_managed_python_creates_confined_venv_with_setup_environment(self):
        uv = setup.shutil.which('uv')
        if not uv or sys.platform != 'darwin' or os.uname().machine != 'arm64':
            self.skipTest('Requires uv on an Apple Silicon Mac; performs no download')
        selected = setup.selection()
        installed = setup.confined(setup.PROJECT,
            f".runtime/python/cpython-{selected['python']}-macos-aarch64-none/bin/python3.12")
        if not installed.is_file():
            self.skipTest('Requires the already downloaded project-owned Python; performs no download')
        temporary = setup.confined(setup.PROJECT, '.runtime/tmp')
        temporary.mkdir(parents=True, exist_ok=True)
        env = setup.environment(setup.PROJECT, download=True)
        with tempfile.TemporaryDirectory(prefix='uv-venv-test-', dir=temporary) as folder:
            venv = Path(folder)/'venv'
            subprocess.run([uv, '--no-config', '--offline', 'venv', '--managed-python',
                '--no-python-downloads', '--python', selected['python'], str(venv)],
                env=env, text=True, capture_output=True, timeout=15, check=True)
            python = venv/'bin/python'
            self.assertEqual(python.resolve(), installed.resolve())
            self.assertTrue(python.resolve().is_relative_to(setup.PROJECT))
            result = subprocess.run([str(python), '-I', '-B', '-c', 'import sys; print(sys.version.split()[0]); print(sys.prefix)'],
                env=env, text=True, capture_output=True, timeout=10, check=True)
            self.assertEqual(result.stdout.splitlines(), [selected['python'], str(venv)])

    def test_missing_download_metadata_fails_before_runtime_creation(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(setup, 'PROJECT', Path(folder).resolve()), \
             patch.object(setup.shutil, 'which', return_value='/test-tools/uv'), \
             patch.object(setup.sys, 'platform', 'darwin'), \
             patch.object(setup.os, 'uname', return_value=os.uname_result(('Darwin', '', '', '', 'arm64'))), \
             patch.object(setup, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'metadata missing'): setup.main(['setup', '--download'])
            run.assert_not_called()
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_docopt_source_exception_preserves_hashes_and_other_wheel_requirements(self):
        uv = setup.shutil.which('uv')
        if not uv or sys.platform != 'darwin' or os.uname().machine != 'arm64':
            self.skipTest('Requires uv on an Apple Silicon Mac; performs no download')
        selected = setup.selection()
        installed = setup.confined(setup.PROJECT,
            f".runtime/python/cpython-{selected['python']}-macos-aarch64-none/bin/python3.12")
        if not installed.is_file():
            self.skipTest('Requires the already downloaded project-owned Python; performs no download')
        temporary = setup.confined(setup.PROJECT, '.runtime/tmp'); temporary.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='uv-source-policy-test-', dir=temporary) as folder:
            root = Path(folder); archives = root/'archives'; archives.mkdir()
            hashes = {name: setup.digest(source_only_fixture(archives, name)) for name in ['docopt', 'sourcefixture']}
            cases = [('previous-policy', 'docopt', False, hashes['docopt']),
                     ('docopt-exception', 'docopt', True, hashes['docopt']),
                     ('other-source-refused', 'sourcefixture', True, hashes['sourcefixture']),
                     ('wrong-hash-refused', 'docopt', True, '0'*64)]
            for label, name, exception, checksum in cases:
                with self.subTest(case=label):
                    env = setup.environment(setup.PROJECT, download=True)
                    # Prevent reuse of any previously built fixture across cases.
                    env['UV_CACHE_DIR'] = str(root/label/'cache')
                    venv = root/label/'venv'
                    subprocess.run([uv, '--no-config', '--offline', 'venv', '--managed-python',
                        '--no-python-downloads', '--python', selected['python'], str(venv)],
                        env=env, text=True, capture_output=True, timeout=15, check=True)
                    requirement = root/label/'requirements.txt'
                    requirement.write_text(f'{name}==0.6.2 --hash=sha256:{checksum}\n')
                    command = [uv, '--no-config', '--offline', 'pip', 'sync', '--python', str(venv/'bin/python'),
                        '--require-hashes', '--only-binary', ':all:', '--no-index', '--find-links', str(archives),
                        '--build-constraints', str(SOURCE/'requirements.lock')]
                    if exception: command += ['--no-binary', 'docopt']
                    result = subprocess.run(command+[str(requirement)], env=env, text=True,
                                            capture_output=True, timeout=30)
                    if label == 'docopt-exception':
                        self.assertEqual(result.returncode, 0, result.stderr)
                        result = subprocess.run([str(venv/'bin/python'), '-I', '-B', '-c',
                            'import docopt; import importlib.metadata; assert docopt.SYNTHETIC_BUILD; print(importlib.metadata.version("docopt"))'],
                            env=env, text=True, capture_output=True, timeout=10, check=True)
                        self.assertEqual(result.stdout.strip(), '0.6.2')
                    else:
                        self.assertNotEqual(result.returncode, 0, result.stdout+result.stderr)
                        self.assertIn('hash' if label == 'wrong-hash-refused' else 'no usable wheels', result.stderr.lower())

    def test_setup_errors_identify_stage_without_echoing_command(self):
        command = ['uv', 'private-command-value']
        failures = [subprocess.CalledProcessError(2, command), subprocess.TimeoutExpired(command, 600)]
        for failure in failures:
            with self.subTest(failure=type(failure).__name__), patch.object(setup.subprocess, 'run', side_effect=failure):
                with self.assertRaises(ValueError) as caught:
                    setup.run(command, env={}, timeout=600, stage='Project-local Python installation')
                message = str(caught.exception)
                self.assertIn('Project-local Python installation', message)
                self.assertNotIn('private-command-value', message)
                self.assertIn('exit 2' if isinstance(failure, subprocess.CalledProcessError) else '600 seconds', message)

    def test_helper_control_errors_never_echo_request_text(self):
        private = 'private text must not become a log'
        request = json.dumps({'protocol': 1, 'id': 7, 'command': 'unknown', 'text': private})+'\n'
        process = subprocess.run([sys.executable, '-I', '-B', str(SOURCE/'provider.py')], input=request,
                                 text=True, capture_output=True, timeout=5,
                                 env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
        self.assertEqual(process.returncode, 0)
        messages = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertEqual(messages[0]['kind'], 'hello')
        self.assertEqual(messages[1], {'protocol': 1, 'id': 7, 'kind': 'error', 'code': 'invalid_request'})
        self.assertNotIn(private, process.stdout+process.stderr)


if __name__ == '__main__':
    unittest.main()
