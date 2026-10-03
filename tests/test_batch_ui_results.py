"""2/20 UI 게이트가 0개·누락·skip·다른 소유를 성공으로 인정하지 않는 Actions 회귀."""
import copy
import importlib.util
import json
import plistlib
import subprocess
import tempfile
from pathlib import Path
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('mirror_batch_results', ROOT / 'scripts/ci-batch-ui-results.py')
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
BUNDLE = 'MirrorIOSBatchUITests'
EXPECTED = {'commitSHA': 'a' * 40, 'buildNumber': '1', 'runID': '2', 'runAttempt': '1', 'platform': 'iphone'}


def tree(bundle=BUNDLE):
    return {'testNodes': [{'nodeType': 'Test Plan', 'children': [
        {'nodeType': 'UI test bundle', 'name': bundle, 'result': 'Passed', 'children': [
            {'nodeType': 'Test Case', 'name': case + '()', 'result': 'Passed'} for case in helper.CASES]}]}]}


def event(case, state, bundle=BUNDLE):
    return "Test Case '-[" + bundle + '.' + helper.CLASS + ' ' + case + "]' " + state + '.'


def log(bundle=BUNDLE):
    return '\n'.join(line for case in helper.CASES for line in (event(case, 'started', bundle), event(case, 'passed', bundle)))


def outcome():
    return {**EXPECTED, 'phase': 'test', 'status': 'passed', 'commandExitCode': 0, 'xcodebuildExitCode': 0,
            **helper.COUNT_FIELDS, 'methods': list(helper.CASES), 'testSourceSHA256': 'b' * 64,
            'buildReceiptSHA256': 'c' * 64}


class BatchResultGateTests(unittest.TestCase):
    def test_exact_two_typed_cases_and_source_are_accepted(self):
        for bundle in ('MirrorIOSBatchUITests', 'MirrorMacBatchUITests'):
            helper.validate_summary(dict(helper.COUNT_FIELDS))
            helper.validate_tree(tree(bundle), bundle)
            helper.validate_log(log(bundle), bundle)
        source = (ROOT / helper.SOURCE).read_text()
        helper.validate_source(source)
        helper.validate_outcome(outcome(), EXPECTED)

    def test_summary_rejects_zero_boolean_missing_skip_failure_and_wrong_total(self):
        changes = ({'totalTestCount': 0}, {'passedTests': True}, {'skippedTests': 1},
                   {'failedTests': 1}, {'totalTestCount': 3}, {'passedTests': 1})
        for changed in changes:
            with self.subTest(changed=changed), self.assertRaises(helper.BatchError):
                helper.validate_summary({**helper.COUNT_FIELDS, **changed})
        missing = dict(helper.COUNT_FIELDS)
        del missing['skippedTests']
        with self.assertRaises(helper.BatchError):
            helper.validate_summary(missing)

    def test_tree_rejects_missing_duplicate_skipped_failed_and_unexpected_case(self):
        for mutation in ('missing', 'duplicate', 'skipped', 'failed', 'unexpected'):
            value = tree()
            cases = value['testNodes'][0]['children'][0]['children']
            if mutation == 'missing': cases.pop()
            elif mutation == 'duplicate': cases.append(copy.deepcopy(cases[0]))
            elif mutation == 'skipped': cases[0]['result'] = 'Skipped'
            elif mutation == 'failed': cases[0]['result'] = 'Failed'
            else: cases[0]['name'] = 'testUnexpected()'
            with self.subTest(mutation=mutation), self.assertRaises(helper.BatchError):
                helper.validate_tree(value, BUNDLE)

    def test_tree_requires_exact_successful_ui_bundle_and_bounded_structure(self):
        for mutation in ('wrongName', 'unitBundle', 'failedBundle', 'duplicateBundle', 'invalidChildren'):
            value = tree()
            bundle = value['testNodes'][0]['children'][0]
            if mutation == 'wrongName': bundle['name'] = 'OtherUITests'
            elif mutation == 'unitBundle': bundle['nodeType'] = 'Unit test bundle'
            elif mutation == 'failedBundle': bundle['result'] = 'Failed'
            elif mutation == 'duplicateBundle': value['testNodes'][0]['children'].append(copy.deepcopy(bundle))
            else: bundle['children'] = {'name': 'invalid'}
            with self.subTest(mutation=mutation), self.assertRaises(helper.BatchError):
                helper.validate_tree(value, BUNDLE)
        with self.assertRaises(helper.BatchError):
            helper.validate_tree({'testNodes': []}, BUNDLE)

    def test_stdout_cannot_replace_typed_summary_or_tree(self):
        helper.validate_log(log(), BUNDLE)
        for value in ({}, {'totalTestCount': 2, 'passedTests': 2}):
            with self.assertRaises(helper.BatchError): helper.validate_summary(value)
        with self.assertRaises(helper.BatchError): helper.validate_tree({'testNodes': []}, BUNDLE)

    def test_log_rejects_missing_repeated_parallel_failed_skipped_and_other_owner(self):
        first, second = helper.CASES
        bad = ('', event(first, 'started') + '\n' + event(first, 'passed'),
               log() + '\n' + log(),
               '\n'.join((event(first, 'started'), event(second, 'started'), event(first, 'passed'), event(second, 'passed'))),
               log().replace("passed.", "failed.", 1), log().replace("passed.", "skipped.", 1),
               log('MirrorMacBatchUITests'), log().replace(helper.CLASS, 'OtherClass'))
        for value in bad:
            with self.subTest(value=value), self.assertRaises(helper.BatchError): helper.validate_log(value, BUNDLE)

    def test_source_requires_exact_two_named_methods_and_class(self):
        source = (ROOT / helper.SOURCE).read_text()
        for value in (source.replace('final class MirrorBatchUITests:', 'final class OtherTests:'),
                      source.replace(helper.CASES[0], 'testMissing'),
                      source + '\n    func testUnexpected() throws {\n',
                      source + '\n    func ' + helper.CASES[0] + '() throws {\n'):
            with self.assertRaises(helper.BatchError): helper.validate_source(value)

    def test_outcome_rejects_other_source_run_attempt_platform_bad_counts_and_raw_fields(self):
        for changes in ({'commitSHA': 'd' * 40}, {'runID': '3'}, {'runAttempt': '2'}, {'platform': 'macos'},
                        {'skippedTests': 1}, {'passedTests': True}, {'methods': list(reversed(helper.CASES))},
                        {'xcodebuildExitCode': 65}, {'commandExitCode': 1}, {'testSourceSHA256': 'invalid'},
                        {'rawLog': 'SYNTHETIC_PRIVATE_VALUE'}):
            with self.subTest(changes=changes), self.assertRaises(helper.BatchError):
                helper.validate_outcome({**outcome(), **changes}, EXPECTED)

    def test_failed_and_build_only_outcomes_do_not_have_passed_counts(self):
        failed = {**EXPECTED, 'phase': 'test', 'status': 'failed', 'commandExitCode': 1, 'xcodebuildExitCode': 65}
        built = {**EXPECTED, 'phase': 'build', 'status': 'buildComplete', 'commandExitCode': 0, 'xcodebuildExitCode': 0}
        helper.validate_outcome(failed, EXPECTED)
        helper.validate_outcome(built, EXPECTED)
        for value in ({**failed, **helper.COUNT_FIELDS}, {**built, **helper.COUNT_FIELDS},
                      {**failed, 'status': 'passed'}, {**built, 'status': 'passed'}):
            with self.assertRaises(helper.BatchError): helper.validate_outcome(value, EXPECTED)


    def test_failure_diagnostics_keep_only_current_case_and_source_without_payload(self):
        case = helper.CASES[0]
        private = 'SYNTHETIC_PRIVATE_VALUE'
        log = str(ROOT / helper.SOURCE) + ':30:5: error: -[' + BUNDLE + '.' + helper.CLASS + ' ' + case + '] : XCTAssertEqual failed: ' + private
        report = helper.failure_locations(log, BUNDLE)
        self.assertEqual(report, [{'scope': 'stdoutOnly', 'method': case, 'sourceFile': helper.SOURCE,
                                  'line': 30, 'column': 5, 'assertionKind': 'XCTAssertEqual'}])
        self.assertEqual(helper.failure_locations(log.replace(':30:5:', ':30:'), BUNDLE),
                         [{key: value for key, value in report[0].items() if key != 'column'}])
        self.assertNotIn(private, str(report))
        self.assertNotIn(str(ROOT), str(report))
        self.assertEqual(helper.failure_locations(log.replace(BUNDLE, 'OtherUITests'), BUNDLE), [])
        self.assertEqual(helper.failure_locations(log.replace(helper.SOURCE, 'Tests/Other.swift'), BUNDLE), [])
        self.assertEqual(helper.failure_locations(log.replace(case, 'testUnexpected'), BUNDLE), [])

    def test_failure_diagnostics_bound_lines_and_deduplicate(self):
        case = helper.CASES[0]
        rows = [str(ROOT / helper.SOURCE) + ':' + str(line) + ':1: error: -[' + BUNDLE + '.' + helper.CLASS + ' ' + case + '] : XCTFail failed: SYNTHETIC_PRIVATE_VALUE'
                for line in range(1, 20)]
        report = helper.failure_locations('\n'.join(row for row in rows for _ in (0, 1)), BUNDLE)
        self.assertEqual(len(report), 12)
        self.assertEqual([entry['line'] for entry in report], list(range(1, 13)))


    def test_runtime_discovery_does_not_inherit_native_stderr(self):
        runtime_id = 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'
        device = {'name': 'iPhone Synthetic', 'state': 'Shutdown', 'udid': '00000000-0000-0000-0000-000000000001'}
        baseline = {'observedToolchain': {'iOSSimulatorRuntime': '27.0'}}
        runtimes = {'runtimes': [{'version': '27.0', 'isAvailable': True, 'identifier': runtime_id}]}
        devices = {'devices': {runtime_id: [device]}}
        with mock.patch.object(helper.SUPPORT, 'read_json', return_value=baseline), \
                mock.patch.object(helper.subprocess, 'check_output', side_effect=[json.dumps(runtimes).encode(), json.dumps(devices).encode()]) as native:
            self.assertEqual(helper.runtime_and_devices(), [device])
        self.assertEqual(native.call_count, 2)
        self.assertTrue(all(call.kwargs.get('stderr') == subprocess.DEVNULL for call in native.call_args_list))


    def build_products_fixture(self, directory, run_count=2, bundle_count=2):
        directory = Path(directory).resolve()
        products = directory / 'DerivedData/Build/Products'
        products.mkdir(parents=True)
        def bundle(path, executable):
            path.mkdir(parents=True)
            (path / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': executable, 'CFBundleVersion': '1'}))
            (path / executable).write_bytes(b'synthetic native executable')
        bundle(products / 'Debug-iphonesimulator/Mirror.app', 'Mirror')
        for index in range(run_count):
            (products / ('Synthetic-' + str(index) + '.xctestrun')).write_bytes(b'synthetic xctestrun')
        for index in range(bundle_count):
            bundle(products / ('Copy-' + str(index)) / (BUNDLE + '.xctest'), BUNDLE)
        return products

    def test_build_receipt_records_all_bounded_native_product_copies(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory).resolve()
            self.build_products_fixture(directory)
            context = {**helper.base_context(EXPECTED), 'destination': 'platform=iOS Simulator,id=00000000-0000-0000-0000-000000000001'}
            with mock.patch.object(helper, 'context_for', return_value=context):
                receipt = helper.build_state(Path(directory), EXPECTED)
            self.assertEqual(len(receipt['xctestruns']), 2)
            self.assertEqual(len(receipt['testBundles']), 2)
            self.assertEqual(receipt['context'], context)
            self.assertEqual(len({record['path'] for record in receipt['xctestruns']}), 2)
            self.assertEqual(len({record['path'] for record in receipt['testBundles']}), 2)
            self.assertTrue(all(len(record['sha256']) == 64 for record in receipt['xctestruns']))
            self.assertTrue(all(len(record['executable']['sha256']) == 64 for record in receipt['testBundles']))

    def test_build_receipt_rejects_zero_and_seventeen_native_products(self):
        for runs, bundles in ((0, 1), (1, 0), (17, 1), (1, 17)):
            with self.subTest(runs=runs, bundles=bundles), tempfile.TemporaryDirectory() as directory:
                directory = Path(directory).resolve()
                self.build_products_fixture(directory, runs, bundles)
                context = {**helper.base_context(EXPECTED), 'destination': 'platform=iOS Simulator,id=00000000-0000-0000-0000-000000000001'}
                with mock.patch.object(helper, 'context_for', return_value=context), self.assertRaises(helper.BatchError):
                    helper.build_state(Path(directory), EXPECTED)

    def test_changed_native_product_or_current_receipt_is_rejected(self):
        for changed in ('app', 'bundle', 'run', 'receipt'):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary).resolve()
                products = self.build_products_fixture(directory)
                context = {**helper.base_context(EXPECTED), 'destination': 'platform=iOS Simulator,id=00000000-0000-0000-0000-000000000001'}
                with mock.patch.object(helper, 'context_for', return_value=context):
                    receipt = helper.build_state(directory, EXPECTED)
                    helper.SUPPORT.write_json(directory / 'build-receipt.json', receipt, exclusive=True)
                    self.assertEqual(len(helper.verify_receipt(directory, EXPECTED)), 64)
                    if changed == 'app':
                        (products / 'Debug-iphonesimulator/Mirror.app/Mirror').write_bytes(b'changed synthetic app')
                    elif changed == 'bundle':
                        (products / 'Copy-1' / (BUNDLE + '.xctest') / BUNDLE).write_bytes(b'changed synthetic test bundle')
                    elif changed == 'run':
                        (products / 'Synthetic-1.xctestrun').write_bytes(b'changed synthetic xctestrun')
                    else:
                        receipt['context']['commitSHA'] = 'd' * 40
                        helper.SUPPORT.write_json(directory / 'build-receipt.json', receipt)
                        context = {**helper.base_context(EXPECTED), 'destination': 'platform=iOS Simulator,id=00000000-0000-0000-0000-000000000001'}
                        # mock return도 같은 context object를 공유하므로 원래 소유를 다시 설정한다.
                        helper.context_for.return_value = context
                    with self.assertRaises(helper.BatchError):
                        helper.verify_receipt(directory, EXPECTED)

    def query_failure_fixture(self, payload, bundle=BUNDLE, case=None, source=None, line=30, column=5, source_root=ROOT):
        case = helper.CASES[0] if case is None else case
        source = helper.SOURCE if source is None else source
        position = str(line) + (':' + str(column) if column is not None else '')
        return str(source_root / source) + ':' + position + ': error: -[' + bundle + '.' + helper.CLASS + ' ' + case + '] : ' + payload

    def test_query_failure_diagnostics_classify_only_fixed_anchored_prefixes(self):
        examples = (
            ('Failed to get matching snapshot', 'failedToGetMatchingSnapshot'),
            ('Failed to get matching snapshots', 'failedToGetMatchingSnapshot'),
            ('Multiple matching elements found', 'multipleMatchingElements'),
            ('No matching elements found', 'noMatchingElements'),
            ('No matches found', 'noMatchingElements'),
            ('AX snapshot timed out', 'axSnapshotTimedOut'),
            ('Element query evaluation failed', 'elementQueryEvaluationFailed'),
            ('Application is not running', 'applicationNotRunning'),
            ('Unhandled XCTest exception', 'unhandledXCTestException'),
        )
        private = 'SYNTHETIC_PRIVATE_TITLE 11111111-2222-3333-4444-555555555555 /private/synthetic/value'
        for bundle in ('MirrorIOSBatchUITests', 'MirrorMacBatchUITests'):
            for case in helper.CASES:
                for prefix, kind in examples:
                    with self.subTest(bundle=bundle, case=case, kind=kind):
                        value = self.query_failure_fixture(prefix + ': ' + private, bundle=bundle, case=case)
                        report = helper.query_failure_locations(value, bundle)
                        self.assertEqual(report, [{'scope': 'stdoutOnly', 'method': case, 'sourceFile': helper.SOURCE,
                                                   'line': 30, 'column': 5, 'queryFailureKind': kind}])
                        self.assertNotIn(private, json.dumps(report))
                        self.assertNotIn(str(ROOT), json.dumps(report))
        no_column = self.query_failure_fixture('Failed to get matching snapshots: ' + private, column=None)
        self.assertEqual(helper.query_failure_locations(no_column, BUNDLE),
                         [{'scope': 'stdoutOnly', 'method': helper.CASES[0], 'sourceFile': helper.SOURCE,
                           'line': 30, 'queryFailureKind': 'failedToGetMatchingSnapshot'}])

    def test_query_failure_diagnostics_keep_unknown_private_and_assertions_separate(self):
        values = ('SYNTHETIC_PRIVATE_TITLE', 'prefix Failed to get matching snapshots: SYNTHETIC_PRIVATE_TITLE',
                  'Failed to get matching snapshotsUnexpected: SYNTHETIC_PRIVATE_TITLE',
                  'failed to get matching snapshots: SYNTHETIC_PRIVATE_TITLE', 'XCTAssertSynthetic failed: SYNTHETIC_PRIVATE_TITLE')
        for payload in values:
            with self.subTest(payload=payload):
                report = helper.query_failure_locations(self.query_failure_fixture(payload), BUNDLE)
                self.assertEqual(report[0]['queryFailureKind'], 'unknown')
                self.assertEqual(set(report[0]), {'scope', 'method', 'sourceFile', 'line', 'column', 'queryFailureKind'})
                self.assertNotIn('SYNTHETIC_PRIVATE_TITLE', json.dumps(report))
        for assertion in helper.SUPPORT.UI_ASSERTION_KINDS:
            value = self.query_failure_fixture(assertion + ' failed: Failed to get matching snapshots: SYNTHETIC_PRIVATE_TITLE')
            self.assertEqual(helper.query_failure_locations(value, BUNDLE), [])

    def test_query_failure_diagnostics_reject_wrong_owner_source_and_real_bounds(self):
        payload = 'Failed to get matching snapshots: SYNTHETIC_PRIVATE_TITLE'
        count = len((ROOT / helper.SOURCE).read_text().splitlines())
        values = (
            self.query_failure_fixture(payload, bundle='OtherUITests'),
            self.query_failure_fixture(payload, bundle='MirrorMacBatchUITests'),
            self.query_failure_fixture(payload, case='testUnexpected'),
            self.query_failure_fixture(payload).replace('.' + helper.CLASS + ' ', '.OtherTests '),
            self.query_failure_fixture(payload, source='Tests/Other.swift'),
            self.query_failure_fixture(payload, source='../' + helper.SOURCE),
            self.query_failure_fixture(payload, source_root=Path('/private/synthetic')),
            self.query_failure_fixture(payload, line=0),
            self.query_failure_fixture(payload, line=count + 1, column=1),
            self.query_failure_fixture(payload, line=count + 2, column=1),
            self.query_failure_fixture(payload, column=0),
            self.query_failure_fixture(payload, column=99999),
        )
        for value in values:
            with self.subTest(value=value):
                self.assertEqual(helper.query_failure_locations(value, BUNDLE), [])
        last = self.query_failure_fixture(payload, line=count, column=1)
        self.assertEqual(helper.query_failure_locations(last, BUNDLE)[0]['line'], count)
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary).resolve()
            source = source_root / helper.SOURCE
            source.parent.mkdir(parents=True)
            source.symlink_to(ROOT / helper.SOURCE)
            value = self.query_failure_fixture(payload, source_root=source_root)
            self.assertEqual(helper.query_failure_locations(value, BUNDLE, source_root), [])
        with mock.patch.object(helper.SUPPORT, 'source_location', return_value={'file': helper.SOURCE, 'line': 30, 'column': 5}), \
                mock.patch.object(helper.SUPPORT, 'read_regular', side_effect=OSError('SYNTHETIC_PRIVATE_VALUE')):
            self.assertEqual(helper.query_failure_locations(self.query_failure_fixture(payload), BUNDLE), [])

    def test_query_failure_diagnostics_bound_and_deduplicate_only_fixed_records(self):
        rows = [self.query_failure_fixture('Failed to get matching snapshots: SYNTHETIC_PRIVATE_TITLE ' + str(line), line=line, column=1)
                for line in range(1, 20)]
        value = '\n'.join(row for row in rows for _ in (0, 1))
        reports = helper.query_failure_locations(value, BUNDLE)
        self.assertEqual(len(reports), 12)
        self.assertEqual([report['line'] for report in reports], list(range(1, 13)))
        self.assertTrue(all(report['queryFailureKind'] == 'failedToGetMatchingSnapshot' for report in reports))
        changed = '\n'.join((rows[0], rows[0].replace('SYNTHETIC_PRIVATE_TITLE 1', 'SYNTHETIC_OTHER_TITLE')))
        self.assertEqual(len(helper.query_failure_locations(changed, BUNDLE)), 1)
        with self.assertRaises(helper.BatchError):
            helper.query_failure_locations(None, BUNDLE)
        with mock.patch.object(helper, 'MAX_LOG', 8), self.assertRaises(helper.BatchError):
            helper.query_failure_locations(value, BUNDLE)

    def test_query_failure_notice_preserves_original_notice_and_filters_payload(self):
        value = self.query_failure_fixture('Failed to get matching snapshots: SYNTHETIC_PRIVATE_TITLE 11111111-2222-3333-4444-555555555555 /private/synthetic/value')
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / 'test.log').write_text(value)
            with mock.patch.object(helper, 'context_for', return_value={'bundle': BUNDLE}), mock.patch('builtins.print') as printed:
                helper.diagnostics(directory, EXPECTED, 'test')
        messages = [call.args[0] for call in printed.call_args_list]
        self.assertEqual(len(messages), 2)
        original = {**EXPECTED, 'phase': 'test', 'scope': 'stdoutOnly', 'locations': helper.failure_locations(value, BUNDLE)}
        self.assertEqual(messages[0], '::notice::Batch UI source diagnostics: ' + json.dumps(original, sort_keys=True))
        prefix = '::notice::Batch UI query failure diagnostics: '
        self.assertTrue(messages[1].startswith(prefix))
        report = json.loads(messages[1][len(prefix):])
        self.assertEqual(report, {**EXPECTED, 'phase': 'test', 'scope': 'stdoutOnly', 'locationCount': 1,
                                  'locations': helper.query_failure_locations(value, BUNDLE)})
        self.assertEqual(set(report), set(EXPECTED) | {'phase', 'scope', 'locations', 'locationCount'})
        for private in ('SYNTHETIC_PRIVATE_TITLE', '11111111-2222-3333-4444-555555555555', '/private/synthetic/value', str(ROOT)):
            self.assertNotIn(private, '\n'.join(messages))

    def test_query_failure_notice_does_not_change_build_or_empty_diagnostics(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / 'build.log').write_text('SYNTHETIC_PRIVATE_TITLE')
            (directory / 'test.log').write_text('SYNTHETIC_PRIVATE_TITLE')
            with mock.patch.object(helper, 'context_for', return_value={'bundle': BUNDLE}), \
                    mock.patch.object(helper.SUPPORT, 'compiler_diagnostics', return_value=[]), \
                    mock.patch('builtins.print') as printed:
                helper.diagnostics(directory, EXPECTED, 'build')
            self.assertEqual(printed.call_args_list, [mock.call('::notice::Batch UI source diagnostics: ' + json.dumps(
                {**EXPECTED, 'phase': 'build', 'scope': 'stdoutOnly', 'locations': []}, sort_keys=True))])
            with mock.patch.object(helper, 'context_for', return_value={'bundle': BUNDLE}), mock.patch('builtins.print') as printed:
                helper.diagnostics(directory, EXPECTED, 'test')
            self.assertEqual(len(printed.call_args_list), 2)
            prefix = '::notice::Batch UI query failure diagnostics: '
            empty = json.loads(printed.call_args_list[1].args[0][len(prefix):])
            self.assertEqual(empty['locations'], [])
            self.assertEqual(empty['locationCount'], 0)


if __name__ == '__main__':
    unittest.main()
