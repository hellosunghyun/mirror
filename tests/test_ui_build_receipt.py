"""GHA에서 실제 Git·합성 Products로 UI receipt를 검증한다. SDK 검증은 아니다."""

import ast
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'scripts/ci-apple-platform.sh').read_text()
MATCHES = re.findall(
    r"^ui_build_receipt\(\) \{\n[ \t]+python3 - \"\$1\"[^\n]* <<'PY'\n(.*?)^PY\n\}",
    SOURCE, re.MULTILINE | re.DOTALL)
if len(MATCHES) != 1:
    raise RuntimeError('UI receipt here-doc 경계를 하나로 확인하지 못했습니다.')
BODY = MATCHES[0]
FIXED_ERRORS = {
    '::error::' + node.args[0].value
    for node in ast.walk(ast.parse(BODY))
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
    and node.func.id == 'fail' and node.args
    and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str)
}


class UIBuildReceiptTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.checkout = self.base / 'checkout'
        self.checkout.mkdir()
        self.environment = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)
        self._git('init', '-q')
        self._git('config', 'user.name', 'Synthetic receipt regression')
        self._git('config', 'user.email', 'receipt@example.invalid')
        (self.checkout / '.gitignore').write_text('.build/\n')
        (self.checkout / 'Sources').mkdir()
        self.source = self.checkout / 'Sources/Tracked.swift'
        self.source.write_text('// Synthetic tracked source\n')
        self._git('add', '.gitignore', 'Sources/Tracked.swift')
        self._git('commit', '-qm', 'Synthetic receipt fixture')
        self.sha = self._git('rev-parse', 'HEAD').strip()
        self.directory = self.checkout / '.build/ci-receipt'
        self.products = self.directory / 'DerivedData/Build/Products'
        self.receipt = self.directory / 'ui-build-receipt.json'
        self.unit_context = self.directory / 'unit-context.json'
        self._configure('macos')

    def _git(self, *arguments):
        result = subprocess.run(['git', *arguments], cwd=self.checkout, env=self.environment,
                                capture_output=True, text=True, timeout=20)
        if result.returncode:
            raise RuntimeError('합성 Git fixture 명령이 실패했습니다.')
        return result.stdout

    def _bundle(self, path, executable, *, mac):
        info = path / ('Contents/Info.plist' if mac else 'Info.plist')
        binary = path / ('Contents/MacOS' if mac else '') / executable
        info.parent.mkdir(parents=True, exist_ok=True)
        binary.parent.mkdir(parents=True, exist_ok=True)
        info.write_bytes(plistlib.dumps({'CFBundleVersion': '30', 'CFBundleExecutable': executable}))
        binary.write_bytes(b'SYNTHETIC_EXECUTABLE_NOT_AN_SDK_BUILD')
        return info, binary

    def _configure(self, platform):
        if self.products.exists():
            shutil.rmtree(self.products)
        self.receipt.unlink(missing_ok=True)
        mac = platform == 'macos'
        scheme, sdk = ('MirrorMac', 'macosx') if mac else ('MirrorIOS', 'iphonesimulator')
        self.ui_scheme = scheme + 'UI'
        destination = 'platform=macOS,arch=arm64' if mac else 'platform=iOS Simulator,id=' + '1' * 36
        self.context = {'platform': platform, 'scheme': scheme, 'sdk': sdk, 'destination': destination,
                        'run_id': '31415', 'run_attempt': '1', 'commit': self.sha, 'build_number': '30'}
        configuration = self.products / ('Debug' if mac else 'Debug-iphonesimulator')
        self.app_info, self.app_binary = self._bundle(configuration / 'Mirror.app', 'Mirror', mac=mac)
        ui_name = scheme + 'UITests'
        self.ui_info, self.ui_binary = self._bundle(configuration / (ui_name + '.xctest'), ui_name, mac=mac)
        plugins = 'Contents/PlugIns' if mac else 'PlugIns'
        self.clone_info, self.clone_binary = self._bundle(
            configuration / (ui_name + '-Runner.app') / plugins / (ui_name + '.xctest'), ui_name, mac=mac)
        self.xctestrun = self.products / 'Synthetic.xctestrun'
        self.xctestrun.write_bytes(b'SYNTHETIC_XCTESTRUN_BYTES_NOT_AN_SDK_SCHEMA')
        self._write_context()

    def _write_context(self):
        self.unit_context.write_text(json.dumps(self.context) + '\n')

    def _invoke(self, action):
        environment = dict(self.environment, GITHUB_RUN_ID=self.context['run_id'],
                           GITHUB_RUN_ATTEMPT=self.context['run_attempt'], GITHUB_SHA=self.context['commit'])
        arguments = [action, str(self.directory), *(self.context[key] for key in
                     ('platform', 'scheme', 'sdk', 'destination', 'build_number')), self.ui_scheme]
        return subprocess.run([sys.executable, '-c', BODY, *arguments], cwd=self.checkout,
                              env=environment, capture_output=True, text=True, timeout=20)

    def _accept(self, action):
        result = self._invoke(action)
        self.assertEqual(result.returncode, 0, 'receipt 작업이 거부됐습니다.')
        self.assertTrue(result.stdout == '' and result.stderr == '', '예상하지 않은 receipt 출력입니다.')

    def _reject(self, action):
        result = self._invoke(action)
        self.assertEqual(result.returncode, 1, '유효하지 않은 receipt가 거부되지 않았습니다.')
        self.assertTrue(result.stdout == '', 'receipt가 예상하지 않은 stdout을 출력했습니다.')
        self.assertTrue(result.stderr.strip() in FIXED_ERRORS, '고정 receipt 오류 형식이 아닙니다.')

    def test_record_and_verify_hash_every_ui_bundle_copy(self):
        for platform in ('macos', 'iphone', 'ipad'):
            with self.subTest(platform=platform):
                self._configure(platform)
                self._accept('record')
                self._accept('verify')
                receipt = json.loads(self.receipt.read_bytes())
                self.assertTrue(receipt['context'] == self.context, 'receipt 실행 context가 다릅니다.')
                self.assertEqual(len(receipt['ui_bundles']), 2)
                self.assertTrue(receipt['xctestruns'][0]['sha256'] == hashlib.sha256(self.xctestrun.read_bytes()).hexdigest())
                self.assertTrue(receipt['unit_context_sha256'] == hashlib.sha256(self.unit_context.read_bytes()).hexdigest())
                expected = {self.ui_binary.relative_to(self.products).as_posix(),
                            self.clone_binary.relative_to(self.products).as_posix()}
                self.assertTrue({bundle['executable']['path'] for bundle in receipt['ui_bundles']} == expected)
                self.assertTrue(all(bundle['executable']['sha256'] == hashlib.sha256(self.ui_binary.read_bytes()).hexdigest()
                                    for bundle in receipt['ui_bundles']))

    def test_other_run_attempt_sha_build_or_destination_is_rejected(self):
        self._accept('record')
        original = copy.deepcopy(self.context)
        changes = {'run_id': '31416', 'run_attempt': '2', 'commit': 'f' * 40,
                   'build_number': '31', 'destination': 'platform=macOS,arch=x86_64'}
        for key, value in changes.items():
            with self.subTest(contextField=key):
                try:
                    self.context[key] = value
                    self._write_context()
                    self._reject('verify')
                finally:
                    self.context = copy.deepcopy(original)
                    self._write_context()
        self._accept('verify')

    def test_light_and_dark_ui_scheme_receipts_cannot_be_interchanged(self):
        for platform in ('macos', 'iphone', 'ipad'):
            for recorded_suffix, other_suffix in (('UI', 'UIDark'), ('UIDark', 'UI')):
                with self.subTest(platform=platform, recorded=recorded_suffix):
                    self._configure(platform)
                    base = self.context['scheme']
                    self.ui_scheme = base + recorded_suffix
                    self._accept('record')
                    self._accept('verify')
                    receipt = json.loads(self.receipt.read_bytes())
                    self.assertEqual(receipt['ui_scheme'], self.ui_scheme)
                    self.assertEqual(receipt['context'], self.context)
                    self.ui_scheme = base + other_suffix
                    self._reject('verify')
                    self.ui_scheme = base + recorded_suffix
                    self._accept('verify')

    def test_unapproved_ui_scheme_is_rejected_before_receipt_creation(self):
        for value in ('MirrorMac', 'MirrorIOSUI', 'UnknownUIDark', '../MirrorMacUI'):
            with self.subTest(scheme=value):
                self._configure('macos')
                self.ui_scheme = value
                self._reject('record')
                self.assertFalse(self.receipt.exists())

    def test_changed_xctestrun_app_or_ui_binary_is_rejected(self):
        self._accept('record')
        for label, path in [('xctestrun', self.xctestrun), ('app', self.app_binary),
                            ('ui', self.ui_binary), ('runnerCopy', self.clone_binary)]:
            with self.subTest(product=label):
                original = path.read_bytes()
                try:
                    path.write_bytes(original + b'CHANGED')
                    self._reject('verify')
                finally:
                    path.write_bytes(original)
        self._accept('verify')

    def test_missing_invalid_bundle_metadata_and_executable_escape_are_rejected(self):
        for label, info, binary in [('app', self.app_info, self.app_binary), ('ui', self.ui_info, self.ui_binary)]:
            original = info.read_bytes()
            value = plistlib.loads(original)
            invalid = [('missingVersion', {key: item for key, item in value.items() if key != 'CFBundleVersion'}),
                       ('invalidVersion', dict(value, CFBundleVersion='invalid')),
                       ('executableTraversal', dict(value, CFBundleExecutable='../outside'))]
            for case, changed in invalid:
                with self.subTest(bundle=label, condition=case):
                    try:
                        info.write_bytes(plistlib.dumps(changed))
                        self._reject('record')
                    finally:
                        info.write_bytes(original)
                        self.receipt.unlink(missing_ok=True)
            with self.subTest(bundle=label, condition='emptyBundle'):
                data = binary.read_bytes()
                try:
                    info.unlink()
                    binary.unlink()
                    self._reject('record')
                finally:
                    info.write_bytes(original)
                    binary.write_bytes(data)
                    self.receipt.unlink(missing_ok=True)
            with self.subTest(bundle=label, condition='executableSymlinkEscape'):
                data = binary.read_bytes()
                outside = self.base / 'outside-executable'
                outside.write_bytes(data)
                try:
                    binary.unlink()
                    binary.symlink_to(outside)
                    self._reject('record')
                finally:
                    binary.unlink()
                    binary.write_bytes(data)
                    self.receipt.unlink(missing_ok=True)

    def test_stale_missing_tampered_or_symlink_receipt_is_rejected(self):
        self._accept('record')
        original = self.receipt.read_bytes()
        self._reject('record')
        self.assertTrue(self.receipt.read_bytes() == original, '기존 receipt를 덮어썼습니다.')
        for label, data in [('invalidJson', b'not json'), ('staleReceipt', b'{"format_version":0}')]:
            with self.subTest(receipt=label):
                self.receipt.write_bytes(data)
                self._reject('verify')
        self.receipt.unlink()
        self._reject('verify')
        outside = self.base / 'outside-receipt.json'
        self.receipt.symlink_to(outside)
        self._reject('record')
        self._reject('verify')
        self.assertFalse(outside.exists(), 'receipt가 외부 파일을 생성했습니다.')

    def test_missing_artifacts_and_changed_or_untracked_source_are_rejected(self):
        self._accept('record')
        for label, path in [('unitContext', self.unit_context), ('xctestrun', self.xctestrun),
                            ('appInfo', self.app_info), ('uiExecutable', self.ui_binary)]:
            with self.subTest(missing=label):
                data = path.read_bytes()
                try:
                    path.unlink()
                    self._reject('verify')
                finally:
                    path.write_bytes(data)
        original = self.source.read_bytes()
        try:
            self.source.write_bytes(original + b'// changed\n')
            self._reject('verify')
            self._git('add', 'Sources/Tracked.swift')
            self._reject('verify')
        finally:
            self._git('reset', '-q', 'HEAD', '--', 'Sources/Tracked.swift')
            self.source.write_bytes(original)
        untracked = self.checkout / 'Sources/Untracked.swift'
        try:
            untracked.write_text('// Synthetic untracked source\n')
            self._reject('verify')
        finally:
            untracked.unlink()
        self._accept('verify')
