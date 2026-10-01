"""공개 UI evidence의 합성 export/parser/집계/게시 회귀. GitHub Actions에서 실행한다."""

import base64
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock
from urllib.parse import parse_qs, urlsplit
import zlib


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('mirror_ui_evidence', ROOT / 'scripts/ci-ui-evidence.py')
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
PRIVATE = 'SYNTHETIC_PRIVATE_LOG_OR_GEOMETRY'
IDENTITY = helper.identity('a' * 40, '27', '31415', '1')
METHOD = 'mirroriosuitests-mirroruitests-testexplicitcompletionandundopreserveeditedtitleandplan'
SCREENSHOT_COUNT = sum(len(helper.required_stages(platform)) for platform in helper.PLATFORMS)


def png(extra=(), pixels=b'\xff\x00\x00\x00\xff\x00'):
    # 두 RGB pixel을 가진 정상 PNG다. PNG signature만 맞춘 임의 bytes를 사용하지 않는다.
    return (helper.PNG_SIGNATURE + helper.png_chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 1, 8, 2, 0, 0, 0)) +
            b''.join(helper.png_chunk(kind, data) for kind, data in extra) +
            helper.png_chunk(b'IDAT', zlib.compress(b'\0' + pixels)) + helper.png_chunk(b'IEND', b''))


def chunks(data):
    result, position = [], 8
    while position < len(data):
        size = struct.unpack('>I', data[position:position + 4])[0]
        result.append((data[position + 4:position + 8], data[position + 8:position + 8 + size]))
        position += size + 12
    return result


def raw_export(directory, *, stages=helper.STAGES, shape='list', image=None):
    directory.mkdir(parents=True)
    attachments = []
    for index, stage in enumerate(stages, 1):
        name = f'mirror-ui-{stage}-{METHOD}-{index}'
        basename = f'export-{index}.png'
        (directory / basename).write_bytes(image or png(((b'tEXt', b'Comment\0' + PRIVATE.encode()),)))
        attachments.append({'exportedFileName': basename, 'suggestedHumanReadableName': name,
                            'uniformTypeIdentifier': 'public.png', 'timestamp': 99.5,
                            'isAssociatedWithFailure': False})
    # 앱 geometry와 Xcode의 전체 기기 화면·영상은 이름 allowlist에 포함되지 않는다.
    (directory / 'geometry.json').write_text(json.dumps({'private': PRIVATE}))
    (directory / 'device.png').write_bytes(png())
    (directory / 'recording.mp4').write_bytes(PRIVATE.encode())
    (directory / 'private.log').write_text(PRIVATE)
    attachments.extend([
        {'exportedFileName': 'geometry.json', 'suggestedHumanReadableName': 'mirror-ui-metadata-initial-today-' + METHOD + '-1'},
        {'exportedFileName': 'device.png', 'suggestedHumanReadableName': 'Screenshot of device'},
        {'exportedFileName': 'recording.mp4', 'suggestedHumanReadableName': 'Screen recording'},
    ])
    record = {'testName': PRIVATE, 'testIdentifier': PRIVATE, 'testIdentifierURL': 'file:///private/' + PRIVATE,
              'attachments': attachments}
    value = [record] if shape == 'list' else {'tests': [record]} if shape == 'tests' else record
    (directory / 'manifest.json').write_text(json.dumps(value))
    return value


def rewrite_export(directory, value):
    (directory / 'manifest.json').write_text(json.dumps(value))


class FakeGitHub:
    """별도 UI release만 API 경로로 변경하며 실제 앱 배포의 8자산은 보존한다."""

    def __init__(self):
        self.calls = []
        self.release = None
        self.tag_sha = None
        self.next_id = 100
        self.app_release = {'tag_name': 'adhoc-31415', 'assets': [
            {'name': name, 'digest': 'sha256:' + 'b' * 64, 'size': 12}
            for name in ('Mirror.ipa', 'build-manifest.json', 'SHA256SUMS', 'release-notes.md',
                         'Mirror-macOS.dmg', 'macos-build-manifest.json', 'macos-SHA256SUMS', 'macos-release-notes.md')]}

    def verify_tag(self, tag, sha):
        self.calls.append(('TAG', tag, sha))
        if self.tag_sha is not None and self.tag_sha != sha:
            raise helper.EvidenceError('identityMismatch')
        return self.tag_sha is not None

    def request(self, method, endpoint, *, value=None, content=None, content_type=None, missing_ok=False):
        self.calls.append((method, endpoint, copy.deepcopy(value)))
        if method == 'GET' and endpoint.startswith('/releases/tags/ui-review-'):
            return copy.deepcopy(self.release)
        if method == 'POST' and endpoint == '/releases':
            self.release = {**value, 'id': 55, 'assets': [],
                            'upload_url': 'https://uploads.github.com/repos/example/mirror/releases/55/assets{?name,label}',
                            'html_url': 'https://github.com/example/mirror/releases/tag/ui-review-31415'}
            return copy.deepcopy(self.release)
        if method == 'PATCH' and endpoint == '/releases/55':
            self.release.update(value)
            if value.get('draft') is False:
                self.tag_sha = value['target_commitish']
            return copy.deepcopy(self.release)
        if method == 'GET' and endpoint == '/releases/55':
            return copy.deepcopy(self.release)
        if method == 'DELETE' and endpoint.startswith('/releases/assets/'):
            asset_id = int(endpoint.rsplit('/', 1)[1])
            self.release['assets'] = [asset for asset in self.release['assets'] if asset['id'] != asset_id]
            return None
        if method == 'POST' and endpoint.startswith('https://uploads.github.com/'):
            name = parse_qs(urlsplit(endpoint).query)['name'][0]
            self.next_id += 1
            asset = {'id': self.next_id, 'name': name, 'size': len(content),
                     'digest': 'sha256:' + helper.digest(content)}
            self.release['assets'].append(asset)
            return copy.deepcopy(asset)
        raise AssertionError('예상하지 않은 합성 GitHub API 호출')


class UIEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def prepare_platform(self, platform='iphone', *, shape='list', stages=None, expected=IDENTITY):
        source = self.root / ('raw-' + platform)
        raw_export(source, shape=shape, stages=helper.required_stages(platform) if stages is None else stages)
        output = self.root / 'inputs' / platform
        helper.prepare(source, output, platform, expected)
        return source, output

    def aggregate_all(self, expected=IDENTITY):
        for platform in helper.PLATFORMS:
            self.prepare_platform(platform, expected=expected)
        output = self.root / 'public'
        helper.aggregate(self.root / 'inputs', output, expected)
        return output

    def expect_error(self, code, operation):
        with self.assertRaises(helper.EvidenceError) as result:
            operation()
        self.assertEqual(result.exception.code, code)

    def invoke(self, arguments):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = helper.main(arguments)
        self.assertEqual(stderr.getvalue(), '')
        self.assertNotIn(PRIVATE, stdout.getvalue())
        # SDK 형식 notice/error annotation 다음의 마지막 줄이 고정 command 결과다.
        return code, json.loads(stdout.getvalue().splitlines()[-1]), stdout.getvalue()

    def test_prepare_copies_only_named_app_png_and_strips_private_metadata(self):
        source, output = self.prepare_platform()
        manifest, files = helper.validate_directory(output, IDENTITY)
        self.assertEqual(len(manifest['screenshots']), len(helper.STAGES))
        self.assertEqual(set(files) - {shot['file'] for shot in manifest['screenshots']}, helper.PREPARE_STATIC)
        self.assertTrue(all(shot['name'].startswith('mirror-ui-') for shot in manifest['screenshots']))
        self.assertEqual(set(manifest), helper.MANIFEST_KEYS)
        self.assertTrue((source / 'private.log').is_file())
        for data in files.values():
            self.assertNotIn(PRIVATE.encode(), data)
        self.assertNotIn(b'geometry.json', files['index.html'])
        self.assertIn(b'data:image/png;base64,', files['index.html'])

    def test_supported_manifest_shapes_and_png_extension(self):
        for shape in ('list', 'tests', 'record'):
            with self.subTest(shape=shape):
                directory = self.root / shape
                value = raw_export(directory, shape=shape)
                records = value if shape == 'list' else value['tests'] if shape == 'tests' else [value]
                records[0]['attachments'][0]['suggestedHumanReadableName'] += '.png'
                rewrite_export(directory, value)
                manifest = helper.prepare(directory, self.root / ('prepared-' + shape), 'iphone', IDENTITY)
                self.assertEqual(len(manifest['screenshots']), len(helper.STAGES))

    def test_longest_stage_matches_before_hyphenated_method(self):
        names = (
            ('library-search', 'mirror-ui-library-search-' + METHOD + '-1'),
            ('detail-edit', 'mirror-ui-detail-edit-mirroriosuitests-testexplicitcompletionandundopreserveeditedtitleandplan-1'),
            ('library', 'mirror-ui-library-' + METHOD + '-1'),
            ('detail', 'mirror-ui-detail-' + METHOD + '-1'),
        )
        for stage, name in names:
            self.assertEqual(helper.SHOT_PATTERN.fullmatch(name)[1], stage)

    def test_unknown_shape_never_succeeds_or_prints_unknown_keys_and_values(self):
        source = self.root / 'unknown'
        source.mkdir()
        (source / 'manifest.json').write_text(json.dumps({PRIVATE: {'attachments': PRIVATE}}))
        arguments = ['prepare', '--input', str(source), '--output', str(self.root / 'out'), '--platform', 'iphone',
                     '--sha', 'a' * 40, '--build-number', '27', '--run-id', '31415', '--attempt', '1']
        code, summary, output = self.invoke(arguments)
        self.assertEqual(code, 1)
        self.assertEqual(summary['status'], 'unsupportedExport')
        self.assertEqual(set(summary['metadata']), {'typeCounts', 'knownKeyCounts', 'unknownKeyCount', 'truncated'})
        self.assertEqual(summary['metadata']['unknownKeyCount'], 1)
        self.assertIn('::notice::UI attachment export 구조:', output)
        self.assertIn('::error::UI attachment export 구조 미확인:', output)
        self.assertFalse((self.root / 'out').exists())

    def test_empty_manifest_and_missing_export_fail(self):
        source = self.root / 'empty'
        source.mkdir()
        self.expect_error('missingExportManifest', lambda: helper.prepare(source, self.root / 'out', 'iphone', IDENTITY))
        (source / 'manifest.json').write_text('[]')
        self.expect_error('emptyExport', lambda: helper.prepare(source, self.root / 'out', 'iphone', IDENTITY))

    def test_missing_stage_fails_without_partial_output(self):
        raw_export(self.root / 'raw', stages=helper.STAGES[:-1])
        self.expect_error('missingCoverage', lambda: helper.prepare(self.root / 'raw', self.root / 'out', 'ipad', IDENTITY))
        self.assertFalse((self.root / 'out').exists())

    def test_duplicate_stage_is_not_a_substitute_for_exact_baseline_coverage(self):
        raw_export(self.root / 'raw', stages=helper.STAGES + ('initial-today',))
        self.expect_error('duplicateStage', lambda: helper.prepare(self.root / 'raw', self.root / 'out', 'iphone', IDENTITY))

    def test_duplicate_names_or_shared_export_are_rejected(self):
        for duplicate in ('name', 'file'):
            with self.subTest(duplicate=duplicate):
                directory = self.root / duplicate
                value = raw_export(directory)
                first, second = value[0]['attachments'][:2]
                key = 'suggestedHumanReadableName' if duplicate == 'name' else 'exportedFileName'
                second[key] = first[key]
                rewrite_export(directory, value)
                self.expect_error('duplicateScreenshot', lambda: helper.prepare(directory, self.root / ('out-' + duplicate), 'iphone', IDENTITY))

    def test_attachment_path_and_name_pollution_are_rejected(self):
        cases = [('exportedFileName', '../export-1.png', 'invalidAttachmentPath'),
                 ('exportedFileName', '/private/file.png', 'invalidAttachmentPath'),
                 ('exportedFileName', 'video.mp4', 'invalidAttachmentPath'),
                 ('suggestedHumanReadableName', 'mirror-ui-initial-today-<script>-1', 'invalidAttachmentName'),
                 ('suggestedHumanReadableName', 'mirror-ui-unknown-' + METHOD + '-1', 'invalidAttachmentName'),
                 ('uniformTypeIdentifier', 'public.movie', 'invalidAttachmentType')]
        for index, (key, bad_value, error) in enumerate(cases):
            with self.subTest(key=key, value=bad_value):
                directory = self.root / str(index)
                value = raw_export(directory)
                value[0]['attachments'][0][key] = bad_value
                rewrite_export(directory, value)
                self.expect_error(error, lambda: helper.prepare(directory, self.root / ('out-' + str(index)), 'iphone', IDENTITY))

    def test_duplicate_json_keys_are_not_accepted(self):
        with self.assertRaises(helper.EvidenceError):
            helper.strict_json(b'{"attachments":[],"attachments":[]}')

    def test_symlink_export_and_output_are_rejected(self):
        source = self.root / 'raw'
        raw_export(source)
        (source / 'export-1.png').unlink()
        (source / 'export-1.png').symlink_to(source / 'export-2.png')
        with self.assertRaises(helper.EvidenceError):
            helper.prepare(source, self.root / 'out', 'iphone', IDENTITY)
        (source / 'export-1.png').unlink()
        (source / 'export-1.png').write_bytes(png())
        (self.root / 'linked').symlink_to(source, target_is_directory=True)
        with self.assertRaises(helper.EvidenceError):
            helper.prepare(source, self.root / 'linked', 'iphone', IDENTITY)

    def test_png_pixels_and_standard_color_chunks_are_preserved(self):
        color = ((b'gAMA', struct.pack('>I', 45455)),
                 (b'cHRM', struct.pack('>8I', 31270, 32900, 64000, 33000, 30000, 60000, 15000, 6000)),
                 (b'sRGB', b'\0'))
        original = png(color + ((b'tEXt', b'Comment\0' + PRIVATE.encode()), (b'eXIf', PRIVATE.encode())))
        cleaned, width, height = helper.clean_png(original)
        self.assertEqual((width, height), (2, 1))
        original_chunks, cleaned_chunks = dict(chunks(original)), dict(chunks(cleaned))
        for kind in (b'IHDR', b'IDAT', b'gAMA', b'cHRM', b'sRGB'):
            self.assertEqual(cleaned_chunks[kind], original_chunks[kind])
        self.assertNotIn(b'tEXt', cleaned_chunks)
        self.assertNotIn(b'eXIf', cleaned_chunks)
        self.assertEqual(helper.clean_png(cleaned)[0], cleaned)

    def test_icc_profile_bytes_are_preserved_and_compression_is_bounded(self):
        profile = bytearray(132)
        profile[:4] = struct.pack('>I', len(profile))
        profile[36:40] = b'acsp'
        icc = b'Display P3\0\0' + zlib.compress(bytes(profile))
        original = png(((b'iCCP', icc),))
        cleaned = helper.clean_png(original)[0]
        self.assertEqual(dict(chunks(cleaned))[b'iCCP'], icc)
        self.assertEqual(dict(chunks(cleaned))[b'IDAT'], dict(chunks(original))[b'IDAT'])
        for bad in (b'Display P3\0\1' + zlib.compress(bytes(profile)),
                    b'Display P3\0\0' + zlib.compress(b'\0' * (1024 * 1024 + 1)),
                    b'Display P3\0\0not-zlib'):
            self.expect_error('unsupportedICC', lambda: helper.clean_png(png(((b'iCCP', bad),))))

    def test_png_signature_crc_truncation_and_false_pixels_fail(self):
        valid = png()
        invalid = (b'not a PNG', valid[:-1], valid + b'private trailer',
                   valid[:30] + bytes([valid[30] ^ 1]) + valid[31:],
                   png(pixels=b'\x01'))
        for image in invalid:
            with self.subTest(image=image[:16]):
                with self.assertRaises(helper.EvidenceError):
                    helper.clean_png(image)

    def test_aggregate_requires_three_platforms_and_all_required_stages_each(self):
        self.prepare_platform('iphone')
        self.prepare_platform('ipad')
        self.expect_error('missingPlatforms', lambda: helper.aggregate(self.root / 'inputs', self.root / 'out', IDENTITY))
        self.prepare_platform('mac')
        output = self.root / 'out'
        manifest = helper.aggregate(self.root / 'inputs', output, IDENTITY)
        self.assertEqual(len(manifest['screenshots']), SCREENSHOT_COUNT)
        self.assertEqual(manifest['platforms'], ['iphone', 'ipad', 'mac'])
        self.assertTrue(all(path.is_file() for path in output.iterdir()))
        self.assertEqual(len({shot['file'] for shot in manifest['screenshots']}), SCREENSHOT_COUNT)
        for shot in manifest['screenshots']:
            self.assertTrue(shot['file'].startswith('mirror-ui-' + shot['platform'] + '-'))
        helper.validate_directory(output, IDENTITY, aggregate=True)

    def test_duplicate_platform_is_rejected(self):
        for platform in helper.PLATFORMS:
            self.prepare_platform(platform)
        mac = self.root / 'inputs' / 'mac'
        manifest = json.loads((mac / 'manifest.json').read_text())
        manifest['platform'] = 'iphone'
        files = {shot['file']: (mac / shot['file']).read_bytes() for shot in manifest['screenshots']}
        for name, data in helper.payload(manifest, files).items():
            (mac / name).write_bytes(data)
        self.expect_error('duplicatePlatform', lambda: helper.aggregate(self.root / 'inputs', self.root / 'out', IDENTITY))

    def test_sha_build_run_and_attempt_must_match(self):
        _, output = self.prepare_platform()
        for key in helper.IDENTITY_KEYS:
            with self.subTest(key=key):
                expected = {**IDENTITY, key: 'b' * 40 if key == 'commitSHA' else '2'}
                self.expect_error('identityMismatch', lambda: helper.validate_directory(output, expected))

    def test_mutated_png_manifest_html_checksums_or_extra_log_fail(self):
        _, output = self.prepare_platform()
        original = {path.relative_to(output): path.read_bytes() for path in output.rglob('*') if path.is_file()}
        for filename in ('manifest.json', 'index.html', 'SHA256SUMS', next(name.as_posix() for name in original if name.suffix == '.png')):
            with self.subTest(filename=filename):
                path = output / filename
                path.write_bytes(path.read_bytes() + b' ')
                with self.assertRaises(helper.EvidenceError):
                    helper.validate_directory(output, IDENTITY)
                path.write_bytes(original[Path(filename)])
        (output / 'private.log').write_text(PRIVATE)
        self.expect_error('unexpectedPublicFile', lambda: helper.validate_directory(output, IDENTITY))

    def test_prepare_and_aggregate_retries_are_deterministic(self):
        output = self.aggregate_all()
        original = {path.name: path.read_bytes() for path in output.iterdir()}
        helper.prepare(self.root / 'raw-iphone', self.root / 'inputs' / 'iphone', 'iphone', IDENTITY)
        helper.aggregate(self.root / 'inputs', output, IDENTITY)
        self.assertEqual({path.name: path.read_bytes() for path in output.iterdir()}, original)
        self.assertFalse(list(self.root.glob('.mirror-ui-*')))

    def test_output_with_unrelated_files_or_old_run_is_not_deleted(self):
        source = self.root / 'raw'
        raw_export(source)
        output = self.root / 'out'
        output.mkdir()
        (output / 'private.log').write_text(PRIVATE)
        with self.assertRaises(Exception):
            helper.prepare(source, output, 'iphone', IDENTITY)
        self.assertEqual((output / 'private.log').read_text(), PRIVATE)
        with self.assertRaises(helper.EvidenceError):
            helper.prepare(source, source / 'out', 'iphone', IDENTITY)

    def test_report_has_self_contained_image_data_matching_published_png(self):
        output = self.aggregate_all()
        manifest = json.loads((output / 'ui-review-manifest.json').read_text())
        report = (output / 'ui-review.html').read_text()
        for shot in manifest['screenshots']:
            encoded = base64.b64encode((output / shot['file']).read_bytes()).decode('ascii')
            self.assertIn('data:image/png;base64,' + encoded, report)
        self.assertNotIn('https://', report)
        self.assertIn('default-src', report)

    def test_publish_creates_separate_prerelease_without_touching_eight_app_assets(self):
        output = self.aggregate_all()
        client = FakeGitHub()
        app_before = copy.deepcopy(client.app_release)
        url = helper.publish(client, output, IDENTITY)
        self.assertEqual(url, 'https://github.com/example/mirror/releases/tag/ui-review-31415')
        self.assertEqual(client.app_release, app_before)
        self.assertEqual(client.release['tag_name'], 'ui-review-31415')
        self.assertEqual(client.release['target_commitish'], IDENTITY['commitSHA'])
        self.assertEqual(client.release['make_latest'], 'false')
        self.assertTrue(client.release['prerelease'])
        self.assertFalse(client.release['draft'])
        self.assertEqual(len(client.release['assets']), SCREENSHOT_COUNT + len(helper.PUBLIC_STATIC))
        self.assertTrue(all('adhoc-' not in str(call) for call in client.calls))
        for method, endpoint, value in client.calls:
            if method in ('POST', 'PATCH') and endpoint.startswith('/releases'):
                self.assertEqual(value['make_latest'], 'false')

    def test_publish_same_run_retry_reuses_assets_and_stays_not_latest(self):
        output = self.aggregate_all()
        client = FakeGitHub()
        helper.publish(client, output, IDENTITY)
        assets = copy.deepcopy(client.release['assets'])
        client.calls.clear()
        helper.publish(client, output, IDENTITY)
        self.assertEqual(client.release['assets'], assets)
        self.assertFalse(any(method in ('POST', 'DELETE') for method, _, _ in client.calls))
        self.assertEqual(client.release['make_latest'], 'false')

    def test_changed_attempt_safely_replaces_assets_of_same_run(self):
        output = self.aggregate_all()
        client = FakeGitHub()
        helper.publish(client, output, IDENTITY)
        old_ids = {asset['id'] for asset in client.release['assets']}
        next_identity = {**IDENTITY, 'runAttempt': '2'}
        # 새 Actions attempt는 새로운 artifact 디렉터리를 사용한다.
        manifest = json.loads((output / 'ui-review-manifest.json').read_text())
        manifest.update(next_identity)
        images = {shot['file']: (output / shot['file']).read_bytes() for shot in manifest['screenshots']}
        retry = self.root / 'retry'
        helper.write_directory(retry, helper.payload(manifest, images, aggregate=True), next_identity, aggregate=True)
        helper.publish(client, retry, next_identity)
        self.assertFalse(old_ids & {asset['id'] for asset in client.release['assets']})
        self.assertFalse(client.release['draft'])
        self.assertEqual(client.release['make_latest'], 'false')
        self.assertIn('Attempt 2', client.release['body'])

    def test_wrong_tag_sha_or_unrelated_existing_release_has_no_mutation(self):
        output = self.aggregate_all()
        for mode in ('sha', 'body', 'asset'):
            with self.subTest(mode=mode):
                client = FakeGitHub()
                helper.publish(client, output, IDENTITY)
                if mode == 'sha':
                    client.tag_sha = 'b' * 40
                elif mode == 'body':
                    client.release['body'] = 'unrelated release'
                else:
                    client.release['assets'][0]['name'] = 'Mirror.ipa'
                client.calls.clear()
                with self.assertRaises(helper.EvidenceError):
                    helper.publish(client, output, IDENTITY)
                self.assertFalse(any(method in ('PATCH', 'POST', 'DELETE') for method, _, _ in client.calls))

    def test_invalid_public_assets_fail_before_any_network_request(self):
        output = self.aggregate_all()
        (output / 'video.mp4').write_bytes(PRIVATE.encode())
        client = FakeGitHub()
        self.expect_error('unexpectedPublicFile', lambda: helper.publish(client, output, IDENTITY))
        self.assertEqual(client.calls, [])

    def test_upload_digest_mismatch_leaves_draft_and_never_publishes(self):
        output = self.aggregate_all()
        client = FakeGitHub()
        original = client.request

        def wrong_digest(method, endpoint, **kwargs):
            result = original(method, endpoint, **kwargs)
            if method == 'POST' and endpoint.startswith('https://uploads.github.com/'):
                result['digest'] = 'sha256:' + 'c' * 64
            return result

        client.request = wrong_digest
        self.expect_error('uploadedAssetMismatch', lambda: helper.publish(client, output, IDENTITY))
        self.assertTrue(client.release['draft'])
        self.assertFalse(any(method == 'PATCH' and value.get('draft') is False for method, _, value in client.calls))

    def test_invalid_cli_arguments_do_not_echo_private_inputs(self):
        code, summary, _ = self.invoke(['prepare', '--sha', PRIVATE])
        self.assertEqual(code, 1)
        self.assertEqual(summary['status'], 'invalidArguments')

    def test_ipad_landscape_is_required_only_for_ipad(self):
        source, output = self.prepare_platform('ipad')
        manifest, _ = helper.validate_directory(output, IDENTITY)
        self.assertEqual(len(manifest['screenshots']), 15)
        self.assertIn('ipad-landscape', {shot['stage'] for shot in manifest['screenshots']})
        without_landscape = self.root / 'without-landscape'
        raw_export(without_landscape)
        self.expect_error('missingCoverage', lambda: helper.prepare(without_landscape, self.root / 'out', 'ipad', IDENTITY))
        for platform in ('iphone', 'mac'):
            with self.subTest(platform=platform):
                wrong = self.root / ('wrong-' + platform)
                raw_export(wrong, stages=helper.IPAD_STAGES)
                self.expect_error('invalidPlatformStage', lambda: helper.prepare(wrong, self.root / ('out-' + platform), platform, IDENTITY))

    def test_prepare_and_aggregate_cli_bind_current_provenance(self):
        context = ['--sha', 'a' * 40, '--build-number', '27', '--run-id', '31415', '--attempt', '1']
        for platform in helper.PLATFORMS:
            source, output = self.root / ('raw-' + platform), self.root / 'inputs' / platform
            raw_export(source, stages=helper.required_stages(platform))
            code, summary, _ = self.invoke(['prepare', '--input', str(source), '--output', str(output), '--platform', platform] + context)
            self.assertEqual((code, summary['status'], summary['screenshotCount']), (0, 'prepared', len(helper.required_stages(platform))))
        code, summary, _ = self.invoke(['aggregate', '--input-root', str(self.root / 'inputs'), '--output', str(self.root / 'public')] + context)
        self.assertEqual((code, summary['status'], summary['screenshotCount']), (0, 'aggregated', SCREENSHOT_COUNT))

    def test_publish_cli_uses_actions_context_and_writes_only_release_url(self):
        output = self.aggregate_all()
        client = FakeGitHub()
        github_output = self.root / 'github-output'
        with mock.patch.dict(helper.os.environ, {'GITHUB_REPOSITORY': 'example/mirror', 'GITHUB_TOKEN': PRIVATE,
                                                 'GITHUB_OUTPUT': str(github_output)}), mock.patch.object(helper, 'github_class', return_value=lambda repository, token: client):
            code, summary, _ = self.invoke(['publish', '--publish-dir', str(output), '--sha', 'a' * 40,
                                          '--build-number', '27', '--run-id', '31415', '--attempt', '1'])
        self.assertEqual((code, summary['status']), (0, 'published'))
        self.assertEqual(github_output.read_text(), 'ui_review_url=https://github.com/example/mirror/releases/tag/ui-review-31415\n')


if __name__ == '__main__':
    unittest.main()
