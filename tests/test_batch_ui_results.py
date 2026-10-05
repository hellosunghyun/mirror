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


def progress_lines(case, count=None):
    return [helper.PROGRESS_MARKER + json.dumps({'method': case, 'phase': phase,
            'sequence': index, 'captureOrdinal': ordinal})
            for index, (phase, ordinal) in enumerate(helper.progress_steps(case)[:count], 1)]


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

    def test_reachable_failure_diagnostics_accept_exact_reasons_and_target_enums(self):
        reasons = ('batchTargetIsNotReachableWithin15SecondsAnd12Scrolls', 'batchActualScrollOwnerMissing',
                   'batchActualScrollOwnerWindowNotUnique', 'batchActualScrollOwnerCandidateMissing',
                   'batchActualScrollOwnerAmbiguous', 'batchScrollOwnerRequiresActualSurface')
        targets = ('unknown', 'captureOpen', 'captureSave', 'captureClose', 'destinationToday', 'destinationLibrary',
                   'librarySearch', 'librarySelectToggle', 'librarySelectAll', 'taskRow', 'taskSelection',
                   'planToday', 'planTomorrow', 'planCancel', 'planDisclosure', 'planTask')
        for index, reason in enumerate(reasons):
            bundle = ('MirrorIOSBatchUITests', 'MirrorMacBatchUITests')[index % 2]
            case = helper.CASES[index % 2]
            for target in targets:
                with self.subTest(reason=reason, target=target, bundle=bundle, case=case):
                    value = self.query_failure_fixture('failed - ' + reason + ' target=' + target,
                                                       bundle=bundle, case=case)
                    self.assertEqual(helper.reachable_failure_locations(value, bundle),
                                     [{'scope': 'stdoutOnly', 'method': case, 'sourceFile': helper.SOURCE,
                                       'line': 30, 'column': 5, 'reason': reason, 'target': target}])
        value = self.query_failure_fixture('failed - batchActualScrollOwnerMissing target=librarySearch', column=None)
        self.assertNotIn('column', helper.reachable_failure_locations(value, BUNDLE)[0])

    def test_reachable_failure_diagnostics_reject_payload_quotes_suffixes_and_unknown_enums(self):
        for reason in ('batchActualScrollOwnerMissing', 'batchActualScrollOwnerWindowNotUnique',
                       'batchActualScrollOwnerCandidateMissing'):
            fixed = 'failed - ' + reason + ' target=librarySearch'
            invalid = (fixed + ' SYNTHETIC_PRIVATE_VALUE', fixed + '.', fixed + ' ',
                       'SYNTHETIC_PRIVATE_VALUE ' + fixed, '"' + fixed + '"',
                       'XCTAssertEqual failed: ' + fixed, 'failed - "' + fixed + '"',
                       fixed.replace(reason, 'batchUnknownFailure'), fixed.replace(reason, reason + 'Extra'),
                       fixed.replace('librarySearch', 'SYNTHETIC_PRIVATE_VALUE'),
                       fixed.replace('target=', 'target ='), fixed.replace('failed - ', 'XCTFail failed - '))
            for payload in invalid:
                with self.subTest(reason=reason, payload=payload):
                    self.assertEqual(helper.reachable_failure_locations(self.query_failure_fixture(payload), BUNDLE), [])

    def test_reachable_failure_diagnostics_reject_other_owner_source_and_bounds(self):
        payload = 'failed - batchActualScrollOwnerMissing target=librarySearch'
        count = len((ROOT / helper.SOURCE).read_text().splitlines())
        valid = self.query_failure_fixture(payload)
        invalid = (self.query_failure_fixture(payload, bundle='MirrorMacBatchUITests'),
                   self.query_failure_fixture(payload, bundle='OtherUITests'),
                   self.query_failure_fixture(payload, case='testUnexpected'),
                   valid.replace('.' + helper.CLASS + ' ', '.OtherTests '),
                   self.query_failure_fixture(payload, source='Tests/Other.swift'),
                   self.query_failure_fixture(payload, source='../' + helper.SOURCE),
                   self.query_failure_fixture(payload, source_root=Path('/private/synthetic')),
                   self.query_failure_fixture(payload, line=0),
                   self.query_failure_fixture(payload, line=count + 1, column=1),
                   self.query_failure_fixture(payload, column=0),
                   self.query_failure_fixture(payload, column=99999))
        for value in invalid:
            with self.subTest(value=value):
                self.assertEqual(helper.reachable_failure_locations(value, BUNDLE), [])
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary).resolve()
            source = source_root / helper.SOURCE
            source.parent.mkdir(parents=True)
            source.symlink_to(ROOT / helper.SOURCE)
            self.assertEqual(helper.reachable_failure_locations(
                self.query_failure_fixture(payload, source_root=source_root), BUNDLE, source_root), [])
        rows = [self.query_failure_fixture(payload, line=line, column=1) for line in range(1, 20)]
        reports = helper.reachable_failure_locations('\n'.join(row for row in rows for _ in (0, 1)), BUNDLE)
        self.assertEqual([report['line'] for report in reports], list(range(1, 13)))
        with mock.patch.object(helper, 'MAX_LOG', 8), self.assertRaises(helper.BatchError):
            helper.reachable_failure_locations(valid, BUNDLE)

    def test_reachable_failure_notice_preserves_source_query_and_partial_diagnostics(self):
        value = self.query_failure_fixture('failed - batchActualScrollOwnerMissing target=librarySearch')
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / 'test.log').write_text(value)
            with mock.patch.object(helper, 'context_for', return_value={'bundle': BUNDLE}), mock.patch('builtins.print') as printed:
                helper.diagnostics(directory, EXPECTED, 'test', partial_failure=True)
        messages = [call.args[0] for call in printed.call_args_list]
        self.assertEqual(len(messages), 4)
        base = {**EXPECTED, 'phase': 'test', 'scope': 'stdoutOnly'}
        self.assertEqual(messages[0], '::notice::Batch UI source diagnostics: ' + json.dumps(
            {**base, 'locations': helper.failure_locations(value, BUNDLE)}, sort_keys=True))
        self.assertEqual(messages[1], '::notice::Batch UI query failure diagnostics: ' + json.dumps(
            {**base, 'locations': helper.query_failure_locations(value, BUNDLE), 'locationCount': 1}, sort_keys=True))
        self.assertEqual(messages[2], '::notice::Batch UI reachable failure diagnostics: ' + json.dumps(
            {**base, 'locations': helper.reachable_failure_locations(value, BUNDLE), 'locationCount': 1}, sort_keys=True))
        self.assertEqual(messages[3], '::notice::Batch UI partial progress diagnostics: ' + json.dumps(
            {**EXPECTED, 'scope': 'partialFailureOnly', 'status': 'diagnosticUnavailable'}, sort_keys=True))
        self.assertNotIn(str(ROOT), '\n'.join(messages))

    def mobile_target_fixture(self, source_root, payload, bundle=BUNDLE, case=None, line=1, column=1, source=None):
        case = helper.CASES[0] if case is None else case
        source = helper.SOURCE if source is None else source
        position = str(line) + (':' + str(column) if column is not None else '')
        return str(source_root / source) + ':' + position + ': error: -[' + bundle + '.' + helper.CLASS + ' ' + case + '] : ' + payload

    def mobile_source_fixture(self, source_root, axes):
        source = source_root / helper.SOURCE
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text('\n'.join('XCTAssertGreaterThanOrEqual(element.frame.' + axis
                                  + ', 44, "Batch UI mobile target: ' + axis + ' \\(target)")' for axis in axes) + '\n')
        return source

    def test_mobile_target_diagnostics_accept_only_owned_actual_44pt_source_and_finite_controls(self):
        controls = ('captureOpen', 'captureSave', 'captureClose', 'librarySelectToggle', 'librarySelectAll',
                    'libraryBatchPlan', 'planToday', 'planTomorrow', 'planCancel', 'destinationToday',
                    'destinationCalendar', 'destinationLibrary', 'taskSelection', 'other')
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary).resolve()
            self.mobile_source_fixture(source_root, ('width', 'height'))
            for bundle in ('MirrorIOSBatchUITests', 'MirrorMacBatchUITests'):
                for case in helper.CASES:
                    for line, axis in enumerate(('width', 'height'), 1):
                        for control in controls:
                            with self.subTest(bundle=bundle, case=case, axis=axis, control=control):
                                payload = 'XCTAssertGreaterThanOrEqual failed: (37.125) < (44.0) - Batch UI mobile target: ' + axis + ' ' + control
                                value = self.mobile_target_fixture(source_root, payload, bundle=bundle, case=case, line=line)
                                reports = helper.mobile_target_failure_locations(value, bundle, source_root)
                                self.assertEqual(reports, [{'scope': 'stdoutOnly', 'method': case, 'sourceFile': helper.SOURCE,
                                                            'line': line, 'column': 1, 'axis': axis, 'targetControl': control}])
                                self.assertNotIn('37.125', json.dumps(reports))
                                self.assertNotIn(str(source_root), json.dumps(reports))
            payload = 'XCTAssertGreaterThanOrEqual failed - Batch UI mobile target: width captureOpen'
            value = self.mobile_target_fixture(source_root, payload, column=None)
            self.assertNotIn('column', helper.mobile_target_failure_locations(value, BUNDLE, source_root)[0])

    def test_mobile_target_diagnostics_reject_wrong_source_predicates_ownership_bounds_and_private_codes(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary).resolve()
            source = self.mobile_source_fixture(source_root, ('width', 'height'))
            payload = 'XCTAssertGreaterThanOrEqual failed: SYNTHETIC_PRIVATE_VALUE - Batch UI mobile target: width captureOpen'
            valid = self.mobile_target_fixture(source_root, payload)
            invalid = (
                self.mobile_target_fixture(source_root, payload, bundle='OtherUITests'),
                self.mobile_target_fixture(source_root, payload, bundle='MirrorMacBatchUITests'),
                self.mobile_target_fixture(source_root, payload, case='testUnexpected'),
                valid.replace('.' + helper.CLASS + ' ', '.OtherTests '),
                self.mobile_target_fixture(source_root, payload, source='Tests/Other.swift'),
                self.mobile_target_fixture(source_root, payload, source='../' + helper.SOURCE),
                self.mobile_target_fixture(source_root, payload, line=0),
                self.mobile_target_fixture(source_root, payload, line=3),
                self.mobile_target_fixture(source_root, payload, column=0),
                self.mobile_target_fixture(source_root, payload, column=99999),
                self.mobile_target_fixture(source_root, payload, line=2),
                valid.replace('XCTAssertGreaterThanOrEqual failed', 'XCTAssertEqual failed'),
                valid.replace('captureOpen', 'SYNTHETIC_PRIVATE_VALUE'),
                valid.replace('captureOpen', 'task.select.11111111-2222-3333-4444-555555555555'),
                valid + ' SYNTHETIC_PRIVATE_VALUE',
                valid.replace('width captureOpen', 'diagonal captureOpen'),
                valid.replace('Batch UI mobile target:', 'Other marker:'),
            )
            for value in invalid:
                self.assertEqual(helper.mobile_target_failure_locations(value, BUNDLE, source_root), [])
            original = source.read_text()
            for changed in (original.replace(', 44,', ', 43,'), original.replace('XCTAssertGreaterThanOrEqual(', 'XCTAssertEqual('),
                            original.replace('element.frame.width', 'element.frame.height'), original.replace('\\(target)', 'private')):
                source.write_text(changed)
                self.assertEqual(helper.mobile_target_failure_locations(valid, BUNDLE, source_root), [])
            source.write_text(original)
            with mock.patch.object(helper.SUPPORT, 'read_regular', side_effect=OSError('SYNTHETIC_PRIVATE_VALUE')):
                self.assertEqual(helper.mobile_target_failure_locations(valid, BUNDLE, source_root), [])
            source.unlink()
            source.symlink_to(ROOT / helper.SOURCE)
            self.assertEqual(helper.mobile_target_failure_locations(valid, BUNDLE, source_root), [])

    def mobile_measurement_source_fixture(self, source_root):
        source = source_root / helper.SOURCE
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text('\n'.join((
            '    private func assertMobileTarget(_ element: XCUIElement) throws {',
            '        let target = mobileTargetControl(element)',
            '        let width = element.frame.width',
            '        recordMobileTargetFailure(width, axis: "width", target: target, callerLine: #line + 1)',
            '        XCTAssertGreaterThanOrEqual(width, 44, "Batch UI mobile target: width \\(target)")',
            '        let height = element.frame.height',
            '        recordMobileTargetFailure(height, axis: "height", target: target, callerLine: #line + 1)',
            '        XCTAssertGreaterThanOrEqual(height, 44, "Batch UI mobile target: height \\(target)")',
            '    }',
        )))
        return source

    def mobile_measurement_log_fixture(self, source_root, case=None, axis='width', column=1, **changes):
        case = helper.CASES[0] if case is None else case
        caller_line = 5 if axis == 'width' else 8
        value = {'schemaVersion': 1, 'method': case, 'progressSequence': 2,
                 'callerLine': caller_line, 'axis': axis, 'targetControl': 'captureOpen',
                 'actual': 37.125, 'required': 44, **changes}
        assertion = self.mobile_target_fixture(source_root,
            'XCTAssertGreaterThanOrEqual failed: SYNTHETIC_PRIVATE_VALUE /private/synthetic/title'
            ' - Batch UI mobile target: ' + axis + ' captureOpen', case=case,
            line=value['callerLine'], column=column)
        return ([event(case, 'started')] + progress_lines(case, 2)
                + ['Batch UI mobile measurement diagnostic: ' + json.dumps(value),
                   assertion, event(case, 'failed')])

    def test_mobile_measurements_bind_each_axis_to_failed_case_and_exact_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary).resolve()
            self.mobile_measurement_source_fixture(source_root)
            for case in helper.CASES:
                for axis, caller_line in (('width', 5), ('height', 8)):
                    for actual in (0, 37.125, 43.999):
                        with self.subTest(case=case, axis=axis, actual=actual):
                            lines = self.mobile_measurement_log_fixture(source_root, case, axis, actual=actual)
                            reports = helper.mobile_target_measurements('\n'.join(lines), BUNDLE, source_root)
                            self.assertEqual(reports, [{'scope': 'partialFailureOnly', 'method': case,
                                'sourceFile': helper.SOURCE, 'line': caller_line, 'column': 1,
                                'axis': axis, 'targetControl': 'captureOpen', 'actual': actual,
                                'required': 44, 'progressSequence': 2, 'terminal': 'failed'}])
                            for private in ('SYNTHETIC_PRIVATE_VALUE', '/private/synthetic/title', str(source_root)):
                                self.assertNotIn(private, json.dumps(reports))
                            with self.assertRaises(helper.BatchError):
                                helper.validate_outcome({**EXPECTED, **reports[0]}, EXPECTED)
            combined = sum((self.mobile_measurement_log_fixture(source_root, case) for case in helper.CASES), [])
            self.assertEqual([item['method'] for item in helper.mobile_target_measurements(
                '\n'.join(combined), BUNDLE, source_root)], list(helper.CASES))
            lines = self.mobile_measurement_log_fixture(source_root, column=None)
            self.assertNotIn('column', helper.mobile_target_measurements('\n'.join(lines), BUNDLE, source_root)[0])

    def test_mobile_measurements_reject_nonfinite_nonfailure_and_private_json(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary).resolve()
            self.mobile_measurement_source_fixture(source_root)
            changes = [{'actual': value} for value in
                       (True, False, -1, 44, 44.001, 10 ** 400, float('nan'), float('inf'), -float('inf'),
                        '37.125', None, [], {}, 'SYNTHETIC_PRIVATE_VALUE')]
            changes += [{'required': value} for value in (True, 43, 44.0, '44', None)]
            changes += [{'schemaVersion': value} for value in (True, 0, 2, '1')]
            changes += [{'progressSequence': value} for value in (True, 0, 1, 3, 97, '2')]
            changes += [{'callerLine': value} for value in (True, 0, 4, 100001, '5')]
            changes += [{'axis': value} for value in ('height', 'diagonal', [], None)]
            changes += [{'targetControl': value} for value in ('captureSave', 'task.select.private', [], None)]
            changes += [{'method': helper.CASES[1]}, {'method': 'testUnexpected'},
                        {'extra': 'SYNTHETIC_PRIVATE_VALUE'}]
            for change in changes:
                with self.subTest(change=change):
                    lines = self.mobile_measurement_log_fixture(source_root)
                    marker_prefix = 'Batch UI mobile measurement diagnostic: '
                    fields = json.loads(lines[-3][len(marker_prefix):])
                    lines[-3] = marker_prefix + json.dumps({**fields, **change})
                    self.assertEqual(helper.mobile_target_measurements('\n'.join(lines), BUNDLE, source_root), [])
            lines = self.mobile_measurement_log_fixture(source_root)
            marker = lines[-3]
            for malformed in (marker[:-1], marker.replace('"actual": 37.125', '"actual": 37.125, "actual": 37.125'),
                              marker.replace('"actual": 37.125, ', ''),
                              'Batch UI mobile measurement diagnostic: []',
                              'Batch UI mobile measurement diagnostic: {}',
                              'SDK error: ' + marker, 'title="' + marker + '"', marker + ' SYNTHETIC_PRIVATE_VALUE'):
                self.assertEqual(helper.mobile_target_measurements(
                    '\n'.join(lines[:-3] + [malformed] + lines[-2:]), BUNDLE, source_root), [])
            padded = lines[:-3] + [marker.ljust(511)] + lines[-2:]
            self.assertEqual(len(helper.mobile_target_measurements('\n'.join(padded), BUNDLE, source_root)), 1)
            for malformed in (marker.ljust(512), marker + ' ' * 512, marker + '한' * 200):
                self.assertEqual(helper.mobile_target_measurements(
                    '\n'.join(lines[:-3] + [malformed] + lines[-2:]), BUNDLE, source_root), [])

    def test_mobile_measurements_reject_wrong_call_source_axis_control_and_assertion(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary).resolve()
            source = self.mobile_measurement_source_fixture(source_root)
            lines = self.mobile_measurement_log_fixture(source_root)
            assertion = lines[-2]
            for changed in (assertion.replace(helper.SOURCE, 'Tests/Other.swift'),
                            assertion.replace(helper.SOURCE, '../' + helper.SOURCE),
                            assertion.replace(':5:1:', ':8:1:'), assertion.replace(':5:1:', ':5:0:'),
                            assertion.replace('width captureOpen', 'height captureOpen'),
                            assertion.replace('width captureOpen', 'width captureSave'),
                            assertion.replace('XCTAssertGreaterThanOrEqual failed', 'XCTAssertEqual failed'),
                            assertion.replace(BUNDLE, 'OtherUITests'),
                            assertion.replace(helper.CASES[0], helper.CASES[1]),
                            assertion + ' SYNTHETIC_PRIVATE_VALUE'):
                with self.subTest(assertion=changed):
                    self.assertEqual(helper.mobile_target_measurements(
                        '\n'.join(lines[:-2] + [changed, lines[-1]]), BUNDLE, source_root), [])
            original = source.read_text()
            mutations = (original.replace('let width = element.frame.width', 'let width = element.frame.height'),
                         original.replace('callerLine: #line + 1', 'callerLine: #line + 2'),
                         original.replace('recordMobileTargetFailure(width, axis: "width"',
                                          'recordMobileTargetFailure(width, axis: "height"'),
                         original.replace('target: target', 'target: "private"'),
                         original.replace('XCTAssertGreaterThanOrEqual(width, 44,', 'XCTAssertGreaterThanOrEqual(width, 43,'),
                         original.replace('let width = element.frame.width\n',
                                          'let width = element.frame.width\n        // non-adjacent call\n'),
                         original.replace('private func assertMobileTarget(', 'private func unrelated('),
                         original + '\n' + original,
                         original.replace('        let height = element.frame.height',
                                          '\n'.join(original.splitlines()[2:5]) + '\n        let height = element.frame.height'))
            for changed in mutations:
                source.write_text(changed)
                self.assertEqual(helper.mobile_target_measurements('\n'.join(lines), BUNDLE, source_root), [])
            source.write_text(original)
            with mock.patch.object(helper.SUPPORT, 'read_regular', side_effect=OSError('SYNTHETIC_PRIVATE_VALUE')):
                self.assertEqual(helper.mobile_target_measurements('\n'.join(lines), BUNDLE, source_root), [])
            source.unlink()
            source.symlink_to(ROOT / helper.SOURCE)
            self.assertEqual(helper.mobile_target_measurements('\n'.join(lines), BUNDLE, source_root), [])

    def test_mobile_measurements_require_one_observation_before_one_assertion_and_failed_terminal(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary).resolve()
            self.mobile_measurement_source_fixture(source_root)
            lines = self.mobile_measurement_log_fixture(source_root)
            before, marker, assertion, terminal = lines[:-3], *lines[-3:]
            invalid = ([marker, assertion, terminal], before + [marker, terminal], before + [assertion, terminal],
                       before + [marker, assertion], before + [marker, assertion, terminal.replace('failed', 'skipped')],
                       before + [marker, assertion, terminal.replace('failed', 'passed')],
                       before + [marker, marker, assertion, terminal], before + [marker, assertion, assertion, terminal],
                       before + [assertion, marker, assertion, terminal],
                       before + [marker, assertion, terminal, assertion],
                       before + [assertion, marker, terminal], before + [marker, terminal, assertion],
                       before + [marker, assertion, terminal, marker],
                       before + [marker, progress_lines(helper.CASES[0], 3)[-1], assertion, terminal],
                       before + [marker, assertion, progress_lines(helper.CASES[0], 3)[-1], terminal],
                       [before[0], event(helper.CASES[1], 'started')] + lines[1:],
                       before + [marker, assertion, terminal.replace(helper.CASES[0], helper.CASES[1])],
                       [before[0], before[2], marker, assertion, terminal],
                       [before[0], marker, assertion, terminal])
            for wrong in invalid:
                self.assertEqual(helper.mobile_target_measurements('\n'.join(wrong), BUNDLE, source_root), [])
            complete = progress_lines(helper.CASES[0])
            passed_marker = marker.replace('"progressSequence": 2', '"progressSequence": ' + str(len(complete)))
            passed = [before[0]] + complete + [passed_marker, assertion, terminal.replace('failed', 'passed')]
            self.assertEqual(helper.partial_progress('\n'.join(passed), BUNDLE)['status'], 'partial')
            self.assertEqual(helper.mobile_target_measurements('\n'.join(passed), BUNDLE, source_root), [])
            value = '\n'.join(lines)
            for bundle in ('MirrorMacBatchUITests', 'OtherUITests'):
                self.assertEqual(helper.mobile_target_measurements(value, bundle, source_root), [])
                self.assertEqual(helper.mobile_target_measurements(value.replace(BUNDLE, bundle), bundle, source_root), [])
            for wrong in ('', None):
                self.assertEqual(helper.mobile_target_measurements(wrong, BUNDLE, source_root), [])
            with mock.patch.object(helper, 'MAX_LOG', 8):
                self.assertEqual(helper.mobile_target_measurements(value, BUNDLE, source_root), [])

    def test_mobile_measurement_notice_is_opt_in_merges_only_matching_location_and_cannot_publish_success(self):
        source = (ROOT / helper.SOURCE).read_text().splitlines()
        caller_line = next(index for index, text in enumerate(source, 1)
                           if text.strip() == 'XCTAssertGreaterThanOrEqual(width, 44, "Batch UI mobile target: width \\(target)")')
        lines = self.mobile_measurement_log_fixture(ROOT, callerLine=caller_line)
        unmeasured = self.mobile_measurement_log_fixture(ROOT, helper.CASES[1], callerLine=caller_line)
        lines += unmeasured[:-3] + unmeasured[-2:]
        value = '\n'.join(lines)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            (directory / 'test.log').write_text(value)
            output_path, summary_path = directory / 'github-output', directory / 'github-summary'
            output_path.write_text('previous=value\n')
            summary_path.write_text('previous summary\n')
            for enabled in (False, True):
                with mock.patch.object(helper, 'context_for', return_value={'bundle': BUNDLE}), \
                        mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path),
                                                           'GITHUB_STEP_SUMMARY': str(summary_path)}), \
                        mock.patch.object(helper.SUPPORT, 'write_json') as write, mock.patch('builtins.print') as printed:
                    helper.diagnostics(directory, EXPECTED, 'test', partial_failure=enabled)
                messages = [call.args[0] for call in printed.call_args_list]
                prefix = '::notice::Batch UI mobile target diagnostics: '
                notices = [message for message in messages if message.startswith(prefix)]
                self.assertEqual(len(notices), 1)
                original = helper.mobile_target_failure_locations(value, BUNDLE)
                expected_location = {**original[0], **({'actual': 37.125, 'required': 44, 'progressSequence': 2,
                                                      'measurementScope': 'partialFailureOnly'} if enabled else {})}
                self.assertEqual(json.loads(notices[0][len(prefix):]),
                                 {**EXPECTED, 'phase': 'test', 'scope': 'stdoutOnly',
                                  'locations': [expected_location, original[1]], 'locationCount': 2})
                self.assertEqual(messages[0], '::notice::Batch UI source diagnostics: ' + json.dumps(
                    {**EXPECTED, 'phase': 'test', 'scope': 'stdoutOnly',
                     'locations': helper.failure_locations(value, BUNDLE)}, sort_keys=True))
                self.assertEqual(messages[1], '::notice::Batch UI query failure diagnostics: ' + json.dumps(
                    {**EXPECTED, 'phase': 'test', 'scope': 'stdoutOnly', 'locations': [], 'locationCount': 0}, sort_keys=True))
                write.assert_not_called()
                self.assertEqual(output_path.read_text(), 'previous=value\n')
                self.assertEqual(summary_path.read_text(), 'previous summary\n')
                self.assertFalse((directory / 'safe-outcome.json').exists())
                for private in ('SYNTHETIC_PRIVATE_VALUE', '/private/synthetic/title', str(ROOT)):
                    self.assertNotIn(private, '\n'.join(messages))
            with self.assertRaises(helper.BatchError):
                helper.validate_log(value, BUNDLE)
            malformed = value.replace('"actual": 37.125', '"actual": "SYNTHETIC_PRIVATE_VALUE"')
            (directory / 'test.log').write_text(malformed)
            with mock.patch.object(helper, 'context_for', return_value={'bundle': BUNDLE}), mock.patch('builtins.print') as printed:
                helper.diagnostics(directory, EXPECTED, 'test', partial_failure=True)
            notices = [call.args[0] for call in printed.call_args_list if call.args[0].startswith(prefix)]
            self.assertEqual(json.loads(notices[0][len(prefix):])['locations'],
                             helper.mobile_target_failure_locations(malformed, BUNDLE))
            self.assertNotIn('SYNTHETIC_PRIVATE_VALUE', '\n'.join(call.args[0] for call in printed.call_args_list))

    def test_partial_progress_keeps_interrupted_capture_ordinal_without_claiming_a_pass(self):
        for bundle in ('MirrorIOSBatchUITests', 'MirrorMacBatchUITests'):
            for case, capture_count in zip(helper.CASES, (3, 20)):
                lines = [event(case, 'started', bundle)] + progress_lines(case, 2 + capture_count * 3)
                expected = {'status': 'partial', 'cases': [{'method': case, 'terminal': 'notObserved',
                    'lastProgress': {'phase': 'captureSaved', 'sequence': 2 + capture_count * 3,
                                     'captureOrdinal': capture_count}}]}
                self.assertEqual(helper.partial_progress('\n'.join(lines), bundle), expected)
                self.assertNotIn('passedTests', expected)
                for terminal in ('failed', 'skipped'):
                    ended = event(case, terminal, bundle).replace(terminal + '.', terminal + ' (1.250 seconds).')
                    report = helper.partial_progress('\n'.join(lines + [ended]), bundle)
                    self.assertEqual(report['cases'][0]['terminal'], terminal)

    def test_partial_progress_rejects_wrong_sequence_phase_shape_and_case_specific_ordinal(self):
        for case, capture_count in zip(helper.CASES, (3, 20)):
            prefix = [event(case, 'started')] + progress_lines(case, 2)
            valid = {'method': case, 'phase': 'captureStarted', 'sequence': 3, 'captureOrdinal': 1}
            for change in ({'phase': 'captureSaved'}, {'phase': 'unknown'}, {'sequence': 2}, {'sequence': 4},
                           {'sequence': True}, {'captureOrdinal': True}, {'captureOrdinal': 0},
                           {'captureOrdinal': capture_count + 1}, {'method': 'testUnexpected'},
                           {'extra': 'SYNTHETIC_PRIVATE_VALUE'}):
                value = helper.PROGRESS_MARKER + json.dumps({**valid, **change})
                with self.subTest(change=change):
                    self.assertEqual(helper.partial_progress('\n'.join(prefix + [value]), BUNDLE),
                                     {'status': 'diagnosticUnavailable'})
            value = helper.PROGRESS_MARKER + json.dumps(valid)
            for malformed in (value[:-1], value.replace('"sequence": 3', '"sequence": 3, "sequence": 3'),
                              value.replace('"sequence": 3', '"sequence": NaN'),
                              helper.PROGRESS_MARKER + '[]', helper.PROGRESS_MARKER + '{}', 'title="' + value + '"'):
                self.assertEqual(helper.partial_progress('\n'.join(prefix + [malformed]), BUNDLE),
                                 {'status': 'diagnosticUnavailable'})
            self.assertEqual(helper.partial_progress('\n'.join(prefix + [value, value]), BUNDLE),
                             {'status': 'diagnosticUnavailable'})

    def test_partial_progress_requires_unambiguous_active_case_and_rejects_embedded_events(self):
        first, second = helper.CASES
        started = event(first, 'started')
        marker = progress_lines(first, 1)[0]
        for lines in ([marker], [started, event(first, 'failed'), marker],
                      [event(first, 'started', 'OtherUITests'), marker],
                      [event('testUnexpected', 'started'), marker],
                      [started, event(second, 'started'), marker],
                      [started, event(second, 'failed')], [started, started],
                      [started, event(first, 'failed'), started],
                      [started.replace('Test Case', 'Test  Case'), marker],
                      [started, 'title="' + started + '"'],
                      [started, 'SDK error: ' + marker],
                      [started, marker.replace(first, second)]):
            with self.subTest(lines=lines):
                self.assertEqual(helper.partial_progress('\n'.join(lines), BUNDLE),
                                 {'status': 'diagnosticUnavailable'})

    def test_partial_progress_records_complete_cases_but_cannot_replace_typed_acceptance(self):
        for case in helper.CASES:
            incomplete = [event(case, 'started')] + progress_lines(case, 1) + [event(case, 'passed')]
            self.assertEqual(helper.partial_progress('\n'.join(incomplete), BUNDLE),
                             {'status': 'diagnosticUnavailable'})
        for order in (helper.CASES, tuple(reversed(helper.CASES))):
            lines = []
            for case in order:
                lines += [event(case, 'started')] + progress_lines(case) + [event(case, 'passed')]
            report = helper.partial_progress('\n'.join(lines), BUNDLE)
            self.assertEqual(report['status'], 'partial')
            self.assertEqual([item['method'] for item in report['cases']], list(order))
            self.assertEqual([item['terminal'] for item in report['cases']], ['passed', 'passed'])
            with self.assertRaises(helper.BatchError):
                helper.validate_outcome({**EXPECTED, **report}, EXPECTED)
            self.assertEqual(helper.partial_progress('\n'.join(lines + [progress_lines(order[-1], 1)[0]]), BUNDLE),
                             {'status': 'diagnosticUnavailable'})

    def test_partial_progress_bounds_whole_log_and_single_write_without_echoing_payload(self):
        case = helper.CASES[0]
        prefix = event(case, 'started') + '\n'
        marker = progress_lines(case, 1)[0]
        self.assertEqual(helper.partial_progress(prefix + marker.ljust(511), BUNDLE)['status'], 'partial')
        for value in ('', None, prefix + marker.ljust(512), prefix + 'Batch UI progress: SYNTHETIC_PRIVATE_VALUE'):
            self.assertEqual(helper.partial_progress(value, BUNDLE), {'status': 'diagnosticUnavailable'})
        with mock.patch.object(helper, 'MAX_LOG', 8):
            self.assertEqual(helper.partial_progress(prefix + marker, BUNDLE), {'status': 'diagnosticUnavailable'})

    def test_partial_progress_notice_is_opt_in_and_does_not_write_outcome_or_actions_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            case = helper.CASES[0]
            (directory / 'test.log').write_text(event(case, 'started') + '\n' + progress_lines(case, 1)[0])
            output_path, summary_path = directory / 'github-output', directory / 'github-summary'
            output_path.write_text('previous=value\n')
            summary_path.write_text('previous summary\n')
            for enabled in (False, True):
                with mock.patch.object(helper, 'context_for', return_value={'bundle': BUNDLE}), \
                        mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path),
                                                           'GITHUB_STEP_SUMMARY': str(summary_path)}), \
                        mock.patch.object(helper.SUPPORT, 'write_json') as write, mock.patch('builtins.print') as printed:
                    helper.diagnostics(directory, EXPECTED, 'test', partial_failure=enabled)
                messages = [call.args[0] for call in printed.call_args_list]
                self.assertEqual(len(messages), 3 if enabled else 2)
                write.assert_not_called()
                self.assertFalse((directory / 'safe-outcome.json').exists())
                self.assertEqual(output_path.read_text(), 'previous=value\n')
                self.assertEqual(summary_path.read_text(), 'previous summary\n')
                if enabled:
                    report = json.loads(messages[-1].split(': ', 1)[1])
                    self.assertEqual(report, {**EXPECTED, 'scope': 'partialFailureOnly', 'status': 'partial',
                        'cases': [{'method': case, 'terminal': 'notObserved',
                                   'lastProgress': {'phase': 'started', 'sequence': 1, 'captureOrdinal': 0}}]})

    def disclosure_source_fixture(self, source_root):
        source = source_root / helper.SOURCE
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text('\n'.join((
            '    private func verifyPicker(_ selected: [OriginalTask], in app: XCUIApplication) throws {',
            '        progress(.pickerStarted)',
            '        let initialState = plannerDisclosureState(disclosure)',
            '        recordPlannerDisclosureFailureIfNeeded(disclosure, initialState: initialState, callerLine: #line + 1)',
            '        XCTAssertEqual(initialState, "접힘", "여러 제목을 처음에는 접어 빠른 날짜를 먼저 보여 준다.")',
            '        try waitPlannerDisclosureState("펼쳐짐", element: disclosure)',
            '        try waitPlannerDisclosureState("접힘", element: folded)',
            '    }',
        )))
        return 5

    def disclosure_log_fixture(self, source_root, case=None, stage=None, **changes):
        case = helper.CASES[0] if case is None else case
        sequence = 19 if case == helper.CASES[0] else 70
        value = {'schemaVersion': 1, 'method': case, 'phase': 'pickerStarted',
                 'progressSequence': sequence, 'callerLine': 5, 'target': 'planDisclosure',
                 'observationTiming': 'afterMismatch', 'role': 'disclosureTriangle',
                 'valueKind': 'string', 'valueState': 'other'}
        if stage is not None:
            value.update({'schemaVersion': 2, 'callerLine': 6 if stage == 'expanded' else 7,
                          'expectedState': stage, 'observationTiming': 'afterWaitFailure'})
        value.update(changes)
        payload = ('XCTAssertEqual failed: SYNTHETIC_PRIVATE_VALUE /private/synthetic/title' if stage is None
                   else 'failed - batchExpectedUIStateDidNotCompleteWithin15Seconds')
        assertion = self.query_failure_fixture(
            payload, bundle='MirrorMacBatchUITests', case=case,
            line=5 if stage is None else value['callerLine'], column=1, source_root=source_root)
        return ([event(case, 'started', 'MirrorMacBatchUITests')] + progress_lines(case, sequence)
                + [helper.DISCLOSURE_MARKER + json.dumps(value), assertion,
                   event(case, 'failed', 'MirrorMacBatchUITests')])

    def test_disclosure_failure_diagnostics_bind_after_mismatch_to_owned_failed_picker(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary).resolve()
            self.disclosure_source_fixture(source_root)
            states = [('string', state) for state in ('folded', 'expanded', 'empty', 'placeholder', 'other')]
            states += [('number', state) for state in ('binaryZero', 'binaryOne', 'other')]
            states += [('nil', 'other'), ('other', 'other')]
            for case in helper.CASES:
                for index, (kind, state) in enumerate(states):
                    role = ('disclosureTriangle', 'button', 'other')[index % 3]
                    lines = self.disclosure_log_fixture(source_root, case, role=role, valueKind=kind, valueState=state)
                    with self.subTest(case=case, kind=kind, state=state):
                        reports = helper.disclosure_failure_diagnostics('\n'.join(lines), 'MirrorMacBatchUITests', source_root)
                        self.assertEqual(len(reports), 1)
                        self.assertEqual(reports[0], {'scope': 'partialFailureOnly', 'schemaVersion': 1,
                            'method': case, 'phase': 'pickerStarted', 'progressSequence': 19 if case == helper.CASES[0] else 70,
                            'callerLine': 5, 'target': 'planDisclosure', 'observationTiming': 'afterMismatch',
                            'role': role, 'valueKind': kind, 'valueState': state,
                            'sourceFile': helper.SOURCE, 'line': 5, 'column': 1, 'terminal': 'failed'})
                        self.assertNotIn('SYNTHETIC_PRIVATE_VALUE', json.dumps(reports))
                        self.assertNotIn('/private/synthetic/title', json.dumps(reports))
                        self.assertNotIn(str(source_root), json.dumps(reports))
                        with self.assertRaises(helper.BatchError):
                            helper.validate_outcome({**EXPECTED, **reports[0]}, EXPECTED)

    def test_disclosure_failure_diagnostics_reject_unknown_fields_types_and_incompatible_states(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary).resolve()
            self.disclosure_source_fixture(source_root)
            changes = ({'schemaVersion': True}, {'schemaVersion': 2}, {'method': 'testUnexpected'},
                       {'phase': 'pickerVerified'}, {'progressSequence': True}, {'progressSequence': 18},
                       {'progressSequence': 97}, {'callerLine': True}, {'callerLine': 0}, {'callerLine': 100001},
                       {'target': 'SYNTHETIC_PRIVATE_TITLE'}, {'observationTiming': 'beforeMismatch'},
                       {'role': 'SYNTHETIC_PRIVATE_ROLE'}, {'role': []}, {'valueKind': []},
                       {'valueKind': 'SYNTHETIC_PRIVATE_KIND'}, {'valueState': 'SYNTHETIC_PRIVATE_VALUE'},
                       {'valueKind': 'nil', 'valueState': 'empty'}, {'valueKind': 'other', 'valueState': 'folded'},
                       {'valueKind': 'number', 'valueState': 'folded'}, {'valueState': 'binaryZero'},
                       {'valueState': []}, {'extra': 'SYNTHETIC_PRIVATE_VALUE'})
            for change in changes:
                with self.subTest(change=change):
                    value = '\n'.join(self.disclosure_log_fixture(source_root, **change))
                    self.assertEqual(helper.disclosure_failure_diagnostics(value, 'MirrorMacBatchUITests', source_root), [])
            lines = self.disclosure_log_fixture(source_root)
            marker = lines[-3]
            malformed = (marker[:-1], marker.replace('"schemaVersion": 1', '"schemaVersion": 1, "schemaVersion": 1'),
                         marker.replace('"schemaVersion": 1', '"schemaVersion": NaN'), marker.ljust(768),
                         helper.DISCLOSURE_MARKER + '[]', helper.DISCLOSURE_MARKER + '{}',
                         'SDK error: ' + marker, 'title="' + marker + '"')
            for invalid in malformed:
                with self.subTest(marker=invalid):
                    value = '\n'.join(lines[:-3] + [invalid] + lines[-2:])
                    self.assertEqual(helper.disclosure_failure_diagnostics(value, 'MirrorMacBatchUITests', source_root), [])
            lines[-3] = marker.ljust(767)
            self.assertEqual(len(helper.disclosure_failure_diagnostics('\n'.join(lines), 'MirrorMacBatchUITests', source_root)), 1)

    def test_disclosure_failure_diagnostics_reject_wrong_source_call_and_assertion(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary).resolve()
            self.disclosure_source_fixture(source_root)
            lines = self.disclosure_log_fixture(source_root)
            source_path = source_root / helper.SOURCE
            original = source_path.read_text()
            for changed in (original.replace('verifyPicker(', 'anotherPicker('),
                            original.replace('progress(.pickerStarted)', 'progress(.pickerVerified)'),
                            original.replace('let initialState = plannerDisclosureState(disclosure)',
                                             'let initialState = plannerDisclosureState(other)'),
                            original.replace('let initialState = plannerDisclosureState(disclosure)',
                                             'let initialState = textValue(disclosure)'),
                            original.replace('initialState: initialState', 'initialState: other'),
                            original.replace('callerLine: #line + 1', 'callerLine: 5'),
                            original.replace('XCTAssertEqual(initialState, "접힘"', 'XCTAssertEqual(initialState, "펼쳐짐"'),
                            original + '\n' + original):
                source_path.write_text(changed)
                self.assertEqual(helper.disclosure_failure_diagnostics('\n'.join(lines), 'MirrorMacBatchUITests', source_root), [])
            source_path.write_text(original)
            assertion = lines[-2]
            for invalid in (assertion.replace(':5:1:', ':4:1:'), assertion.replace(':5:1:', ':7:1:'),
                            assertion.replace(':5:1:', ':5:99999:'), assertion.replace('XCTAssertEqual', 'XCTAssertTrue'),
                            assertion.replace(helper.SOURCE, 'Tests/Other.swift'),
                            assertion.replace(str(source_root), '/private/foreign'),
                            assertion.replace('MirrorMacBatchUITests', 'MirrorIOSBatchUITests'),
                            assertion.replace(helper.CASES[0], helper.CASES[1])):
                value = '\n'.join(lines[:-2] + [invalid, lines[-1]])
                self.assertEqual(helper.disclosure_failure_diagnostics(value, 'MirrorMacBatchUITests', source_root), [])
            with mock.patch.object(helper.SUPPORT, 'read_regular', side_effect=OSError('SYNTHETIC_PRIVATE_VALUE')):
                self.assertEqual(helper.disclosure_failure_diagnostics('\n'.join(lines), 'MirrorMacBatchUITests', source_root), [])

    def test_disclosure_failure_diagnostics_require_same_active_phase_and_failed_terminal(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary).resolve()
            self.disclosure_source_fixture(source_root)
            lines = self.disclosure_log_fixture(source_root)
            before, marker, assertion, terminal = lines[:-3], lines[-3], lines[-2], lines[-1]
            invalid = ([marker] + before + [assertion, terminal], before + [assertion, marker, terminal],
                       before + [assertion, terminal, marker], before + [marker, marker, assertion, terminal],
                       before + [marker, assertion, assertion, terminal], before + [marker, assertion],
                       before + [marker, terminal], before + [marker, assertion, terminal.replace('failed.', 'skipped.')],
                       before + [marker, assertion, terminal.replace('failed.', 'passed.')],
                       before[:-1] + [marker, assertion, terminal],
                       before + [marker, progress_lines(helper.CASES[0], 20)[-1], assertion, terminal],
                       [before[0], event(helper.CASES[1], 'started', 'MirrorMacBatchUITests')] + lines[1:],
                       before + [marker, assertion, terminal.replace(helper.CASES[0], helper.CASES[1])])
            for wrong in invalid:
                self.assertEqual(helper.disclosure_failure_diagnostics('\n'.join(wrong), 'MirrorMacBatchUITests', source_root), [])
            value = '\n'.join(lines)
            self.assertEqual(helper.disclosure_failure_diagnostics(value, BUNDLE, source_root), [])
            self.assertEqual(helper.disclosure_failure_diagnostics(value.replace('MirrorMacBatchUITests', BUNDLE),
                                                                  'MirrorMacBatchUITests', source_root), [])
            with mock.patch.object(helper, 'MAX_LOG', 8):
                self.assertEqual(helper.disclosure_failure_diagnostics(value, 'MirrorMacBatchUITests', source_root), [])
            self.assertEqual(helper.disclosure_failure_diagnostics(None, 'MirrorMacBatchUITests', source_root), [])
            self.assertEqual(helper.disclosure_failure_diagnostics('\n'.join(before + [assertion, terminal]),
                                                                  'MirrorMacBatchUITests', source_root), [])

    def test_disclosure_failure_notice_is_mac_failure_only_and_preserves_existing_notices(self):
        native_source = (ROOT / helper.SOURCE).read_text().splitlines()
        actual_line = next(index for index, line in enumerate(native_source, 1)
                           if line.strip() == 'XCTAssertEqual(initialState, "접힘", "여러 제목을 처음에는 접어 빠른 날짜를 먼저 보여 준다.")')
        lines = self.disclosure_log_fixture(ROOT, callerLine=actual_line)
        lines[-2] = lines[-2].replace(':5:1:', ':' + str(actual_line) + ':1:')
        value = '\n'.join(lines)
        actual = helper.disclosure_failure_diagnostics(value, 'MirrorMacBatchUITests')
        self.assertEqual(len(actual), 1)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            (directory / 'test.log').write_text(value)
            output_path, summary_path = directory / 'github-output', directory / 'github-summary'
            output_path.write_text('previous=value\n')
            summary_path.write_text('previous summary\n')
            for platform, enabled in (('macos', True), ('macos', False), ('ipad', True)):
                expected = {**EXPECTED, 'platform': platform}
                with mock.patch.object(helper, 'context_for', return_value={'bundle': 'MirrorMacBatchUITests'}), \
                        mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path),
                                                           'GITHUB_STEP_SUMMARY': str(summary_path)}), \
                        mock.patch.object(helper.SUPPORT, 'write_json') as write, mock.patch('builtins.print') as printed:
                    helper.diagnostics(directory, expected, 'test', partial_failure=enabled)
                messages = [call.args[0] for call in printed.call_args_list]
                self.assertEqual(messages[0], '::notice::Batch UI source diagnostics: ' + json.dumps(
                    {**expected, 'phase': 'test', 'scope': 'stdoutOnly',
                     'locations': helper.failure_locations(value, 'MirrorMacBatchUITests')}, sort_keys=True))
                self.assertEqual(messages[1], '::notice::Batch UI query failure diagnostics: ' + json.dumps(
                    {**expected, 'phase': 'test', 'scope': 'stdoutOnly', 'locations': [], 'locationCount': 0}, sort_keys=True))
                notices = [message for message in messages if message.startswith('::notice::Batch UI disclosure failure diagnostics: ')]
                self.assertEqual(len(notices), int(platform == 'macos' and enabled))
                if notices:
                    self.assertEqual(json.loads(notices[0].split(': ', 1)[1]),
                                     {**expected, 'scope': 'partialFailureOnly', 'locations': actual, 'locationCount': 1})
                if enabled:
                    self.assertEqual(messages[2], '::notice::Batch UI partial progress diagnostics: ' + json.dumps(
                        {**expected, 'scope': 'partialFailureOnly', **helper.partial_progress(value, 'MirrorMacBatchUITests')}, sort_keys=True))
                write.assert_not_called()
                self.assertEqual(output_path.read_text(), 'previous=value\n')
                self.assertEqual(summary_path.read_text(), 'previous summary\n')
                self.assertFalse((directory / 'safe-outcome.json').exists())
                for private in ('SYNTHETIC_PRIVATE_VALUE', '/private/synthetic/title', str(ROOT)):
                    self.assertNotIn(private, '\n'.join(messages))

    def test_disclosure_wait_diagnostics_bind_each_expected_state_to_owned_failed_picker(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary).resolve()
            self.disclosure_source_fixture(source_root)
            for case in helper.CASES:
                for stage, line in (('expanded', 6), ('folded', 7)):
                    for kind, state in (('string', 'expanded'), ('string', 'folded'), ('number', 'binaryOne'),
                                        ('number', 'binaryZero'), ('nil', 'other')):
                        lines = self.disclosure_log_fixture(source_root, case, stage, valueKind=kind, valueState=state)
                        with self.subTest(case=case, stage=stage, kind=kind, state=state):
                            reports = helper.disclosure_failure_diagnostics('\n'.join(lines), 'MirrorMacBatchUITests', source_root)
                            observation = json.loads(lines[-3][len(helper.DISCLOSURE_MARKER):])
                            self.assertEqual(reports, [{'scope': 'partialFailureOnly', **observation,
                                'sourceFile': helper.SOURCE, 'line': line, 'column': 1, 'terminal': 'failed'}])
                            with self.assertRaises(helper.BatchError):
                                helper.validate_outcome({**EXPECTED, **reports[0]}, EXPECTED)
                            with self.assertRaises(helper.BatchError):
                                helper.validate_log('\n'.join(lines), 'MirrorMacBatchUITests')
                            self.assertNotIn(str(source_root), json.dumps(reports))

    def test_disclosure_wait_diagnostics_reject_schema_source_and_exact_failure_mismatches(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary).resolve()
            self.disclosure_source_fixture(source_root)
            lines = self.disclosure_log_fixture(source_root, stage='expanded')
            marker = lines[-3]
            fields = json.loads(marker[len(helper.DISCLOSURE_MARKER):])
            changes = ({'schemaVersion': True}, {'schemaVersion': 1}, {'schemaVersion': 3},
                       {'expectedState': 'folded'}, {'expectedState': []}, {'expectedState': 'SYNTHETIC_PRIVATE_VALUE'},
                       {'observationTiming': 'afterMismatch'}, {'callerLine': 5}, {'callerLine': True},
                       {'phase': 'pickerVerified'}, {'progressSequence': 18}, {'progressSequence': True},
                       {'method': helper.CASES[1]}, {'role': []}, {'valueKind': []},
                       {'valueKind': 'number', 'valueState': 'expanded'},
                       {'valueState': 'SYNTHETIC_PRIVATE_VALUE'}, {'extra': '/private/synthetic/title'})
            for change in changes:
                with self.subTest(change=change):
                    wrong = lines[:-3] + [helper.DISCLOSURE_MARKER + json.dumps({**fields, **change})] + lines[-2:]
                    self.assertEqual(helper.disclosure_failure_diagnostics('\n'.join(wrong), 'MirrorMacBatchUITests', source_root), [])
            for wrong_marker in (marker.replace('"expectedState": "expanded"', '"expectedState": "expanded", "expectedState": "expanded"'),
                                 helper.DISCLOSURE_MARKER + json.dumps({key: value for key, value in fields.items() if key != 'expectedState'}),
                                 marker.ljust(768), marker + '한' * 256, 'title="' + marker + '"'):
                self.assertEqual(helper.disclosure_failure_diagnostics(
                    '\n'.join(lines[:-3] + [wrong_marker] + lines[-2:]), 'MirrorMacBatchUITests', source_root), [])
            self.assertEqual(len(helper.disclosure_failure_diagnostics(
                '\n'.join(lines[:-3] + [marker.ljust(767)] + lines[-2:]), 'MirrorMacBatchUITests', source_root)), 1)
            assertion = lines[-2]
            for wrong in (assertion.replace('failed - ', 'XCTAssertEqual failed - '),
                          assertion.replace('15Seconds', '5Seconds'), assertion + ' SYNTHETIC_PRIVATE_VALUE',
                          assertion.replace(helper.SOURCE, 'Tests/Other.swift'), assertion.replace(':6:1:', ':7:1:'),
                          assertion.replace(helper.CASES[0], helper.CASES[1]),
                          assertion.replace('MirrorMacBatchUITests', BUNDLE)):
                self.assertEqual(helper.disclosure_failure_diagnostics(
                    '\n'.join(lines[:-2] + [wrong, lines[-1]]), 'MirrorMacBatchUITests', source_root), [])
            source_path = source_root / helper.SOURCE
            original = source_path.read_text()
            expanded = 'try waitPlannerDisclosureState("펼쳐짐", element: disclosure)'
            folded = 'try waitPlannerDisclosureState("접힘", element: folded)'
            for wrong in (original.replace(expanded, expanded.replace('disclosure)', 'folded)')),
                          original.replace(folded, folded.replace('folded)', 'disclosure)')),
                          original.replace(expanded, folded), original.replace(folded, ''),
                          original.replace(expanded, expanded + '\n        ' + expanded),
                          original.replace(expanded, '}' + '\n    private func anotherPicker() {\n        ' + expanded)):
                source_path.write_text(wrong)
                self.assertEqual(helper.disclosure_failure_diagnostics('\n'.join(lines), 'MirrorMacBatchUITests', source_root), [])

    def test_disclosure_wait_diagnostics_require_marker_assertion_order_and_failed_terminal(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary).resolve()
            self.disclosure_source_fixture(source_root)
            lines = self.disclosure_log_fixture(source_root, stage='folded')
            before, marker, assertion, terminal = lines[:-3], *lines[-3:]
            invalid = (before + [assertion, marker, terminal], before + [marker, marker, assertion, terminal],
                       before + [marker, assertion, assertion, terminal], before + [marker, terminal],
                       before + [assertion, marker, assertion, terminal],
                       before + [marker, assertion, terminal, assertion],
                       before + [marker, assertion], before + [marker, assertion, terminal.replace('failed.', 'passed.')],
                       before + [marker, assertion, terminal.replace('failed.', 'skipped.')],
                       before + [marker, progress_lines(helper.CASES[0], 20)[-1], assertion, terminal],
                       before + [marker, assertion, terminal.replace(helper.CASES[0], helper.CASES[1])],
                       [marker] + before + [assertion, terminal], before + [assertion, terminal, marker])
            for wrong in invalid:
                self.assertEqual(helper.disclosure_failure_diagnostics('\n'.join(wrong), 'MirrorMacBatchUITests', source_root), [])

    def test_disclosure_wait_notice_remains_optional_mac_failure_evidence(self):
        source = (ROOT / helper.SOURCE).read_text().splitlines()
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            for stage, expected_text in (('expanded', 'try waitPlannerDisclosureState("펼쳐짐", element: disclosure)'),
                                         ('folded', 'try waitPlannerDisclosureState("접힘", element: folded)')):
                line = next(index for index, text in enumerate(source, 1) if text.strip() == expected_text)
                value = '\n'.join(self.disclosure_log_fixture(ROOT, stage=stage, callerLine=line,
                                                              valueKind='number', valueState='binaryOne'))
                (directory / 'test.log').write_text(value)
                reports = helper.disclosure_failure_diagnostics(value, 'MirrorMacBatchUITests')
                self.assertEqual(len(reports), 1)
                for platform, enabled in (('macos', True), ('macos', False), ('ipad', True)):
                    expected = {**EXPECTED, 'platform': platform}
                    with mock.patch.object(helper, 'context_for', return_value={'bundle': 'MirrorMacBatchUITests'}), \
                            mock.patch.object(helper.SUPPORT, 'write_json') as write, mock.patch('builtins.print') as printed:
                        helper.diagnostics(directory, expected, 'test', partial_failure=enabled)
                    messages = [call.args[0] for call in printed.call_args_list]
                    prefix = '::notice::Batch UI disclosure failure diagnostics: '
                    notices = [message for message in messages if message.startswith(prefix)]
                    self.assertEqual(len(notices), int(platform == 'macos' and enabled))
                    if notices:
                        self.assertEqual(json.loads(notices[0][len(prefix):]),
                                         {**expected, 'scope': 'partialFailureOnly', 'locations': reports, 'locationCount': 1})
                    self.assertTrue(messages[0].startswith('::notice::Batch UI source diagnostics: '))
                    self.assertTrue(messages[1].startswith('::notice::Batch UI query failure diagnostics: '))
                    write.assert_not_called()
                    self.assertFalse((directory / 'safe-outcome.json').exists())
                    self.assertNotIn(str(ROOT), '\n'.join(messages))

    def planner_source_fixture(self, source_root):
        source = source_root / helper.SOURCE
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text('\n'.join((
            '    private func verifyPicker(_ selected: [OriginalTask], in app: XCUIApplication) throws {',
            '        progress(.pickerStarted)',
            '        for task in selected {',
            '            let title = try reachable(app.staticTexts.matching(identifier: "plan.task.\\(task.uuid)"), surface: .planner, target: .planTask, in: app)',
            '        }', '    }',
        )))
        return source

    def planner_log_fixture(self, source_root, case=None, column=1, **changes):
        case = helper.CASES[0] if case is None else case
        sequence = 19 if case == helper.CASES[0] else 70
        value = {'schemaVersion': 1, 'method': case, 'phase': 'pickerStarted', 'progressSequence': sequence,
                 'callerLine': 4, 'target': 'planTask', 'observationTiming': 'cachedLastIteration',
                 'iteration': 1, 'exists': True, 'role': 'staticText', 'targetFrame': [0, 90, 100, 20],
                 'ownerFrame': [0, 0, 100, 100], 'windowCount': 1, 'hittable': True, 'enabled': True,
                 'insideOwner': False, 'deadlineExceededAtLastGuard': True, 'swipePerformed': False, **changes}
        assertion = self.query_failure_fixture(
            'failed - batchTargetIsNotReachableWithin15SecondsAnd12Scrolls target=planTask',
            case=case, line=value['callerLine'], column=column, source_root=source_root)
        return ([event(case, 'started')] + progress_lines(case, sequence)
                + [helper.PLANNER_REACHABILITY_MARKER + json.dumps(value), assertion, event(case, 'failed')])

    def test_planner_reachability_keeps_cached_short_circuit_observations_and_zero_frames(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary).resolve()
            self.planner_source_fixture(source_root)
            unread = {'role': None, 'targetFrame': None, 'windowCount': None,
                      'hittable': None, 'enabled': None, 'insideOwner': None}
            unchecked = {'windowCount': None, 'hittable': None, 'enabled': None, 'insideOwner': None}
            changes = ({}, {'exists': False, **unread, 'ownerFrame': None},
                       {'targetFrame': [0, 0, 0, 0], **unchecked, 'ownerFrame': None},
                       {'targetFrame': [0, 0, 0, 20], **unchecked},
                       {'targetFrame': 'invalid', **unchecked},
                       {'windowCount': 0, 'hittable': None, 'enabled': None, 'insideOwner': None},
                       {'windowCount': 10_000, 'hittable': None, 'enabled': None, 'insideOwner': None},
                       {'hittable': False, 'enabled': None, 'insideOwner': None},
                       {'enabled': False, 'insideOwner': None}, {'role': 'button', 'targetFrame': 'invalid'},
                       {'role': 'other', 'targetFrame': [-100_000, 100_000, 100_000, 0],
                        **unchecked, 'ownerFrame': 'invalid'},
                       {'iteration': 12, 'deadlineExceededAtLastGuard': False, 'swipePerformed': True})
            for change in changes:
                with self.subTest(change=change):
                    lines = self.planner_log_fixture(source_root, **change)
                    reports = helper.planner_reachability_diagnostics('\n'.join(lines), BUNDLE, 'ipad', source_root)
                    fields = json.loads(lines[-3][len(helper.PLANNER_REACHABILITY_MARKER):])
                    self.assertEqual(reports, [{'scope': 'partialFailureOnly', **fields,
                        'sourceFile': helper.SOURCE, 'line': 4, 'column': 1, 'terminal': 'failed'}])
                    self.assertNotIn(str(source_root), json.dumps(reports))
                    with self.assertRaises(helper.BatchError):
                        helper.validate_outcome({**EXPECTED, **reports[0]}, EXPECTED)
            lines = self.planner_log_fixture(source_root, column=None, targetFrame=[0, 0, 0, 0], **unchecked)
            report = helper.planner_reachability_diagnostics('\n'.join(lines), BUNDLE, 'ipad', source_root)[0]
            self.assertNotIn('column', report)
            self.assertEqual(report['targetFrame'], [0, 0, 0, 0])
            with self.assertRaises(helper.BatchError):
                helper.validate_log('\n'.join(lines), BUNDLE)
            for sequence, (phase, _) in enumerate(helper.progress_steps(helper.CASES[0]), 1):
                if phase == 'pickerStarted':
                    tail = self.planner_log_fixture(source_root, progressSequence=sequence)[-3:]
                    current = [event(helper.CASES[0], 'started')] + progress_lines(helper.CASES[0], sequence) + tail
                    self.assertEqual(len(helper.planner_reachability_diagnostics(
                        '\n'.join(current), BUNDLE, 'ipad', source_root)), 1)

    def test_planner_reachability_rejects_short_circuit_contradictions_and_unsafe_fields(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary).resolve()
            self.planner_source_fixture(source_root)
            changes = [{'iteration': item} for item in (True, 0, 13, '1')]
            changes += [{'exists': item} for item in (1, None, False)]
            changes += [{'role': item} for item in (None, [], 'SYNTHETIC_PRIVATE_ROLE')]
            changes += [{'windowCount': item} for item in (True, -1, 10001, 1.0, None, 0, 2)]
            changes += [{'hittable': item} for item in (1, None, False)]
            changes += [{'enabled': item} for item in (1, None, False)]
            changes += [{'insideOwner': item} for item in (1, None, True)]
            changes += [{'deadlineExceededAtLastGuard': item} for item in (1, None, False)]
            changes += [{'swipePerformed': item} for item in (1, None, True)]
            changes += [{'iteration': 11, 'deadlineExceededAtLastGuard': False, 'swipePerformed': True},
                        {'targetFrame': [0, 0, 0, 20]}, {'targetFrame': [0, 0, 100, 0]},
                        {'windowCount': None, 'hittable': None, 'enabled': None, 'insideOwner': None},
                        {'ownerFrame': None},
                        {'exists': False, 'role': None, 'targetFrame': None, 'windowCount': None,
                         'hittable': None, 'enabled': None, 'insideOwner': None, 'ownerFrame': None,
                         'iteration': 12, 'deadlineExceededAtLastGuard': False, 'swipePerformed': True},
                        {'schemaVersion': True}, {'schemaVersion': 2}, {'method': helper.CASES[1]},
                        {'phase': 'pickerVerified'}, {'progressSequence': 18}, {'progressSequence': True},
                        {'callerLine': True}, {'callerLine': 100001}, {'target': 'other'},
                        {'observationTiming': 'freshQuery'}, {'extra': '/private/synthetic/title'}]
            invalid_frames = ('SYNTHETIC_PRIVATE_FRAME', [], [0, 0, 0], [0, 0, 0, 0, 0], [True, 0, 0, 0],
                              [100001, 0, 0, 0], [0, -100001, 0, 0], [0, 0, -1, 0], [0, 0, 0, -1],
                              [float('nan'), 0, 0, 0], [0, float('inf'), 0, 0], [10 ** 400, 0, 0, 0])
            changes += [{key: frame} for key in ('targetFrame', 'ownerFrame') for frame in invalid_frames]
            changes += [{'targetFrame': None}]
            lines = self.planner_log_fixture(source_root)
            fields = json.loads(lines[-3][len(helper.PLANNER_REACHABILITY_MARKER):])
            for change in changes:
                with self.subTest(change=change):
                    marker = helper.PLANNER_REACHABILITY_MARKER + json.dumps({**fields, **change})
                    self.assertEqual(helper.planner_reachability_diagnostics(
                        '\n'.join(lines[:-3] + [marker] + lines[-2:]), BUNDLE, 'ipad', source_root), [])
            absent = {**fields, 'exists': False, 'role': None, 'targetFrame': None, 'windowCount': None,
                      'hittable': None, 'enabled': None, 'insideOwner': None}
            for key in ('role', 'targetFrame', 'windowCount', 'hittable', 'enabled', 'insideOwner'):
                marker = helper.PLANNER_REACHABILITY_MARKER + json.dumps({**absent, key: fields[key]})
                self.assertEqual(helper.planner_reachability_diagnostics(
                    '\n'.join(lines[:-3] + [marker] + lines[-2:]), BUNDLE, 'ipad', source_root), [])

    def test_planner_reachability_requires_owned_source_case_sequence_and_exact_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary).resolve()
            source = self.planner_source_fixture(source_root)
            lines = self.planner_log_fixture(source_root)
            value = '\n'.join(lines)
            for platform in ('iphone', 'macos', None, 'SYNTHETIC_PRIVATE_PLATFORM'):
                self.assertEqual(helper.planner_reachability_diagnostics(value, BUNDLE, platform, source_root), [])
            for bundle in ('MirrorMacBatchUITests', 'OtherUITests'):
                self.assertEqual(helper.planner_reachability_diagnostics(value.replace(BUNDLE, bundle), bundle, 'ipad', source_root), [])
            other = self.planner_log_fixture(source_root, helper.CASES[1])
            self.assertEqual(helper.planner_reachability_diagnostics('\n'.join(other), BUNDLE, 'ipad', source_root), [])
            before, marker, assertion, terminal = lines[:-3], *lines[-3:]
            invalid = ([marker, assertion, terminal], before[:-1] + [marker, assertion, terminal],
                       before + [assertion, marker, terminal], before + [marker, marker, assertion, terminal],
                       before + [marker, assertion, assertion, terminal], before + [assertion, marker, assertion, terminal],
                       before + [marker, assertion, terminal, assertion], before + [marker, assertion],
                       before + [marker, terminal], before + [marker, assertion, terminal.replace('failed.', 'passed.')],
                       before + [marker, assertion, terminal.replace('failed.', 'skipped.')],
                       before + [marker, progress_lines(helper.CASES[0], 20)[-1], assertion, terminal],
                       before + [marker, assertion, progress_lines(helper.CASES[0], 20)[-1], terminal],
                       before + [marker, assertion, terminal.replace(helper.CASES[0], helper.CASES[1])],
                       before + [marker, assertion, terminal, marker])
            for wrong in invalid:
                self.assertEqual(helper.planner_reachability_diagnostics('\n'.join(wrong), BUNDLE, 'ipad', source_root), [])
            for wrong in (assertion.replace('failed - ', 'XCTAssertEqual failed - '),
                          assertion.replace('target=planTask', 'target=planToday'), assertion + ' SYNTHETIC_PRIVATE_VALUE',
                          assertion.replace(helper.SOURCE, 'Tests/Other.swift'), assertion.replace(':4:1:', ':3:1:'),
                          assertion.replace(':4:1:', ':4:0:'), assertion.replace(helper.CASES[0], helper.CASES[1]),
                          assertion.replace(BUNDLE, 'OtherUITests')):
                self.assertEqual(helper.planner_reachability_diagnostics(
                    '\n'.join(before + [marker, wrong, terminal]), BUNDLE, 'ipad', source_root), [])
            original = source.read_text()
            for wrong in (original.replace('verifyPicker(', 'otherPicker('), original + '\n' + original,
                          original.replace('progress(.pickerStarted)', 'progress(.pickerVerified)'),
                          original.replace('app.staticTexts', 'app.buttons'), original.replace('.planTask', '.planToday'),
                          original.replace('surface: .planner', 'surface: .library'),
                          original.replace('for task in selected {', '}\n    private func otherPicker() {')):
                source.write_text(wrong)
                self.assertEqual(helper.planner_reachability_diagnostics(value, BUNDLE, 'ipad', source_root), [])
            source.write_text(original)
            with mock.patch.object(helper.SUPPORT, 'read_regular', side_effect=OSError('SYNTHETIC_PRIVATE_VALUE')):
                self.assertEqual(helper.planner_reachability_diagnostics(value, BUNDLE, 'ipad', source_root), [])
            source.unlink()
            source.symlink_to(ROOT / helper.SOURCE)
            self.assertEqual(helper.planner_reachability_diagnostics(value, BUNDLE, 'ipad', source_root), [])

    def test_planner_reachability_rejects_malformed_or_oversized_private_markers(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary).resolve()
            self.planner_source_fixture(source_root)
            lines = self.planner_log_fixture(source_root)
            marker = lines[-3]
            fields = json.loads(marker[len(helper.PLANNER_REACHABILITY_MARKER):])
            malformed = (marker[:-1], marker.replace('"exists": true', '"exists": true, "exists": true'),
                         helper.PLANNER_REACHABILITY_MARKER + json.dumps({key: item for key, item in fields.items() if key != 'role'}),
                         helper.PLANNER_REACHABILITY_MARKER + '[]', 'SDK error: ' + marker, 'title="' + marker + '"',
                         marker.ljust(1024), marker + '한' * 350, marker + ' SYNTHETIC_PRIVATE_VALUE')
            for wrong in malformed:
                self.assertEqual(helper.planner_reachability_diagnostics(
                    '\n'.join(lines[:-3] + [wrong] + lines[-2:]), BUNDLE, 'ipad', source_root), [])
            self.assertEqual(len(helper.planner_reachability_diagnostics(
                '\n'.join(lines[:-3] + [marker.ljust(1023)] + lines[-2:]), BUNDLE, 'ipad', source_root)), 1)
            for wrong in ('', None):
                self.assertEqual(helper.planner_reachability_diagnostics(wrong, BUNDLE, 'ipad', source_root), [])
            with mock.patch.object(helper, 'MAX_LOG', 8):
                self.assertEqual(helper.planner_reachability_diagnostics('\n'.join(lines), BUNDLE, 'ipad', source_root), [])

    def test_planner_reachability_notice_is_optional_ipad_only_and_does_not_publish_acceptance(self):
        source = (ROOT / helper.SOURCE).read_text().splitlines()
        expected_call = ('let title = try reachable(app.staticTexts.matching(identifier: "plan.task.\\(task.uuid)"), '
                         'surface: .planner, target: .planTask, in: app)')
        caller_line = next(index for index, line in enumerate(source, 1) if line.strip() == expected_call)
        value = '\n'.join(self.planner_log_fixture(ROOT, callerLine=caller_line))
        reports = helper.planner_reachability_diagnostics(value, BUNDLE, 'ipad')
        self.assertEqual(len(reports), 1)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            (directory / 'test.log').write_text(value)
            output, summary = directory / 'github-output', directory / 'github-summary'
            output.write_text('previous=value\n')
            summary.write_text('previous summary\n')
            for platform, enabled in (('ipad', True), ('ipad', False), ('iphone', True), ('macos', True)):
                expected = {**EXPECTED, 'platform': platform}
                with mock.patch.object(helper, 'context_for', return_value={'bundle': BUNDLE}), \
                        mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output), 'GITHUB_STEP_SUMMARY': str(summary)}), \
                        mock.patch.object(helper.SUPPORT, 'write_json') as write, mock.patch('builtins.print') as printed:
                    helper.diagnostics(directory, expected, 'test', partial_failure=enabled)
                messages = [call.args[0] for call in printed.call_args_list]
                prefix = '::notice::Batch UI planner reachability diagnostics: '
                notices = [message for message in messages if message.startswith(prefix)]
                self.assertEqual(len(notices), int(platform == 'ipad' and enabled))
                if notices:
                    self.assertEqual(json.loads(notices[0][len(prefix):]),
                                     {**expected, 'scope': 'partialFailureOnly', 'locations': reports, 'locationCount': 1})
                self.assertEqual(messages[0], '::notice::Batch UI source diagnostics: ' + json.dumps(
                    {**expected, 'phase': 'test', 'scope': 'stdoutOnly', 'locations': helper.failure_locations(value, BUNDLE)}, sort_keys=True))
                self.assertTrue(any(message.startswith('::notice::Batch UI reachable failure diagnostics: ') for message in messages))
                write.assert_not_called()
                self.assertEqual(output.read_text(), 'previous=value\n')
                self.assertEqual(summary.read_text(), 'previous summary\n')
                self.assertFalse((directory / 'safe-outcome.json').exists())
                self.assertNotIn(str(ROOT), '\n'.join(messages))
            invalid = value.replace('"role": "staticText"', '"role": "SYNTHETIC_PRIVATE_ROLE"')
            (directory / 'test.log').write_text(invalid)
            with mock.patch.object(helper, 'context_for', return_value={'bundle': BUNDLE}), mock.patch('builtins.print') as printed:
                helper.diagnostics(directory, {**EXPECTED, 'platform': 'ipad'}, 'test', partial_failure=True)
            messages = [call.args[0] for call in printed.call_args_list]
            self.assertFalse(any(message.startswith(prefix) for message in messages))
            self.assertTrue(any(message.startswith('::notice::Batch UI reachable failure diagnostics: ') for message in messages))
            self.assertNotIn('SYNTHETIC_PRIVATE_ROLE', '\n'.join(messages))

    def task_row_source_fixture(self, source_root):
        source = self.planner_source_fixture(source_root)
        source.write_text(source.read_text() + '\n' + '\n'.join((
            '    private func originalTasks(_ titles: [String], in app: XCUIApplication) throws -> [OriginalTask] {',
            '        let tasks = try titles.map { title in',
            '            let query = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "task.row.", title))',
            '            let row = try reachable(query, surface: .library, target: .taskRow, in: app)',
            '        }', '    }',
        )))
        return source

    def task_row_log_fixture(self, source_root, bundle=BUNDLE, **changes):
        lines = self.planner_log_fixture(source_root, helper.CASES[1], **{
            'schemaVersion': 2, 'phase': 'libraryStarted', 'progressSequence': 64,
            'callerLine': 10, 'target': 'taskRow', 'role': 'button', **changes})
        lines[-2] = lines[-2].replace('target=planTask', 'target=taskRow')
        return [line.replace(BUNDLE, bundle) for line in
                ([event(helper.CASES[1], 'started')] + progress_lines(helper.CASES[1], 64) + lines[-3:])]

    def test_task_row_reachability_accepts_three_platforms_and_preserves_each_declared_case(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary).resolve()
            self.task_row_source_fixture(source_root)
            unchecked = {'windowCount': None, 'hittable': None, 'enabled': None, 'insideOwner': None}
            changes = ({}, {'targetFrame': [0, 0, 0, 0], **unchecked, 'ownerFrame': None},
                       {'exists': False, 'role': None, 'targetFrame': None, **unchecked, 'ownerFrame': None},
                       {'iteration': 12, 'deadlineExceededAtLastGuard': False, 'swipePerformed': True})
            for platform, bundle in (('iphone', BUNDLE), ('ipad', BUNDLE), ('macos', 'MirrorMacBatchUITests')):
                for change in changes:
                    with self.subTest(platform=platform, change=change):
                        lines = self.task_row_log_fixture(source_root, bundle, **change)
                        fields = json.loads(lines[-3][len(helper.PLANNER_REACHABILITY_MARKER):])
                        reports = helper.planner_reachability_diagnostics('\n'.join(lines), bundle, platform, source_root)
                        self.assertEqual(reports, [{'scope': 'partialFailureOnly', **fields,
                            'sourceFile': helper.SOURCE, 'line': 10, 'column': 1, 'terminal': 'failed'}])
                        self.assertNotIn(str(source_root), json.dumps(reports))
                        with self.assertRaises(helper.BatchError):
                            helper.validate_outcome({**EXPECTED, **reports[0]}, EXPECTED)
            both = [self.planner_log_fixture(source_root), self.task_row_log_fixture(source_root)]
            for order in (both, list(reversed(both))):
                reports = helper.planner_reachability_diagnostics('\n'.join(sum(order, [])), BUNDLE, 'ipad', source_root)
                self.assertEqual([report['schemaVersion'] for report in reports],
                                 [json.loads(lines[-3][len(helper.PLANNER_REACHABILITY_MARKER):])['schemaVersion'] for lines in order])
                self.assertEqual({report['method'] for report in reports}, set(helper.CASES))

    def test_task_row_reachability_rejects_wrong_schema_owner_platform_and_private_or_null_payload(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary).resolve()
            self.task_row_source_fixture(source_root)
            lines = self.task_row_log_fixture(source_root)
            fields = json.loads(lines[-3][len(helper.PLANNER_REACHABILITY_MARKER):])
            changes = ({'schemaVersion': 1}, {'schemaVersion': 3}, {'schemaVersion': True},
                       {'method': helper.CASES[0]}, {'phase': 'pickerStarted'}, {'progressSequence': 63},
                       {'progressSequence': 70}, {'progressSequence': True}, {'target': 'planTask'},
                       {'callerLine': 4}, {'observationTiming': 'freshQuery'},
                       {'role': 'SYNTHETIC_PRIVATE_TITLE'}, {'extra': '/private/synthetic/path'},
                       {'targetFrame': None}, {'targetFrame': [0, 0, 0, 0]}, {'ownerFrame': None},
                       {'exists': False}, {'hittable': None}, {'enabled': None}, {'insideOwner': True})
            for change in changes:
                with self.subTest(change=change):
                    marker = helper.PLANNER_REACHABILITY_MARKER + json.dumps({**fields, **change})
                    self.assertEqual(helper.planner_reachability_diagnostics(
                        '\n'.join(lines[:-3] + [marker] + lines[-2:]), BUNDLE, 'ipad', source_root), [])
            for platform, bundle in (('macos', BUNDLE), ('iphone', 'MirrorMacBatchUITests'),
                                     ('ipad', 'MirrorMacBatchUITests'), ('ipad', 'OtherUITests'), ('unknown', BUNDLE)):
                value = '\n'.join(self.task_row_log_fixture(source_root, bundle))
                self.assertEqual(helper.planner_reachability_diagnostics(value, bundle, platform, source_root), [])
            for wrong in (lines[-3].replace('"schemaVersion": 2', '"schemaVersion": 2, "schemaVersion": 2'),
                          lines[-3].ljust(1024), 'title="' + lines[-3] + '"'):
                self.assertEqual(helper.planner_reachability_diagnostics(
                    '\n'.join(lines[:-3] + [wrong] + lines[-2:]), BUNDLE, 'iphone', source_root), [])

    def test_task_row_reachability_requires_exact_source_query_and_one_ordered_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary).resolve()
            source = self.task_row_source_fixture(source_root)
            lines = self.task_row_log_fixture(source_root)
            before, marker, assertion, terminal = lines[:-3], *lines[-3:]
            invalid = (before[:-1] + [marker, assertion, terminal], before + [assertion, marker, terminal],
                       before + [marker, marker, assertion, terminal], before + [marker, assertion, assertion, terminal],
                       before + [assertion, marker, assertion, terminal], before + [marker, assertion, terminal, assertion],
                       before + [marker, progress_lines(helper.CASES[1], 65)[-1], assertion, terminal],
                       before + [marker, assertion], before + [marker, terminal],
                       before + [marker, assertion, terminal.replace('failed.', 'passed.')],
                       before + [marker, assertion, terminal.replace('failed.', 'skipped.')])
            for wrong in invalid:
                self.assertEqual(helper.planner_reachability_diagnostics('\n'.join(wrong), BUNDLE, 'ipad', source_root), [])
            for wrong in (assertion.replace('target=taskRow', 'target=planTask'), assertion + ' SYNTHETIC_PRIVATE_VALUE',
                          assertion.replace(helper.SOURCE, 'Tests/Other.swift'), assertion.replace(':10:1:', ':9:1:'),
                          assertion.replace(helper.CASES[1], helper.CASES[0]), assertion.replace(BUNDLE, 'OtherUITests')):
                self.assertEqual(helper.planner_reachability_diagnostics(
                    '\n'.join(before + [marker, wrong, terminal]), BUNDLE, 'ipad', source_root), [])
            original = source.read_text()
            query = original.splitlines()[8]
            call = original.splitlines()[9]
            for wrong in (original.replace('originalTasks(', 'otherTasks('),
                          original.replace('let tasks = try titles.map { title in', 'let tasks = try others.map { title in'),
                          original.replace('identifier BEGINSWITH %@ AND label == %@', 'label == %@'),
                          original.replace('"task.row.", title', '"task.row.", other'),
                          original.replace(query, query + '\n            // separated query'),
                          original.replace(call, call + '\n' + call),
                          original.replace('reachable(query, surface: .library', 'reachable(query, surface: .planner'),
                          original.replace('let tasks = try titles.map { title in', '}\n    private func otherTasks() {'),
                          original + '\n' + '\n'.join(original.splitlines()[6:])):
                source.write_text(wrong)
                self.assertEqual(helper.planner_reachability_diagnostics('\n'.join(lines), BUNDLE, 'ipad', source_root), [])

    def test_task_row_reachability_notice_is_partial_only_on_each_owned_platform(self):
        source = (ROOT / helper.SOURCE).read_text().splitlines()
        call = 'let row = try reachable(query, surface: .library, target: .taskRow, in: app)'
        line = next(index for index, text in enumerate(source, 1) if text.strip() == call)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            for platform, bundle in (('iphone', BUNDLE), ('ipad', BUNDLE), ('macos', 'MirrorMacBatchUITests')):
                value = '\n'.join(self.task_row_log_fixture(ROOT, bundle, callerLine=line))
                (directory / 'test.log').write_text(value)
                reports = helper.planner_reachability_diagnostics(value, bundle, platform)
                self.assertEqual(len(reports), 1)
                expected = {**EXPECTED, 'platform': platform}
                for enabled in (False, True):
                    with mock.patch.object(helper, 'context_for', return_value={'bundle': bundle}), \
                            mock.patch.object(helper.SUPPORT, 'write_json') as write, mock.patch('builtins.print') as printed:
                        helper.diagnostics(directory, expected, 'test', partial_failure=enabled)
                    messages = [call.args[0] for call in printed.call_args_list]
                    prefix = '::notice::Batch UI planner reachability diagnostics: '
                    notices = [message for message in messages if message.startswith(prefix)]
                    self.assertEqual(len(notices), int(enabled))
                    if notices:
                        self.assertEqual(json.loads(notices[0][len(prefix):]),
                                         {**expected, 'scope': 'partialFailureOnly', 'locations': reports, 'locationCount': 1})
                    self.assertEqual(messages[0], '::notice::Batch UI source diagnostics: ' + json.dumps(
                        {**expected, 'phase': 'test', 'scope': 'stdoutOnly', 'locations': helper.failure_locations(value, bundle)}, sort_keys=True))
                    self.assertTrue(any(message.startswith('::notice::Batch UI reachable failure diagnostics: ') for message in messages))
                    write.assert_not_called()
                    self.assertFalse((directory / 'safe-outcome.json').exists())
                    self.assertNotIn(str(ROOT), '\n'.join(messages))

    def test_mobile_target_notice_bounds_deduplicates_and_preserves_other_notices_without_payload(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_root = Path(temporary).resolve()
            self.mobile_source_fixture(source_root, ('width',) * 20)
            payload = 'XCTAssertGreaterThanOrEqual failed: SYNTHETIC_PRIVATE_TITLE 37.125 11111111-2222-3333-4444-555555555555 /private/synthetic - Batch UI mobile target: width taskSelection'
            rows = [self.mobile_target_fixture(source_root, payload, line=line) for line in range(1, 21)]
            reports = helper.mobile_target_failure_locations('\n'.join(row for row in rows for _ in (0, 1)), BUNDLE, source_root)
            self.assertEqual(len(reports), 12)
            self.assertEqual([report['line'] for report in reports], list(range(1, 13)))
            self.assertEqual(len(helper.mobile_target_failure_locations(rows[0] + '\n' + rows[0].replace('37.125', '38.875'), BUNDLE, source_root)), 1)
            with self.assertRaises(helper.BatchError):
                helper.mobile_target_failure_locations(None, BUNDLE, source_root)
            with mock.patch.object(helper, 'MAX_LOG', 8), self.assertRaises(helper.BatchError):
                helper.mobile_target_failure_locations(rows[0], BUNDLE, source_root)
        native_source = (ROOT / helper.SOURCE).read_text().splitlines()
        actual_line = next(index for index, text in enumerate(native_source, 1)
                           if text.strip() in ('XCTAssertGreaterThanOrEqual(element.frame.width, 44, "Batch UI mobile target: width \\(target)")',
                                               'XCTAssertGreaterThanOrEqual(width, 44, "Batch UI mobile target: width \\(target)")'))
        value = self.mobile_target_fixture(ROOT, payload, line=actual_line)
        actual = helper.mobile_target_failure_locations(value, BUNDLE)
        self.assertEqual(len(actual), 1)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            (directory / 'test.log').write_text(value)
            with mock.patch.object(helper, 'context_for', return_value={'bundle': BUNDLE}), mock.patch('builtins.print') as printed:
                helper.diagnostics(directory, EXPECTED, 'test')
            messages = [call.args[0] for call in printed.call_args_list]
            self.assertEqual(len(messages), 3)
            self.assertEqual(messages[0], '::notice::Batch UI source diagnostics: ' + json.dumps(
                {**EXPECTED, 'phase': 'test', 'scope': 'stdoutOnly', 'locations': helper.failure_locations(value, BUNDLE)}, sort_keys=True))
            self.assertEqual(messages[1], '::notice::Batch UI query failure diagnostics: ' + json.dumps(
                {**EXPECTED, 'phase': 'test', 'scope': 'stdoutOnly', 'locations': [], 'locationCount': 0}, sort_keys=True))
            prefix = '::notice::Batch UI mobile target diagnostics: '
            report = json.loads(messages[2][len(prefix):])
            self.assertEqual(report, {**EXPECTED, 'phase': 'test', 'scope': 'stdoutOnly', 'locations': actual, 'locationCount': 1})
            self.assertEqual(set(report), set(EXPECTED) | {'phase', 'scope', 'locations', 'locationCount'})
            for private in ('SYNTHETIC_PRIVATE_TITLE', '37.125', '11111111-2222-3333-4444-555555555555', '/private/synthetic', str(ROOT)):
                self.assertNotIn(private, '\n'.join(messages))
            (directory / 'build.log').write_text('SYNTHETIC_PRIVATE_TITLE')
            with mock.patch.object(helper, 'context_for', return_value={'bundle': BUNDLE}), \
                    mock.patch.object(helper.SUPPORT, 'compiler_diagnostics', return_value=[]), mock.patch('builtins.print') as printed:
                helper.diagnostics(directory, EXPECTED, 'build')
            self.assertEqual(len(printed.call_args_list), 1)



if __name__ == '__main__':
    unittest.main()
