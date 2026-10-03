"""적응형 UI 게이트의 오수용·PNG 경계 회귀. GitHub Actions에서 실행한다."""

import importlib.util
import json
from pathlib import Path
import struct
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('mirror_adaptive_results', ROOT / 'scripts/ci-adaptive-ui-results.py')
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
BUNDLE = 'MirrorIOSAdaptiveUITests'
CASE = 'testMaximumTypeCaptureValidationAndRecovery'
EXPECTED = {'platform': 'iphone', 'appearance': 'system'}
PRIVATE = 'SYNTHETIC_PRIVATE_VALUE'


def event(case=CASE, owner=BUNDLE + '.MirrorAdaptiveUITests', state='started'):
    return "Test Case '-[" + owner + ' ' + case + "]' " + state + '.'


def valid_log(expected=EXPECTED, bundle=BUNDLE):
    lines = []
    for case in helper.required_cases(expected['platform']):
        lines.extend((event(case, bundle + '.MirrorAdaptiveUITests'),
                      helper.CONFIG_MARKER + json.dumps(helper.configuration(expected, case)),
                      event(case, bundle + '.MirrorAdaptiveUITests', 'passed')))
    return '\n'.join(lines)


def tree(platform='iphone', bundle=BUNDLE):
    return {'testNodes': [{'nodeType': 'Test Plan', 'name': PRIVATE, 'children': [
        {'nodeType': 'UI test bundle', 'name': bundle, 'result': 'Passed', 'children': [
            {'nodeType': 'Test Case', 'name': case + '()', 'result': 'Passed'}
            for case in helper.required_cases(platform)]}]}]}


def export(platform='iphone'):
    return [{'testName': PRIVATE, 'testIdentifierURL': '/private/' + PRIVATE,
             'attachments': [{'suggestedHumanReadableName': 'mirror-adaptive-' + stage + '-' + str(index),
                              'exportedFileName': 'shot-' + str(case_index) + '-' + str(index) + '.png',
                              'uniformTypeIdentifier': 'public.png'}
                             for index, stage in enumerate(helper.CASES[case], 1)]}
            for case_index, case in enumerate(helper.required_cases(platform), 1)]


def png(*extra, width=1, height=1, raw=b'\0\xff\x00\x00\xff'):
    return (helper.SIGNATURE + helper.chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
            + b''.join(extra) + helper.chunk(b'IDAT', zlib.compress(raw)) + helper.chunk(b'IEND', b''))


class AdaptiveResultGateTests(unittest.TestCase):
    def test_summary_requires_exact_platform_count_and_integer_fields(self):
        for platform, count in (('iphone', 4), ('ipad', 4), ('macos', 5)):
            valid = {'totalTestCount': count, 'passedTests': count, 'failedTests': 0, 'skippedTests': 0}
            helper.validate_summary(valid, platform)
            for key, replacements in (('totalTestCount', (0, count + 1, True, str(count))),
                                      ('passedTests', (0, count + 1, True, str(count))),
                                      ('failedTests', (1, False, '0')), ('skippedTests', (1, False, '0'))):
                for replacement in replacements:
                    with self.subTest(platform=platform, key=key, replacement=replacement), self.assertRaises(helper.AdaptiveError):
                        helper.validate_summary({**valid, key: replacement}, platform)

    def test_tree_requires_exact_adaptive_bundle_and_platform_cases(self):
        helper.validate_tree(tree(), BUNDLE, 'iphone')
        helper.validate_tree(tree('macos', 'MirrorMacAdaptiveUITests'), 'MirrorMacAdaptiveUITests', 'macos')
        for value in (tree(bundle='MirrorIOSUITests'), tree('macos')):
            with self.assertRaises(helper.AdaptiveError):
                helper.validate_tree(value, BUNDLE, 'iphone')
        for path in ('bundle', 'case'):
            value = tree()
            node = value['testNodes'][0]['children'][0]
            if path == 'case':
                node = node['children'][0]
            node['result'] = 'Failed'
            with self.assertRaises(helper.AdaptiveError):
                helper.validate_tree(value, BUNDLE, 'iphone')

    def test_extra_bundles_duplicate_cases_and_legacy_cases_are_rejected(self):
        values = []
        value = tree()
        value['testNodes'][0]['children'].append({'nodeType': 'UI test bundle', 'name': BUNDLE, 'result': 'Passed'})
        values.append(value)
        value = tree()
        value['testNodes'][0]['children'][0]['children'].append({'nodeType': 'Test Case', 'name': CASE + '()', 'result': 'Passed'})
        values.append(value)
        value = tree()
        value['testNodes'][0]['children'][0]['children'][0]['name'] = 'testOverlongTitleShowsErrorAndPreservesEveryCharacter()'
        values.append(value)
        values.append({'testNodes': [{'nodeType': 'Test Case', 'name': CASE + '()', 'result': 'Passed'}]})
        for value in values:
            with self.assertRaises(helper.AdaptiveError):
                helper.validate_tree(value, BUNDLE, 'iphone')

    def test_log_binds_module_class_all_cases_and_one_execution_each(self):
        helper.validate_log(valid_log(), BUNDLE, EXPECTED)
        for value in (valid_log().replace('.MirrorAdaptiveUITests', '.OtherClass'),
                      valid_log().replace(BUNDLE, 'MirrorIOSUITests'), valid_log() + '\n' + event(state='passed'),
                      valid_log().replace("' passed.", "' failed.", 1),
                      valid_log().replace("' started.", "' skipped.", 1),
                      valid_log() + '\n' + event('testOverlongTitleShowsErrorAndPreservesEveryCharacter')):
            with self.assertRaises(helper.AdaptiveError):
                helper.validate_log(value, BUNDLE, EXPECTED)

    def test_applied_configuration_is_owned_once_per_case_and_matches_matrix(self):
        values = [valid_log() + '\n' + helper.CONFIG_MARKER + json.dumps(helper.configuration(EXPECTED, CASE)),
                  valid_log().replace('accessibility5', 'large', 1), valid_log().replace('"system"', '"dark"', 1),
                  valid_log().replace('"standard"', '"narrow"', 1), valid_log().replace('"iphone"', '"ipad"', 1),
                  valid_log().replace('"dynamicType":', '"private": "' + PRIVATE + '", "dynamicType":', 1)]
        for value in values:
            with self.assertRaises(helper.AdaptiveError):
                helper.validate_log(value, BUNDLE, EXPECTED)
        with self.assertRaises(helper.AdaptiveError):
            helper.validate_log('\n'.join((event(), event(state='passed'))), BUNDLE, EXPECTED)
        mac = {'platform': 'macos', 'appearance': 'dark'}
        helper.validate_log(valid_log(mac, 'MirrorMacAdaptiveUITests'), 'MirrorMacAdaptiveUITests', mac)

    def test_parallel_or_retried_cases_are_rejected_but_suite_order_is_flexible(self):
        lines = valid_log().splitlines()
        with self.assertRaises(helper.AdaptiveError):
            helper.validate_log('\n'.join((lines[0], lines[3], *lines[1:])), BUNDLE, EXPECTED)
        with self.assertRaises(helper.AdaptiveError):
            helper.validate_log(valid_log() + '\n' + '\n'.join(lines[:3]), BUNDLE, EXPECTED)
        blocks = [lines[index:index + 3] for index in range(0, len(lines), 3)]
        helper.validate_log('\n'.join(line for block in reversed(blocks) for line in block), BUNDLE, EXPECTED)

    def test_multiple_native_case_events_on_one_line_are_rejected(self):
        lines = valid_log().splitlines()
        lines[0] += ' ' + event('foreignCase', BUNDLE + '.OtherClass')
        with self.assertRaises(helper.AdaptiveError):
            helper.validate_log('\n'.join(lines), BUNDLE, EXPECTED)

    def test_duplicate_json_keys_and_nonfinite_numbers_are_rejected(self):
        for value in ('{"dynamicType":"large","dynamicType":"accessibility5"}', '{"value":NaN}'):
            with self.assertRaises(helper.AdaptiveError):
                helper.strict_json(value)

    def test_safe_outcome_rejects_stale_identity_unknown_values_and_fake_pass(self):
        expected = {**EXPECTED, 'commitSHA': 'a' * 40, 'buildNumber': '12', 'runID': '34', 'runAttempt': '1'}
        valid = {**expected, 'phase': 'test', 'status': 'passed', 'commandExitCode': 0, 'xcodebuildExitCode': 0,
                 'totalTestCount': 4, 'passedTests': 4, 'failedTests': 0, 'skippedTests': 0, 'screenshotCount': 11}
        helper.validate_outcome(valid, expected)
        for key, value in (('runID', '33'), ('status', PRIVATE), ('xcodebuildExitCode', 65),
                           ('commandExitCode', True), ('screenshotCount', 10), ('private', PRIVATE)):
            with self.assertRaises(helper.AdaptiveError):
                helper.validate_outcome({**valid, key: value}, expected)
        failed = {**expected, 'phase': 'test', 'status': 'failed', 'commandExitCode': 65, 'xcodebuildExitCode': 65}
        helper.validate_outcome(failed, expected)
        with self.assertRaises(helper.AdaptiveError):
            helper.validate_outcome({**failed, 'passedTests': 4}, expected)

    def test_full_screenshot_coverage_requires_eleven_mobile_and_thirteen_mac(self):
        for platform, count in (('iphone', 11), ('ipad', 11), ('macos', 13)):
            entries = helper.export_entries(export(platform), platform)
            self.assertEqual(len(entries), count)
            self.assertEqual({case for case, _, _ in entries}, set(helper.required_cases(platform)))

    def test_screenshot_duplicates_wrong_stages_and_paths_are_rejected(self):
        values = []
        value = export()
        value[0]['attachments'].append(dict(value[0]['attachments'][0]))
        values.append(value)
        value = export()
        value[0]['attachments'][1]['exportedFileName'] = value[0]['attachments'][0]['exportedFileName']
        values.append(value)
        value = export()
        value[0]['attachments'][0]['suggestedHumanReadableName'] = 'mirror-adaptive-max-week-1'
        values.append(value)
        value = export()
        value[0]['attachments'][0]['exportedFileName'] = '../private.png'
        values.append(value)
        value = export()
        value[0]['attachments'][0]['uniformTypeIdentifier'] = 'public.jpeg'
        values.append(value)
        for value in values:
            with self.assertRaises(helper.AdaptiveError):
                helper.export_entries(value, 'iphone')

    def test_attachment_records_must_each_own_a_complete_distinct_case(self):
        value = export()
        value.append({'attachments': []})
        with self.assertRaises(helper.AdaptiveError):
            helper.export_entries(value, 'iphone')
        value = export()
        value[0]['attachments'][0], value[1]['attachments'][0] = value[1]['attachments'][0], value[0]['attachments'][0]
        with self.assertRaises(helper.AdaptiveError):
            helper.export_entries(value, 'iphone')
        value = export()
        value[1] = value[0]
        with self.assertRaises(helper.AdaptiveError):
            helper.export_entries(value, 'iphone')

    def test_only_named_app_attachment_contract_is_selected(self):
        value = export()
        value[0]['attachments'].extend(({'name': 'Screenshot of device', 'exportedFileName': 'device.png'},
                                        {'name': PRIVATE, 'exportedFileName': 'video.mp4'}))
        self.assertEqual(len(helper.export_entries(value, 'iphone')), 11)
        value[0]['attachments'].append({'name': 'mirror-adaptive-unknown-1', 'exportedFileName': 'private.png'})
        with self.assertRaises(helper.AdaptiveError):
            helper.export_entries(value, 'iphone')

    def test_observed_sdk_name_suffix_and_conflicting_alias(self):
        value = export()
        attachment = value[0]['attachments'][0]
        canonical = attachment['suggestedHumanReadableName']
        attachment['suggestedHumanReadableName'] += '_1_12345678-1234-1234-1234-123456789ABC.png'
        attachment['name'] = canonical
        self.assertEqual(helper.export_entries(value, 'iphone')[0][1], canonical)
        attachment['name'] = PRIVATE
        with self.assertRaises(helper.AdaptiveError):
            helper.export_entries(value, 'iphone')

    def test_png_scrubs_text_and_exif_without_changing_pixel_chunks(self):
        plain = png()
        decorated = png(helper.chunk(b'tEXt', b'Comment\0' + PRIVATE.encode()), helper.chunk(b'eXIf', PRIVATE.encode()))
        cleaned, width, height = helper.clean_png(decorated)
        self.assertEqual(cleaned, plain)
        self.assertEqual((width, height), (1, 1))
        self.assertNotIn(PRIVATE.encode(), cleaned)

    def test_png_checks_crc_dimensions_idat_size_filter_and_trailing_data(self):
        corrupt = bytearray(png())
        corrupt[29] ^= 1
        for value in (bytes(corrupt), png()[:-1], png() + b'extra', png(width=20000),
                      png(raw=b'\0\xff'), png(raw=b'\5\xff\x00\x00\xff')):
            with self.assertRaises(helper.AdaptiveError):
                helper.clean_png(value)

    def test_png_rejects_animation_and_unknown_critical_chunks(self):
        for kind in (b'acTL', b'ABCD'):
            with self.assertRaises(helper.AdaptiveError):
                helper.clean_png(png(helper.chunk(kind, b'\0')))


if __name__ == '__main__':
    unittest.main()
