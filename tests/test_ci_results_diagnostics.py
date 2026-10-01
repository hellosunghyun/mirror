"""UI·저장 결과 진단의 비공개 값 제외·기존 통과 게이트 회귀. Actions에서 실행한다."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('mirror_ci_results_diagnostics', ROOT / 'scripts/ci_results.py')
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
PRIVATE = 'SYNTHETIC_PRIVATE_TIMING_INPUT'
METHODS = (
    'testCaptureRemainsUnassignedUntilReviewExplicitlyChoosesToday',
    'testExplicitCompletionAndUndoPreserveEditedTitleAndPlan',
    'testOverlongTitleShowsErrorAndPreservesEveryCharacter',
    'testReviewUndoRestoresUnassignedCardInsteadOfAddingToToday',
    'testTomorrowStaysOutOfTodayAndIsSearchableInLibrary',
    'testWeekPanelCancellationAndPartialFinishPreserveUndecidedPlan',
)
STAGES = (
    'initial-today', 'calendar', 'settings', 'capture-form', 'review-card', 'week-picker', 'today-populated',
    'library', 'library-search', 'detail', 'detail-edit', 'completion', 'undo', 'validation-error', 'ipad-landscape',
)
CASE_NOTICE = '::notice::UI case timing: '
SCREENSHOT_NOTICE = '::notice::UI screenshot timing: '
STORE_DEDUP_NOTICE = '::notice::Store dedup result diagnostic: '
STORE_DEDUP_REJECTED_NOTICE = '::notice::Store dedup result diagnostic rejected: '


def case_line(method=METHODS[0], event='passed', seconds='12.345', module='MirrorIOSUITests'):
    # 실제 iPad Actions 로그의 XCTest 완료 줄에는 마지막 마침표가 있다.
    return f"Test Case '-[{module}.MirrorUITests {method}]' {event} ({seconds} seconds)."


def screenshot_line(stage='week-picker', milliseconds='123'):
    return f'UI screenshot timing: stage={stage},milliseconds={milliseconds}'


def store_dedup_line(payload=None):
    if payload is None:
        payload = {'states': ['locallyCommitted', 'unavailable'], 'busyResults': [False, True]}
    return 'Store dedup result diagnostic: ' + json.dumps(payload)


class CIResultsDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def capture(self, operation, *arguments):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            operation(*arguments)
        self.assertEqual(stderr.getvalue(), '')
        output = stdout.getvalue()
        self.assertNotIn(PRIVATE, output)
        return output

    def notices(self, output, prefix):
        return [json.loads(line[len(prefix):]) for line in output.splitlines() if line.startswith(prefix)]

    def test_store_dedup_valid_report_has_only_fixed_method_scope_states_and_bools(self):
        log = self.root / 'store-valid.log'
        log.write_text('fatal: /private/' + PRIVATE + ' ' + store_dedup_line() + '\n')
        output_path = self.root / 'github-output'
        output_path.write_text('previous=value\n')
        with mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path)}), \
                mock.patch.object(helper, 'record') as record:
            output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, STORE_DEDUP_NOTICE), [{
            'method': 'independentInstancesDeduplicate', 'scope': 'stdoutOnly',
            'states': ['locallyCommitted', 'unavailable'], 'busyResults': [False, True],
        }])
        self.assertEqual(self.notices(output, STORE_DEDUP_REJECTED_NOTICE), [])
        self.assertNotIn('/private/', output)
        self.assertNotIn('::error::', output)
        record.assert_not_called()
        self.assertEqual(output_path.read_text(), 'previous=value\n')

    def test_store_dedup_accepts_each_current_command_result_state(self):
        expected_states = {
            'locallyCommitted', 'alreadyApplied', 'requiresConfirmation', 'staleSnapshot',
            'staleContext', 'alreadyDecided', 'notFound', 'unavailable', 'persistenceFailed',
            'committedProjectionPending',
        }
        self.assertEqual(helper.COMMAND_RESULT_STATES, expected_states)
        for state in sorted(expected_states):
            with self.subTest(state=state):
                payload = {'states': [state, 'alreadyApplied'],
                           'busyResults': [state == 'unavailable', False]}
                log = self.root / 'store-state.log'
                log.write_text(store_dedup_line(payload) + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, STORE_DEDUP_NOTICE), [{
                    'method': 'independentInstancesDeduplicate', 'scope': 'stdoutOnly', **payload,
                }])
                self.assertEqual(self.notices(output, STORE_DEDUP_REJECTED_NOTICE), [])

    def test_store_dedup_rejects_unknown_state_and_wrong_payload_shapes(self):
        invalid_payloads = (
            {'states': ['locallyCommitted', PRIVATE], 'busyResults': [False, False]},
            {'states': [PRIVATE, 'alreadyApplied'], 'busyResults': [False, False]},
            {'states': [], 'busyResults': [False, False]},
            {'states': ['locallyCommitted'], 'busyResults': [False, False]},
            {'states': ['locallyCommitted', 'alreadyApplied', 'unavailable'], 'busyResults': [False, False]},
            {'states': 'locallyCommitted', 'busyResults': [False, False]},
            {'states': [None, 'alreadyApplied'], 'busyResults': [False, False]},
            {'states': [True, 'alreadyApplied'], 'busyResults': [False, False]},
            {'states': [{}, 'alreadyApplied'], 'busyResults': [False, False]},
            {'busyResults': [False, False]},
            {'states': ['locallyCommitted', 'alreadyApplied']},
            [], None, True,
        )
        for payload in invalid_payloads:
            with self.subTest(payload=payload):
                log = self.root / 'store-shape.log'
                # None도 기본 정상 payload가 아니라 실제 JSON null로 입력한다.
                log.write_text('Store dedup result diagnostic: ' + json.dumps(payload) + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, STORE_DEDUP_NOTICE), [])
                self.assertEqual(self.notices(output, STORE_DEDUP_REJECTED_NOTICE), [{'invalidCount': 1}])
                self.assertNotIn('::error::', output)

    def test_store_dedup_requires_exactly_two_actual_bool_values(self):
        invalid_values = (0, 1, 0.0, 1.0, 'true', 'false', None, [], {})
        invalid_arrays = ([], [False], [False, True, False], 'false,true', None)
        for value in invalid_values:
            for index in (0, 1):
                values = [False, True]
                values[index] = value
                invalid_arrays += (values,)
        for values in invalid_arrays:
            with self.subTest(busyResults=values):
                payload = {'states': ['locallyCommitted', 'unavailable'], 'busyResults': values}
                log = self.root / 'store-bool.log'
                log.write_text(store_dedup_line(payload) + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, STORE_DEDUP_NOTICE), [])
                self.assertEqual(self.notices(output, STORE_DEDUP_REJECTED_NOTICE), [{'invalidCount': 1}])
                self.assertNotIn('::error::', output)

    def test_store_dedup_rejects_private_extra_fields_duplicates_and_malformed_json(self):
        valid = {'states': ['locallyCommitted', 'alreadyApplied'], 'busyResults': [False, False]}
        private_payload = {**valid, 'private': 'UI row scroll owner: error: /private/' + PRIVATE}
        duplicate = ('{"states":["' + PRIVATE + '","alreadyApplied"],'
                     '"states":["locallyCommitted","alreadyApplied"],"busyResults":[false,false]}')
        lines = [store_dedup_line(private_payload),
                 'Store dedup result diagnostic: ' + duplicate,
                 store_dedup_line(valid) + ' error: ' + PRIVATE,
                 'Store dedup result diagnostic: {' + PRIVATE,
                 store_dedup_line(valid) + ' Store dedup result diagnostic: ' + PRIVATE,
                 'Store dedup result diagnostic: ' + json.dumps({**valid, 'private': PRIVATE * 4096}),
                 'Store dedup result diagnostic: ' + '[' * 1500 + '0' + ']' * 1500]
        log = self.root / 'store-private.log'
        log.write_text('\n'.join(lines) + '\n')
        output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, STORE_DEDUP_NOTICE), [])
        self.assertEqual(self.notices(output, STORE_DEDUP_REJECTED_NOTICE), [{'invalidCount': len(lines)}])
        self.assertNotIn('/private/', output)
        self.assertNotIn('UI row scroll owners:', output)
        self.assertNotIn('::error::', output)

    def test_store_dedup_interleaved_logs_keep_other_diagnostics_and_swift_target_gates(self):
        log = self.root / 'store-parallel.log'
        lines = [
            'Test run with 36 tests passed after 0.2 seconds.',
            store_dedup_line(),
            screenshot_line('detail', '123'),
            'Test run with 94 tests failed after 0.3 seconds.',
            store_dedup_line({'states': ['locallyCommitted', PRIVATE], 'busyResults': [False, False]}),
            'error: safe unrelated compiler failure',
            'Test run with 29 tests passed after 0.1 seconds.',
        ]
        log.write_text('\n'.join(lines) + '\n')
        output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, STORE_DEDUP_NOTICE), [{
            'method': 'independentInstancesDeduplicate', 'scope': 'stdoutOnly',
            'states': ['locallyCommitted', 'unavailable'], 'busyResults': [False, True],
        }])
        self.assertEqual(self.notices(output, STORE_DEDUP_REJECTED_NOTICE), [{'invalidCount': 1}])
        self.assertEqual(self.notices(output, SCREENSHOT_NOTICE), [
            {'scope': 'stdoutOnly', 'stage': 'detail', 'milliseconds': 123},
        ])
        self.assertEqual(self.notices(output, '::notice::Swift Testing completion reports: '), [[
            {'tests': 36, 'result': 'passed'}, {'tests': 94, 'result': 'failed'},
            {'tests': 29, 'result': 'passed'},
        ]])
        self.assertIn('::error::error: safe unrelated compiler failure', output)
        output_path = self.root / 'github-output'
        output_path.write_text('previous=value\n')
        with mock.patch.object(helper.sys, 'argv', ['ci_results.py', 'swift', str(log)]), \
                mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path)}), \
                mock.patch.object(helper, 'record') as record:
            with self.assertRaises(ValueError):
                self.capture(helper.main)
        record.assert_not_called()
        self.assertEqual(output_path.read_text(), 'previous=value\n')

        valid = {'states': ['locallyCommitted', 'alreadyApplied'], 'busyResults': [False, False]}
        log.write_text('\n'.join([
            'Test run with 36 tests passed after 0.2 seconds.', store_dedup_line(valid),
            'Test run with 94 tests passed after 0.3 seconds.',
            'Test run with 29 tests passed after 0.1 seconds.',
        ]) + '\n')
        with mock.patch.object(helper.sys, 'argv', ['ci_results.py', 'swift', str(log)]), \
                mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path)}):
            output = self.capture(helper.main)
        self.assertEqual(self.notices(output, STORE_DEDUP_NOTICE), [{
            'method': 'independentInstancesDeduplicate', 'scope': 'stdoutOnly', **valid,
        }])
        self.assertIn('"executedTests": 159, "result": "pass"', output)
        self.assertEqual(output_path.read_text(), 'previous=value\ntests=159\n')

    def test_duration_accepts_native_numbers_at_both_inclusive_bounds(self):
        for value in (0, 0.0, 0.001, 1199.999, 1200, 1200.0):
            with self.subTest(value=value):
                self.assertIs(helper.valid_ui_duration(value), True)
        for value in (True, False, None, '1', [], {}, -1, -0.001, 1200.001, 1201,
                      float('nan'), float('inf'), float('-inf'), 10 ** 400, complex(1, 0)):
            with self.subTest(value=value):
                self.assertIs(helper.valid_ui_duration(value), False)

    def test_case_timings_include_only_completed_baseline_cases_and_safe_fields(self):
        lines = [case_line(event='started'), case_line(seconds='0')[:-1],
                 case_line(METHODS[1], 'failed', '1200', 'MirrorMacUITests')]
        output = self.capture(helper.report_ui_timing_diagnostics, lines)
        self.assertEqual(self.notices(output, CASE_NOTICE), [
            {'scope': 'stdoutOnly', 'method': METHODS[0], 'event': 'passed', 'seconds': 0.0},
            {'scope': 'stdoutOnly', 'method': METHODS[1], 'event': 'failed', 'seconds': 1200.0},
        ])
        self.assertNotIn('MirrorIOSUITests', output)
        self.assertNotIn('MirrorMacUITests', output)

    def test_case_timings_keep_latest_valid_event_for_each_of_six_baselines(self):
        lines = [case_line(method, seconds='1') for method in METHODS]
        lines += [case_line(method, 'failed', '2.5') for method in METHODS]
        lines += [case_line(METHODS[0], seconds='1200.001'), case_line('test' + PRIVATE)]
        output = self.capture(helper.report_ui_timing_diagnostics, lines)
        cases = self.notices(output, CASE_NOTICE)
        self.assertEqual(len(cases), 6)
        self.assertEqual({case['method'] for case in cases}, set(METHODS))
        self.assertTrue(all(case['event'] == 'failed' and case['seconds'] == 2.5 for case in cases))

    def test_case_timing_rejects_malformed_or_out_of_range_decimal_text(self):
        for seconds in ('true', 'NaN', 'inf', '-1', '+1', '.5', '1.', '1e2', '1200.001',
                        '999999999999999999999', '\u0661', PRIVATE + '/private/path'):
            with self.subTest(seconds=seconds):
                self.assertEqual(self.capture(helper.report_ui_timing_diagnostics,
                                              [case_line(seconds=seconds)]), '')
        for line in (case_line('test' + PRIVATE), case_line(event='skipped'),
                     case_line() + ' error: /private/' + PRIVATE):
            with self.subTest(line=line):
                self.assertEqual(self.capture(helper.report_ui_timing_diagnostics, [line]), '')

    def test_screenshot_timing_accepts_fixed_stages_and_exact_millisecond_bounds(self):
        lines = [screenshot_line(stage, '0' if index == 0 else '1200000')
                 for index, stage in enumerate(STAGES)]
        output = self.capture(helper.report_ui_timing_diagnostics, lines)
        shots = self.notices(output, SCREENSHOT_NOTICE)
        self.assertEqual(len(shots), 15)
        self.assertEqual({shot['stage'] for shot in shots}, set(STAGES))
        self.assertEqual(shots[0], {'scope': 'stdoutOnly', 'stage': STAGES[0], 'milliseconds': 0})
        self.assertTrue(all(type(shot['milliseconds']) is int for shot in shots))
        self.assertEqual(shots[-1]['milliseconds'], 1200000)

    def test_screenshot_timing_retains_only_last_fifteen_valid_events(self):
        lines = [screenshot_line(milliseconds=str(value)) for value in range(20)]
        lines += [screenshot_line(PRIVATE), screenshot_line(milliseconds='1200001')]
        output = self.capture(helper.report_ui_timing_diagnostics, lines)
        self.assertEqual([shot['milliseconds'] for shot in self.notices(output, SCREENSHOT_NOTICE)],
                         list(range(5, 20)))

    def test_screenshot_timing_rejects_bad_tokens_and_trailing_payloads(self):
        lines = [screenshot_line(milliseconds=value) for value in
                 ('true', 'NaN', '-1', '+1', '1.0', '1e3', '1200001', '999999999999', '\u0661', PRIVATE)]
        lines += [screenshot_line('/private/' + PRIVATE), screenshot_line('week-picker/' + PRIVATE),
                  screenshot_line() + ' error: /private/' + PRIVATE,
                  'UI screenshot timing: stage=week-picker, milliseconds=123']
        self.assertEqual(self.capture(helper.report_ui_timing_diagnostics, lines), '')

    def test_log_prefixes_are_not_copied_into_timing_notices(self):
        prefix = '2026-10-01T00:00:00.000Z fatal: /private/' + PRIVATE + ' '
        output = self.capture(helper.report_ui_timing_diagnostics,
                              [prefix + case_line(), prefix + screenshot_line()])
        self.assertEqual(len(self.notices(output, CASE_NOTICE)), 1)
        self.assertEqual(len(self.notices(output, SCREENSHOT_NOTICE)), 1)
        self.assertNotIn('2026-10-01', output)
        self.assertNotIn('/private/', output)

    def test_diagnostics_filters_invalid_structured_payloads_from_raw_error_and_fallback(self):
        for lines in ([case_line('test' + PRIVATE, 'failed')],
                      [case_line(seconds=PRIVATE + '/private/path')],
                      [screenshot_line() + ' error: /private/' + PRIVATE],
                      [screenshot_line(PRIVATE, 'true')],
                      [case_line('test' + PRIVATE, 'failed').replace('Test Case', 'Test\tCase')],
                      [case_line('test' + PRIVATE, 'failed').replace('Test Case', 'Test  Case')],
                      [case_line(seconds='/private/' + PRIVATE).replace("Case '", 'Case ')],
                      [case_line(seconds='/private/' + PRIVATE).replace('.MirrorUITests ', '.MirrorUITests\t')]):
            with self.subTest(lines=lines):
                log = self.root / 'invalid.log'
                log.write_text('\n'.join(lines) + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, CASE_NOTICE), [])
                self.assertEqual(self.notices(output, SCREENSHOT_NOTICE), [])
                self.assertNotIn('/private/', output)

    def test_timing_diagnostics_never_record_success_or_write_actions_outputs(self):
        output_path = self.root / 'github-output'
        output_path.write_text('previous=value\n')
        samples = ['', screenshot_line(),
                   '\n'.join([case_line(method) for method in METHODS[:-1]] +
                             [f"Test Case '-[MirrorIOSUITests.MirrorUITests {METHODS[-1]}]' started."])]
        for text in samples:
            with self.subTest(text=text):
                log = self.root / 'incomplete.log'
                log.write_text(text)
                with mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path)}), \
                        mock.patch.object(helper, 'record') as record:
                    output = self.capture(helper.diagnostics, log)
                record.assert_not_called()
                self.assertEqual(output_path.read_text(), 'previous=value\n')
                self.assertNotIn('executedTests', output)
                self.assertNotIn('"result": "pass"', output)
                if text:
                    self.assertNotIn('"xcodeCompletionReported": true', output)

    def test_actual_xctest_started_line_survives_without_a_completion_result(self):
        log = self.root / 'started.log'
        log.write_text(f"Test Case '-[MirrorIOSUITests.MirrorUITests {METHODS[-1]}]' started.\n")
        output = self.capture(helper.diagnostics, log)
        summaries = self.notices(output, '::notice::UI stdout diagnostics: ')
        self.assertEqual(len(summaries), 1)
        self.assertEqual(summaries[0]['events'], [{'method': METHODS[-1], 'event': 'started'}])
        self.assertIs(summaries[0]['xcodeCompletionReported'], False)
        self.assertEqual(self.notices(output, CASE_NOTICE), [])

    def test_zero_test_record_still_fails_without_writing_outputs(self):
        output_path = self.root / 'github-output'
        output_path.write_text('previous=value\n')
        with mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path)}):
            with self.assertRaises(ValueError):
                helper.record(0)
        self.assertEqual(output_path.read_text(), 'previous=value\n')

    def test_ui_guard_still_requires_every_case_and_rejects_failed_or_skipped_results(self):
        source = self.root / 'sources'
        source.mkdir()
        (source / 'MirrorUITests.swift').write_text('\n'.join(f'func {method}() {{}}' for method in METHODS))
        tree_path = self.root / 'ui-tests.json'
        for missing, bad_result in ((True, None), (False, 'Failed'), (False, 'Skipped')):
            with self.subTest(missing=missing, bad_result=bad_result):
                children = [{'nodeType': 'Test Case', 'name': method + '()', 'result': 'Passed',
                             'durationInSeconds': 1.0} for method in (METHODS[:-1] if missing else METHODS)]
                if bad_result is not None:
                    children[-1]['result'] = bad_result
                tree_path.write_text(json.dumps({'testNodes': [{'nodeType': 'UI test bundle',
                    'name': 'MirrorIOSUITests', 'result': 'Passed', 'children': children}]}))
                with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(ValueError):
                    helper.ui_guard(tree_path, 'MirrorIOSUITests', source)

    def test_tree_timings_use_only_baseline_case_result_and_numeric_duration(self):
        nodes = {'testNodes': [
            {'nodeType': 'Test Case', 'name': METHODS[0] + '()', 'result': 'Passed',
             'durationInSeconds': 0, 'duration': PRIVATE, 'nodeIdentifierURL': '/private/' + PRIVATE},
            {'nodeType': 'Test Case', 'name': METHODS[1] + '()', 'result': 'Failed',
             'durationInSeconds': 1200.0},
            {'nodeType': 'Failure Message', 'name': METHODS[2] + '()', 'result': 'Passed',
             'durationInSeconds': 1.0},
            {'nodeType': 'Test Case', 'name': 'test' + PRIVATE, 'result': 'Passed', 'durationInSeconds': 1.0},
        ]}
        output = self.capture(helper.report_ui_tree_timings, nodes)
        self.assertEqual(self.notices(output, CASE_NOTICE), [
            {'scope': 'xcresult', 'method': METHODS[0], 'event': 'passed', 'seconds': 0.0},
            {'scope': 'xcresult', 'method': METHODS[1], 'event': 'failed', 'seconds': 1200.0},
        ])
        self.assertNotIn('nodeIdentifierURL', output)
        self.assertNotIn('/private/', output)

    def test_tree_timing_rejects_invalid_numeric_values_and_nonfinal_results(self):
        invalid = (True, False, None, '12.3', -0.001, 1200.001, float('nan'), float('inf'), 10 ** 400)
        nodes = [{'nodeType': 'Test Case', 'name': METHODS[0] + '()', 'result': 'Passed',
                  'durationInSeconds': value} for value in invalid]
        nodes += [{'nodeType': 'Test Case', 'name': METHODS[0] + '()', 'result': result,
                   'durationInSeconds': 1.0} for result in ('Skipped', 'started', PRIVATE)]
        self.assertEqual(self.capture(helper.report_ui_tree_timings, nodes), '')

    def test_tree_timings_keep_latest_valid_result_per_baseline_without_declaring_success(self):
        nodes = [{'nodeType': 'Test Case', 'name': method + '()', 'result': result,
                  'durationInSeconds': seconds} for result, seconds in (('Passed', 1), ('Failed', 2))
                 for method in METHODS]
        with mock.patch.object(helper, 'record') as record:
            output = self.capture(helper.report_ui_tree_timings, {'testNodes': nodes})
        record.assert_not_called()
        cases = self.notices(output, CASE_NOTICE)
        self.assertEqual(len(cases), 6)
        self.assertEqual({case['method'] for case in cases}, set(METHODS))
        self.assertTrue(all(case['event'] == 'failed' and case['seconds'] == 2.0 for case in cases))
        self.assertNotIn('executedTests', output)


if __name__ == '__main__':
    unittest.main()
