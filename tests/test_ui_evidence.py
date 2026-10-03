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
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlsplit
import zlib


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('mirror_ui_evidence', ROOT / 'scripts/ci-ui-evidence.py')
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
PRIVATE = 'SYNTHETIC_PRIVATE_LOG_OR_GEOMETRY'
IDENTITY = helper.identity('a' * 40, '27', '31415', '1')
METHOD = 'mirroriosuitests-mirroruitests-testexplicitcompletionandundopreserveeditedtitleandplan'
SDK_SUFFIX = '_1_12345678-90AB-CDEF-1234-567890ABCDEF.png'
SCREENSHOT_COUNT = sum(len(helper.required_stages(platform)) for platform in helper.PLATFORMS)


def png(extra=(), pixels=b'\xff\x00\x00\x00\xff\x00', *, width=2, height=1):
    # 두 RGB pixel을 가진 정상 PNG다. PNG signature만 맞춘 임의 bytes를 사용하지 않는다.
    row_size = width * 3
    filtered = b''.join(b'\0' + pixels[index:index + row_size] for index in range(0, len(pixels), row_size))
    return (helper.PNG_SIGNATURE + helper.png_chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) +
            b''.join(helper.png_chunk(kind, data) for kind, data in extra) +
            helper.png_chunk(b'IDAT', zlib.compress(filtered)) + helper.png_chunk(b'IEND', b''))


def chunks(data):
    result, position = [], 8
    while position < len(data):
        size = struct.unpack('>I', data[position:position + 4])[0]
        result.append((data[position + 4:position + 8], data[position + 8:position + 8 + size]))
        position += size + 12
    return result


def tiff_orientation(value, *, endian='<', private=b''):
    """실제 classic TIFF IFD0 구조와 선택적인 비공개 description fixture다."""
    count = 2 if private else 1
    data_offset = 8 + 2 + count * 12 + 4
    description = (struct.pack(endian + 'HHII', 0x010E, 2, len(private), data_offset)
                   if private else b'')
    orientation = (struct.pack(endian + 'HHI', 0x0112, 3, 1)
                   + struct.pack(endian + 'H', value) + b'\0\0')
    return ((b'II' if endian == '<' else b'MM') + struct.pack(endian + 'HI', 42, 8)
            + struct.pack(endian + 'H', count) + description + orientation
            + struct.pack(endian + 'I', 0) + private)


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

    def test_sdk27_export_suffix_preserves_pixels_and_canonical_names(self):
        source = self.root / 'sdk27'
        value = raw_export(source)
        originals = []
        for attachment in value[0]['attachments'][:len(helper.STAGES)]:
            originals.append(attachment['suggestedHumanReadableName'])
            attachment['suggestedHumanReadableName'] += SDK_SUFFIX
        rewrite_export(source, value)
        output = self.root / 'sdk27-prepared'
        manifest = helper.prepare(source, output, 'iphone', IDENTITY)
        self.assertEqual({shot['name'] for shot in manifest['screenshots']}, set(originals))
        for shot in manifest['screenshots']:
            self.assertNotIn('12345678-90AB-CDEF', shot['file'])
            original_file = source / ('export-' + shot['name'].rsplit('-', 1)[1] + '.png')
            self.assertEqual(dict(chunks(original_file.read_bytes()))[b'IDAT'],
                             dict(chunks((output / shot['file']).read_bytes()))[b'IDAT'])

    def test_sdk_suffix_rejects_unknown_stage_extra_suffix_nonhex_and_unbounded_counter(self):
        base = 'mirror-ui-initial-today-' + METHOD + '-1'
        invalid = (base + SDK_SUFFIX.replace('CDEF', 'GHIJ'),
                   base + SDK_SUFFIX.replace('_1_', '_1234567_'),
                   base + SDK_SUFFIX.replace('.png', '-extra.png'),
                   base + SDK_SUFFIX[:-4], base + SDK_SUFFIX + '.png',
                   base + SDK_SUFFIX.replace('_1_', '_-1_'),
                   base.replace('initial-today', 'unknown') + SDK_SUFFIX,
                   base + '/' + SDK_SUFFIX, base + SDK_SUFFIX.lower())
        for name in invalid:
            with self.subTest(name=name):
                self.expect_error('invalidAttachmentName', lambda: helper.canonical_attachment_name(name))

    def test_sdk_dual_name_allows_only_same_raw_or_canonical_name(self):
        canonical = 'mirror-ui-initial-today-' + METHOD + '-1'
        for index, alias in enumerate((canonical, canonical + '.png', canonical + SDK_SUFFIX,
                                       canonical + SDK_SUFFIX.replace('_1_', '_2_'))):
            source = self.root / ('sdk-alias-' + str(index))
            value = raw_export(source)
            value[0]['attachments'][0].update(suggestedHumanReadableName=canonical + SDK_SUFFIX, name=alias)
            rewrite_export(source, value)
            output = self.root / ('alias-out-' + str(index))
            if index == 3:
                self.expect_error('invalidAttachmentName', lambda: helper.prepare(source, output, 'iphone', IDENTITY))
            else:
                manifest = helper.prepare(source, output, 'iphone', IDENTITY)
                self.assertEqual(len(manifest['screenshots']), len(helper.STAGES))

    def test_distinct_sdk_suffixes_cannot_hide_duplicate_canonical_screenshots(self):
        source = self.root / 'sdk-duplicate'
        value = raw_export(source)
        first, second = value[0]['attachments'][:2]
        canonical = first['suggestedHumanReadableName']
        first['suggestedHumanReadableName'] = canonical + SDK_SUFFIX
        second['suggestedHumanReadableName'] = canonical + SDK_SUFFIX.replace('_1_', '_2_')
        rewrite_export(source, value)
        self.expect_error('duplicateScreenshot', lambda: helper.prepare(source, self.root / 'duplicate-out', 'iphone', IDENTITY))

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

    def test_quick_picker_is_required_for_each_platform_without_legacy_partial_output(self):
        for platform in helper.PLATFORMS:
            with self.subTest(platform=platform):
                source, output = self.root / ('missing-quick-' + platform), self.root / ('out-' + platform)
                stages = tuple(stage for stage in helper.required_stages(platform) if stage != 'quick-plan-picker')
                raw_export(source, stages=stages)
                self.expect_error('missingCoverage', lambda: helper.prepare(source, output, platform, IDENTITY))
                self.assertFalse(output.exists())

    def test_duplicate_quick_picker_cannot_replace_an_original_stage(self):
        for platform in helper.PLATFORMS:
            with self.subTest(platform=platform):
                source, output = self.root / ('duplicate-quick-' + platform), self.root / ('out-' + platform)
                stages = tuple(stage for stage in helper.required_stages(platform) if stage != 'initial-today')
                raw_export(source, stages=stages + ('quick-plan-picker',))
                self.expect_error('duplicateStage', lambda: helper.prepare(source, output, platform, IDENTITY))
                self.assertFalse(output.exists())

    def test_quick_picker_rejects_private_name_and_non_png_attachment_without_raw_fallback(self):
        context = ['--sha', 'a' * 40, '--build-number', '27', '--run-id', '31415', '--attempt', '1']
        cases = [('name', 'suggestedHumanReadableName', 'mirror-ui-quick-plan-picker-' + PRIVATE + '-1',
                  'invalidAttachmentName'),
                 ('type', 'uniformTypeIdentifier', 'public.movie', 'invalidAttachmentType')]
        for case, key, bad_value, expected in cases:
            with self.subTest(case=case):
                source, output = self.root / ('private-quick-' + case), self.root / ('out-' + case)
                value = raw_export(source)
                quick = next(attachment for attachment in value[0]['attachments']
                             if attachment['suggestedHumanReadableName'].startswith('mirror-ui-quick-plan-picker-'))
                quick[key] = bad_value
                rewrite_export(source, value)
                code, summary, _ = self.invoke(['prepare', '--input', str(source), '--output', str(output),
                                                '--platform', 'iphone'] + context)
                self.assertEqual((code, summary['status']), (1, expected))
                self.assertFalse(output.exists())

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

    def test_orientation_cleaner_rebuilds_only_canonical_ifd0_and_is_idempotent(self):
        for endian in ('<', '>'):
            for value in range(1, 9):
                with self.subTest(endian=endian, value=value):
                    exif = tiff_orientation(value, endian=endian, private=PRIVATE.encode() + b'\0')
                    next_offset = len(exif) + len(exif) % 2
                    # 별도 IFD의 서로 다른 orientation은 따라가거나 공개하지 않는다.
                    exif = (exif[:34] + struct.pack(endian + 'I', next_offset) + exif[38:]
                            + (b'\0' if len(exif) % 2 else b'')
                            + tiff_orientation(9 - value, endian=endian)[8:])
                    original = png(((b'gAMA', struct.pack('>I', 45455)), (b'eXIf', exif),
                                    (b'tEXt', b'Comment\0' + PRIVATE.encode()),
                                    (b'iTXt', PRIVATE.encode()), (b'zTXt', PRIVATE.encode())))
                    cleaned, width, height = helper.clean_png(original, preserve_orientation=True)
                    canonical = (bytes.fromhex('49492a000800000001001201030001000000')
                                 + struct.pack('<H', value) + b'\0' * 6)
                    self.assertEqual(len(canonical), 26)
                    image_chunks = chunks(cleaned)
                    self.assertEqual(image_chunks[1], (b'eXIf', canonical))
                    self.assertEqual(sum(kind == b'eXIf' for kind, _ in image_chunks), 1)
                    self.assertEqual((width, height), (2, 1))
                    self.assertEqual(helper.exif_orientation(image_chunks[1][1]), value)
                    preserved = (b'IHDR', b'gAMA', b'IDAT', b'IEND')
                    self.assertEqual([(kind, data) for kind, data in image_chunks if kind != b'eXIf'],
                                     [(kind, data) for kind, data in chunks(original) if kind in preserved])
                    self.assertNotIn(PRIVATE.encode(), cleaned)
                    self.assertEqual(helper.clean_png(cleaned, preserve_orientation=True)[0], cleaned)
                    self.assertEqual(helper.clean_png(cleaned)[0], helper.clean_png(original)[0])
                    self.assertNotIn(b'eXIf', dict(chunks(helper.clean_png(original)[0])))

    def test_ipad_png_provenance_reports_one_safe_notice_without_asset_or_schema_changes(self):
        source, output = self.root / 'provenance-raw', self.root / 'provenance-out'
        image = png(((b'tEXt', b'Comment\0' + PRIVATE.encode()),
                     (b'eXIf', tiff_orientation(8, private=PRIVATE.encode() + b'\0'))), width=1, height=2)
        raw_export(source, stages=helper.IPAD_STAGES, image=image)
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            manifest = helper.prepare(source, output, 'ipad', IDENTITY)
        prefix = '::notice::UI PNG provenance diagnostic: '
        notices = [line[len(prefix):] for line in stdout.getvalue().splitlines() if line.startswith(prefix)]
        self.assertEqual(len(notices), 1)
        diagnostic = json.loads(notices[0])
        self.assertEqual(set(diagnostic), {
            'platform', 'stage', 'exportWidth', 'exportHeight', 'cleanWidth', 'cleanHeight',
            'exportPNGHash', 'exportIHDRHash', 'cleanIHDRHash', 'exportIDATHash', 'cleanIDATHash',
            'exportExifPresent', 'exportExifOrientation', 'cleanExifPresent',
        })
        self.assertEqual((diagnostic['platform'], diagnostic['stage']), ('ipad', 'ipad-landscape'))
        self.assertEqual((diagnostic['exportWidth'], diagnostic['exportHeight'],
                          diagnostic['cleanWidth'], diagnostic['cleanHeight']), (1, 2, 1, 2))
        self.assertEqual(diagnostic['exportPNGHash'], helper.digest(image))
        for channel in ('IHDR', 'IDAT'):
            self.assertEqual(diagnostic['export' + channel + 'Hash'], diagnostic['clean' + channel + 'Hash'])
        self.assertIs(diagnostic['exportExifPresent'], True)
        self.assertEqual(diagnostic['exportExifOrientation'], 8)
        self.assertIs(diagnostic['cleanExifPresent'], True)
        self.assertNotIn(PRIVATE, stdout.getvalue())
        self.assertEqual(len(manifest['screenshots']), 16)
        self.assertEqual(set(manifest), helper.MANIFEST_KEYS)
        _, files = helper.validate_directory(output, IDENTITY)
        self.assertEqual(set(files) - {shot['file'] for shot in manifest['screenshots']}, helper.PREPARE_STATIC)
        for shot in manifest['screenshots']:
            self.assertEqual((shot['width'], shot['height']), (1, 2))
            image_chunks = chunks(files[shot['file']])
            if shot['stage'] == 'ipad-landscape':
                self.assertEqual(image_chunks[1], (b'eXIf', tiff_orientation(8)))
                self.assertEqual(sum(kind == b'eXIf' for kind, _ in image_chunks), 1)
            else:
                self.assertNotIn(b'eXIf', dict(image_chunks))
        for data in files.values():
            self.assertNotIn(PRIVATE.encode(), data)

    def test_png_provenance_hashes_all_idat_payloads_in_order_without_pixel_changes(self):
        compressed = zlib.compress(b'\0\xff\x00\x00\x00\xff\x00')
        midpoint = len(compressed) // 2
        original = (helper.PNG_SIGNATURE
                    + helper.png_chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 1, 8, 2, 0, 0, 0))
                    + helper.png_chunk(b'eXIf', tiff_orientation(6))
                    + helper.png_chunk(b'IDAT', compressed[:midpoint])
                    + helper.png_chunk(b'IDAT', compressed[midpoint:]) + helper.png_chunk(b'IEND', b''))
        cleaned, _, _ = helper.clean_png(original)
        diagnostic = helper.png_provenance(original, cleaned)
        self.assertEqual(diagnostic['exportIDATHash'], helper.digest(compressed))
        self.assertEqual(diagnostic['cleanIDATHash'], helper.digest(compressed))
        self.assertEqual(diagnostic['exportIHDRHash'], diagnostic['cleanIHDRHash'])
        self.assertEqual([payload for kind, payload in chunks(original) if kind == b'IDAT'],
                         [payload for kind, payload in chunks(cleaned) if kind == b'IDAT'])
        oriented, width, height = helper.clean_png(original, preserve_orientation=True)
        self.assertEqual((width, height), (2, 1))
        self.assertEqual(dict(chunks(oriented))[b'IHDR'], dict(chunks(original))[b'IHDR'])
        self.assertEqual([payload for kind, payload in chunks(original) if kind == b'IDAT'],
                         [payload for kind, payload in chunks(oriented) if kind == b'IDAT'])
        self.assertEqual(chunks(oriented)[1], (b'eXIf', tiff_orientation(6)))
        self.assertEqual(helper.clean_png(oriented, preserve_orientation=True)[0], oriented)

    def test_exif_orientation_reads_only_valid_ifd0_short_values_in_both_byte_orders(self):
        for endian in ('<', '>'):
            for value in range(1, 9):
                with self.subTest(endian=endian, value=value):
                    payload = tiff_orientation(value, endian=endian, private=PRIVATE.encode() + b'\0')
                    self.assertEqual(helper.exif_orientation(payload), value)
        empty_ifd = b'II' + struct.pack('<HIHI', 42, 8, 0, 0)
        self.assertIsNone(helper.exif_orientation(empty_ifd))

    def test_malformed_or_unsupported_exif_reports_null_without_changing_png_acceptance(self):
        valid = tiff_orientation(8)
        wrong_kind = valid[:12] + struct.pack('<H', 4) + valid[14:]
        wrong_count = valid[:14] + struct.pack('<I', 2) + valid[18:]
        bad_offset = valid[:4] + struct.pack('<I', 0xffffffff) + valid[8:]
        too_many_entries = valid[:8] + struct.pack('<H', 257) + valid[10:]
        duplicate = (valid[:8] + struct.pack('<H', 2) + valid[10:22] * 2
                     + struct.pack('<I', 0))
        private = tiff_orientation(8, private=PRIVATE.encode() + b'\0')
        private_offset = private[:18] + struct.pack('<I', 0xffffffff) + private[22:]
        unsupported_type = private[:12] + struct.pack('<H', 99) + private[14:]
        bad_next_ifd = valid[:-4] + struct.pack('<I', len(valid) + 100)
        cases = (PRIVATE.encode(), valid[:-1], b'ZZ' + valid[2:],
                 valid[:2] + struct.pack('<H', 43) + valid[4:],
                 tiff_orientation(0), tiff_orientation(9), wrong_kind, wrong_count,
                 bad_offset, too_many_entries, duplicate, private_offset, unsupported_type,
                 bad_next_ifd, valid + b'\0' * (1024 * 1024))
        for index, payload in enumerate(cases):
            with self.subTest(index=index):
                self.assertIsNone(helper.exif_orientation(payload))
                original = png(((b'eXIf', payload),))
                cleaned, _, _ = helper.clean_png(original)
                diagnostic = helper.png_provenance(original, cleaned)
                self.assertIs(diagnostic['exportExifPresent'], True)
                self.assertIsNone(diagnostic['exportExifOrientation'])
                self.assertIs(diagnostic['cleanExifPresent'], False)
                self.assertNotIn(PRIVATE, json.dumps(diagnostic))
                self.assertEqual(diagnostic['exportIDATHash'], diagnostic['cleanIDATHash'])
                oriented, _, _ = helper.clean_png(original, preserve_orientation=True)
                self.assertEqual(oriented, cleaned)
                self.assertNotIn(b'eXIf', dict(chunks(oriented)))

    def test_duplicate_exif_chunks_do_not_select_one_orientation(self):
        original = png(((b'eXIf', tiff_orientation(3)), (b'eXIf', tiff_orientation(8))))
        cleaned, _, _ = helper.clean_png(original)
        diagnostic = helper.png_provenance(original, cleaned)
        self.assertIs(diagnostic['exportExifPresent'], True)
        self.assertIsNone(diagnostic['exportExifOrientation'])
        self.assertIs(diagnostic['cleanExifPresent'], False)
        self.assertEqual(helper.clean_png(original, preserve_orientation=True)[0], cleaned)
        absent = helper.png_provenance(png(), png())
        self.assertIs(absent['exportExifPresent'], False)
        self.assertIsNone(absent['exportExifOrientation'])

    def test_png_provenance_is_not_reported_for_other_platforms_or_failed_gates(self):
        prefix = 'UI PNG provenance diagnostic: '
        for platform in ('iphone', 'mac'):
            with self.subTest(platform=platform):
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    self.prepare_platform(platform)
                self.assertNotIn(prefix, stdout.getvalue())
        missing = self.root / 'missing-landscape'
        raw_export(missing)
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.expect_error('missingCoverage', lambda: helper.prepare(missing, self.root / 'missing-out', 'ipad', IDENTITY))
        self.assertNotIn(prefix, stdout.getvalue())
        corrupt = self.root / 'corrupt-provenance'
        raw_export(corrupt, stages=helper.IPAD_STAGES)
        landscape = corrupt / ('export-' + str(len(helper.IPAD_STAGES)) + '.png')
        damaged = landscape.read_bytes()
        landscape.write_bytes(damaged[:30] + bytes([damaged[30] ^ 1]) + damaged[31:])
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.expect_error('invalidPNG', lambda: helper.prepare(corrupt, self.root / 'corrupt-out', 'ipad', IDENTITY))
        self.assertNotIn(prefix, stdout.getvalue())
        self.assertNotIn(PRIVATE, stdout.getvalue())

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
        quick = [shot for shot in manifest['screenshots'] if shot['stage'] == 'quick-plan-picker']
        self.assertEqual({shot['platform'] for shot in quick}, {'iphone', 'ipad', 'mac'})
        self.assertEqual(len(quick), 3)
        for shot in manifest['screenshots']:
            self.assertTrue(shot['file'].startswith('mirror-ui-' + shot['platform'] + '-'))
        helper.validate_directory(output, IDENTITY, aggregate=True)

    def test_prepare_aggregate_and_publish_preserve_orientation_only_for_ipad_landscape(self):
        image = png(((b'eXIf', tiff_orientation(8, endian='>', private=PRIVATE.encode() + b'\0')),
                     (b'tEXt', b'Comment\0' + PRIVATE.encode())), width=1, height=2)
        default_cleaned = helper.clean_png(image)[0]
        self.assertNotIn(b'eXIf', dict(chunks(default_cleaned)))
        for platform in helper.PLATFORMS:
            source, output = self.root / ('raw-' + platform), self.root / 'inputs' / platform
            raw_export(source, stages=helper.required_stages(platform), image=image)
            helper.prepare(source, output, platform, IDENTITY)
            helper.validate_directory(output, IDENTITY)
        output = self.root / 'public'
        helper.aggregate(self.root / 'inputs', output, IDENTITY)
        manifest, files = helper.validate_directory(output, IDENTITY, aggregate=True)
        default_count = 0
        for shot in manifest['screenshots']:
            data = files[shot['file']]
            self.assertEqual((shot['width'], shot['height']), (1, 2))
            self.assertEqual(dict(chunks(data))[b'IHDR'], dict(chunks(image))[b'IHDR'])
            self.assertEqual([payload for kind, payload in chunks(data) if kind == b'IDAT'],
                             [payload for kind, payload in chunks(image) if kind == b'IDAT'])
            self.assertNotIn(PRIVATE.encode(), data)
            if (shot['platform'], shot['stage']) == ('ipad', 'ipad-landscape'):
                self.assertEqual(chunks(data)[1], (b'eXIf', tiff_orientation(8)))
                self.assertEqual(sum(kind == b'eXIf' for kind, _ in chunks(data)), 1)
            else:
                default_count += 1
                self.assertEqual(data, default_cleaned)
        self.assertEqual(default_count, SCREENSHOT_COUNT - 1)
        self.assertEqual(set(manifest), helper.AGGREGATE_KEYS)
        self.assertTrue(all(set(shot) == helper.PUBLIC_SHOT_KEYS for shot in manifest['screenshots']))
        self.assertIn(b'image-orientation:from-image', files['ui-review.html'])
        client = FakeGitHub()
        helper.publish(client, output, IDENTITY)
        self.assertFalse(client.release['draft'])
        self.assertEqual(len(client.release['assets']), SCREENSHOT_COUNT + len(helper.PUBLIC_STATIC))

    def test_prepare_requires_landscape_display_geometry_before_output_and_notice(self):
        cases = ((2, 1, None, True), (1, 2, None, False), (2, 2, None, False), (2, 2, 8, False))
        cases += tuple((2, 1, value, True) for value in (1, 2, 3, 4))
        cases += tuple((1, 2, value, False) for value in (1, 2, 3, 4))
        cases += tuple((1, 2, value, True) for value in (5, 6, 7, 8))
        cases += tuple((2, 1, value, False) for value in (5, 6, 7, 8))
        for index, (width, height, orientation, accepted) in enumerate(cases):
            with self.subTest(width=width, height=height, orientation=orientation):
                source, output = self.root / ('geometry-' + str(index)), self.root / ('out-' + str(index))
                raw_export(source, stages=helper.IPAD_STAGES)
                extra = () if orientation is None else ((b'eXIf', tiff_orientation(orientation)),)
                pixels = b'\xff\x00\x00\x00\xff\x00' * (2 if width == height == 2 else 1)
                image = png(extra, pixels, width=width, height=height)
                (source / ('export-' + str(len(helper.IPAD_STAGES)) + '.png')).write_bytes(image)
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    if accepted:
                        manifest = helper.prepare(source, output, 'ipad', IDENTITY)
                    else:
                        self.expect_error('invalidLandscapeGeometry',
                                          lambda: helper.prepare(source, output, 'ipad', IDENTITY))
                if accepted:
                    shot = next(shot for shot in manifest['screenshots'] if shot['stage'] == 'ipad-landscape')
                    self.assertEqual((shot['width'], shot['height']), (width, height))
                    helper.validate_directory(output, IDENTITY)
                else:
                    self.assertFalse(output.exists())
                    self.assertNotIn('UI PNG provenance diagnostic: ', stdout.getvalue())
                self.assertNotIn(PRIVATE, stdout.getvalue())

    def test_prepare_does_not_guess_landscape_orientation_from_malformed_or_duplicate_exif(self):
        valid = tiff_orientation(8)
        duplicate_tag = valid[:8] + struct.pack('<H', 2) + valid[10:22] * 2 + struct.pack('<I', 0)
        cases = (((b'eXIf', valid[:-1]),), ((b'eXIf', duplicate_tag),),
                 ((b'eXIf', valid), (b'eXIf', tiff_orientation(6))),
                 ((b'eXIf', valid), (b'eXIf', PRIVATE.encode())))
        for index, extra in enumerate(cases):
            with self.subTest(case=index):
                source, output = self.root / ('invalid-exif-' + str(index)), self.root / ('out-' + str(index))
                raw_export(source, stages=helper.IPAD_STAGES)
                image = png(extra, width=1, height=2)
                (source / ('export-' + str(len(helper.IPAD_STAGES)) + '.png')).write_bytes(image)
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    self.expect_error('invalidLandscapeGeometry',
                                      lambda: helper.prepare(source, output, 'ipad', IDENTITY))
                self.assertFalse(output.exists())
                self.assertNotIn('UI PNG provenance diagnostic: ', stdout.getvalue())
                self.assertNotIn(PRIVATE, stdout.getvalue())

    def test_single_and_aggregate_reject_nonlandscape_display_before_publish_requests(self):
        public = self.aggregate_all()
        cases = (png(width=1, height=2), png(((b'eXIf', tiff_orientation(8)),)),
                 png(((b'eXIf', tiff_orientation(1)),), width=1, height=2),
                 png(((b'eXIf', tiff_orientation(8)),),
                     b'\xff\x00\x00\x00\xff\x00' * 2, width=2, height=2))
        for aggregate, output in ((False, self.root / 'inputs' / 'ipad'), (True, public)):
            manifest_name = 'ui-review-manifest.json' if aggregate else 'manifest.json'
            original = json.loads((output / manifest_name).read_text())
            images = {shot['file']: (output / shot['file']).read_bytes() for shot in original['screenshots']}
            for index, image in enumerate(cases):
                with self.subTest(aggregate=aggregate, case=index):
                    manifest = copy.deepcopy(original)
                    shot = next(shot for shot in manifest['screenshots'] if shot['stage'] == 'ipad-landscape')
                    width, height = struct.unpack('>II', dict(chunks(image))[b'IHDR'][:8])
                    shot.update(sha256=helper.digest(image), bytes=len(image), width=width, height=height)
                    rewritten = {**images, shot['file']: image}
                    for name, data in helper.payload(manifest, rewritten, aggregate=aggregate).items():
                        (output / name).write_bytes(data)
                    self.expect_error('invalidLandscapeGeometry',
                                      lambda: helper.validate_directory(output, IDENTITY, aggregate=aggregate))
                    if aggregate:
                        client = FakeGitHub()
                        self.expect_error('invalidLandscapeGeometry', lambda: helper.publish(client, output, IDENTITY))
                        self.assertEqual(client.calls, [])

    def test_other_public_stages_reject_orientation_metadata_before_publish_requests(self):
        output = self.aggregate_all()
        original = json.loads((output / 'ui-review-manifest.json').read_text())
        images = {shot['file']: (output / shot['file']).read_bytes() for shot in original['screenshots']}
        image = png(((b'eXIf', tiff_orientation(8)),), width=1, height=2)
        for platform in helper.PLATFORMS:
            with self.subTest(platform=platform):
                manifest = copy.deepcopy(original)
                shot = next(shot for shot in manifest['screenshots']
                            if shot['platform'] == platform and shot['stage'] == 'initial-today')
                shot.update(sha256=helper.digest(image), bytes=len(image), width=1, height=2)
                for name, data in helper.payload(manifest, {**images, shot['file']: image}, aggregate=True).items():
                    (output / name).write_bytes(data)
                client = FakeGitHub()
                self.expect_error('unsafePNGMetadata', lambda: helper.publish(client, output, IDENTITY))
                self.assertEqual(client.calls, [])

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
        self.assertEqual(len(manifest['screenshots']), 16)
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

    def publish_arguments(self, output):
        return ['publish', '--publish-dir', str(output), '--sha', 'a' * 40,
                '--build-number', '27', '--run-id', '31415', '--attempt', '1']

    def assert_publication_failure(self, result, phase, category, http_status=None):
        code, summary, stdout = result
        self.assertEqual((code, summary), (1, {'command': 'publish', 'status': 'processingFailed'}))
        lines = stdout.splitlines()
        self.assertEqual(len(lines), 3)
        prefix = '::notice::UI 게시 실패 분류: '
        self.assertTrue(lines[0].startswith(prefix))
        self.assertEqual(json.loads(lines[0][len(prefix):]),
                         {'phase': phase, 'exceptionCategory': category, 'httpStatus': http_status})
        self.assertEqual(lines[1], '::error::UI 화면 증거 처리 실패: processingFailed')
        self.assertIsNone(helper._PUBLICATION_DIAGNOSTIC.get())

    def test_publish_real_loader_classifies_synthetic_http_transport_and_json_failures(self):
        output = self.aggregate_all()
        failures = (
            (HTTPError(PRIVATE, 403, PRIVATE, {}, io.BytesIO(PRIVATE.encode())), 403),
            (URLError(PRIVATE), None),
            (io.BytesIO(PRIVATE.encode()), None),
        )
        for response, http_status in failures:
            with self.subTest(response_kind='response' if isinstance(response, io.BytesIO) else 'exception'):
                replacement = {'return_value': response} if isinstance(response, io.BytesIO) else {'side_effect': response}
                with mock.patch.dict(helper.os.environ, {'GITHUB_REPOSITORY': 'example/mirror', 'GITHUB_TOKEN': PRIVATE}), \
                        mock.patch('urllib.request.urlopen', **replacement) as request:
                    result = self.invoke(self.publish_arguments(output))
                self.assert_publication_failure(result, 'readRelease', 'clientFailure', http_status)
                request.assert_called_once()
                self.assertEqual(request.call_args.args[0].get_method(), 'GET')

    def test_publish_real_loader_http_status_accepts_only_known_exact_integer_codes(self):
        output = self.aggregate_all()
        allowed = (400, 401, 403, 404, 408, 409, 410, 413, 415, 422, 429,
                   500, 501, 502, 503, 504)
        for code in allowed + (True, False, 403.0, '403', PRIVATE, 418, 599):
            with self.subTest(status_kind='known' if type(code) is int and code in allowed else 'rejected'):
                error = HTTPError(PRIVATE, code, PRIVATE, {}, io.BytesIO(PRIVATE.encode()))
                with mock.patch.dict(helper.os.environ, {'GITHUB_REPOSITORY': 'example/mirror', 'GITHUB_TOKEN': PRIVATE}), \
                        mock.patch('urllib.request.urlopen', side_effect=error) as request:
                    result = self.invoke(self.publish_arguments(output))
                if type(code) is int and code == 404:
                    # release/tag 조회의 missing_ok 404는 그대로 통과하고 draft 요청에서 실패한다.
                    self.assert_publication_failure(result, 'prepareDraft', 'clientFailure', 404)
                    self.assertEqual(request.call_count, 3)
                    self.assertEqual([call.args[0].get_method() for call in request.call_args_list], ['GET', 'GET', 'POST'])
                else:
                    expected = code if type(code) is int and code in allowed else None
                    self.assert_publication_failure(result, 'readRelease', 'clientFailure', expected)
                    request.assert_called_once()

    def test_publish_real_loader_does_not_traverse_http_context_or_cause_chain(self):
        output = self.aggregate_all()
        error = URLError(PRIVATE)
        error.__context__ = HTTPError(PRIVATE, 403, PRIVATE, {}, io.BytesIO(PRIVATE.encode()))
        error.__cause__ = HTTPError(PRIVATE, 401, PRIVATE, {}, io.BytesIO(PRIVATE.encode()))
        with mock.patch.dict(helper.os.environ, {'GITHUB_REPOSITORY': 'example/mirror', 'GITHUB_TOKEN': PRIVATE}), \
                mock.patch('urllib.request.urlopen', side_effect=error) as request:
            result = self.invoke(self.publish_arguments(output))
        self.assert_publication_failure(result, 'readRelease', 'clientFailure')
        request.assert_called_once()

    def test_publish_real_loader_rejects_http_named_errors_and_avoids_unrecognized_context(self):
        output = self.aggregate_all()

        def forbidden_code(error):
            raise AssertionError('선언된 HTTPError 외의 code를 읽으면 안 됩니다.')

        def guarded_attribute(error, name):
            if name == '__context__':
                raise AssertionError('선언된 client 오류 외의 context를 읽으면 안 됩니다.')
            return Exception.__getattribute__(error, name)

        cases = (
            (type('HTTPError', (OSError,), {'code': property(forbidden_code)})(PRIVATE), 'clientFailure'),
            (type(PRIVATE, (Exception,), {'__getattribute__': guarded_attribute})(PRIVATE), 'other'),
        )
        for error, category in cases:
            with self.subTest(category=category):
                with mock.patch.dict(helper.os.environ, {'GITHUB_REPOSITORY': 'example/mirror', 'GITHUB_TOKEN': PRIVATE}), \
                        mock.patch('urllib.request.urlopen', side_effect=error) as request:
                    result = self.invoke(self.publish_arguments(output))
                self.assert_publication_failure(result, 'readRelease', category)
                request.assert_called_once()

    def test_publish_real_loader_classifies_synthetic_tag_failure_at_actual_tag_call(self):
        output = self.aggregate_all()
        responses = [HTTPError(PRIVATE, 404, PRIVATE, {}, io.BytesIO(PRIVATE.encode())),
                     io.BytesIO(json.dumps({'object': {'type': 'commit', 'sha': 'b' * 40}}).encode())]
        with mock.patch.dict(helper.os.environ, {'GITHUB_REPOSITORY': 'example/mirror', 'GITHUB_TOKEN': PRIVATE}), \
                mock.patch('urllib.request.urlopen', side_effect=responses) as request:
            result = self.invoke(self.publish_arguments(output))
        self.assert_publication_failure(result, 'verifyTag', 'clientFailure')
        self.assertEqual(request.call_count, 2)
        self.assertTrue(all(call.args[0].get_method() == 'GET' for call in request.call_args_list))

    def test_publish_loader_failure_keeps_private_source_details_out_of_notice(self):
        with mock.patch.dict(helper.os.environ, {'GITHUB_REPOSITORY': 'example/mirror', 'GITHUB_TOKEN': PRIVATE}), \
                mock.patch.object(helper.importlib.util, 'spec_from_file_location', side_effect=ImportError(PRIVATE)):
            result = self.invoke(self.publish_arguments(self.root / PRIVATE))
        self.assert_publication_failure(result, 'loadClient', 'sourceFailure')

    def test_publish_mock_factory_and_three_argument_publish_remain_compatible_on_output_failure(self):
        client = FakeGitHub()
        output = self.root / PRIVATE
        with mock.patch.dict(helper.os.environ, {'GITHUB_REPOSITORY': 'example/mirror', 'GITHUB_TOKEN': PRIVATE,
                                                 'GITHUB_OUTPUT': str(output)}), \
                mock.patch.object(helper, 'github_class', return_value=lambda repository, token: client), \
                mock.patch.object(helper, 'publish', return_value='https://github.com/example/mirror/releases/tag/ui-review-31415') as publish, \
                mock.patch.object(helper, 'open', side_effect=OSError(PRIVATE), create=True):
            result = self.invoke(self.publish_arguments(output))
        publish.assert_called_once_with(client, output, IDENTITY)
        self.assert_publication_failure(result, 'writeOutput', 'ioFailure')

    def test_publish_client_constructor_failure_has_fixed_phase_and_category(self):
        with mock.patch.dict(helper.os.environ, {'GITHUB_REPOSITORY': 'example/mirror', 'GITHUB_TOKEN': PRIVATE}), \
                mock.patch.object(helper, 'github_class', return_value=mock.Mock(side_effect=TypeError(PRIVATE))):
            result = self.invoke(self.publish_arguments(self.root / PRIVATE))
        self.assert_publication_failure(result, 'initializeClient', 'typeFailure')

    def test_publish_notice_failure_does_not_mask_original_error_result_or_exit(self):
        with mock.patch.dict(helper.os.environ, {'GITHUB_REPOSITORY': 'example/mirror', 'GITHUB_TOKEN': PRIVATE}), \
                mock.patch.object(helper, 'github_class', side_effect=ImportError(PRIVATE)), \
                mock.patch.object(helper, 'publication_failure_notice', side_effect=RuntimeError(PRIVATE)) as notice:
            code, summary, stdout = self.invoke(self.publish_arguments(self.root / PRIVATE))
        self.assertEqual((code, summary), (1, {'command': 'publish', 'status': 'processingFailed'}))
        self.assertEqual(stdout.splitlines()[0], '::error::UI 화면 증거 처리 실패: processingFailed')
        self.assertEqual(len(stdout.splitlines()), 2)
        notice.assert_called_once()
        self.assertIsNone(helper._PUBLICATION_DIAGNOSTIC.get())

    def test_publish_evidence_gate_still_fails_before_api_without_new_notice(self):
        output = self.aggregate_all()
        (output / 'video.mp4').write_bytes(PRIVATE.encode())
        with mock.patch.dict(helper.os.environ, {'GITHUB_REPOSITORY': 'example/mirror', 'GITHUB_TOKEN': PRIVATE}), \
                mock.patch('urllib.request.urlopen', side_effect=AssertionError(PRIVATE)) as request:
            code, summary, stdout = self.invoke(self.publish_arguments(output))
        self.assertEqual((code, summary), (1, {'command': 'publish', 'status': 'unexpectedPublicFile'}))
        self.assertNotIn('::notice::', stdout)
        request.assert_not_called()
        self.assertIsNone(helper._PUBLICATION_DIAGNOSTIC.get())

    def test_publication_notice_rejects_unknown_phase_and_never_reads_error_text_or_args(self):
        def forbidden_text(error):
            raise AssertionError('예외 원문을 읽으면 안 됩니다.')

        def guarded_attribute(error, name):
            if name == 'args':
                raise AssertionError('예외 args를 읽으면 안 됩니다.')
            return Exception.__getattribute__(error, name)

        error_type = type(PRIVATE, (Exception,), {'__str__': forbidden_text, '__getattribute__': guarded_attribute})
        for phase in (PRIVATE, [], {}):
            with self.subTest(phase_kind=type(phase).__name__):
                token = helper._PUBLICATION_DIAGNOSTIC.set({'phase': phase, 'clientErrorType': None})
                stdout = io.StringIO()
                try:
                    with contextlib.redirect_stdout(stdout):
                        helper.publication_failure_notice(error_type(PRIVATE))
                finally:
                    helper._PUBLICATION_DIAGNOSTIC.reset(token)
                self.assertEqual(stdout.getvalue(), '::notice::UI 게시 실패 분류: '
                                 '{"exceptionCategory": "other", "httpStatus": null, "phase": "unknown"}\n')
                self.assertNotIn(PRIVATE, stdout.getvalue())

    def test_publication_notice_uses_only_whitelisted_exception_categories(self):
        cases = (
            (ImportError(PRIVATE), 'sourceFailure'),
            (json.JSONDecodeError(PRIVATE, PRIVATE, 0), 'jsonFailure'),
            (UnicodeDecodeError('utf-8', b'\xff', 0, 1, PRIVATE), 'unicodeFailure'),
            (OSError(PRIVATE), 'ioFailure'),
            (TypeError(PRIVATE), 'typeFailure'),
            (ValueError(PRIVATE), 'valueFailure'),
            (KeyError(PRIVATE), 'keyFailure'),
            (AttributeError(PRIVATE), 'attributeFailure'),
            (type('PublishError', (Exception,), {})(PRIVATE), 'other'),
        )
        for error, category in cases:
            with self.subTest(category=category):
                token = helper._PUBLICATION_DIAGNOSTIC.set({'phase': 'readRelease', 'clientErrorType': None})
                stdout = io.StringIO()
                try:
                    with contextlib.redirect_stdout(stdout):
                        helper.publication_failure_notice(error)
                finally:
                    helper._PUBLICATION_DIAGNOSTIC.reset(token)
                prefix = '::notice::UI 게시 실패 분류: '
                diagnostic = json.loads(stdout.getvalue()[len(prefix):])
                self.assertEqual(diagnostic, {'phase': 'readRelease', 'exceptionCategory': category, 'httpStatus': None})
                self.assertNotIn(PRIVATE, stdout.getvalue())


if __name__ == '__main__':
    unittest.main()
