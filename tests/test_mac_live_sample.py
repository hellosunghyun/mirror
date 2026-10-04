"""Mac 현재 fixture의 live sample 소유·비공개 경계. Actions에서만 실행한다."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    'mac_live_sample', Path(__file__).resolve().parents[1] / 'scripts/ci-mac-live-sample.py')
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
CASE = 'testCaptureRemainsUnassignedUntilReviewExplicitlyChoosesToday'
PENDING = 'UI native query pending: settingsClose'
COMPLETE = 'UI native query complete: settingsClose'
PRIVATE = 'SYNTHETIC_PRIVATE_SAMPLE_PATH_TITLE'
ERRORS = (ValueError, KeyError, TypeError, OSError)


def event(method=CASE, state='started', owner='MirrorMacUITests.MirrorUITests'):
    suffix = '.' if state == 'started' else ' (15.001 seconds).'
    return "Test Case '-[" + owner + ' ' + method + "]' " + state + suffix


def waiting_marker():
    state = helper.MarkerState()
    state.feed(event(), 1.0)
    state.feed(PENDING, 10.0)
    return state


def receipt_fixture(directory):
    root = Path(directory).resolve()
    products = root / 'DerivedData/Build/Products'
    relative = 'Debug/Mirror.app/Contents/MacOS/Mirror'
    executable = products / relative
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b'synthetic unsigned fixture executable')
    environment = {'GITHUB_SHA': 'a' * 40, 'GITHUB_RUN_ID': '101',
                   'GITHUB_RUN_ATTEMPT': '2', 'GITHUB_RUN_NUMBER': '30'}
    context = {'platform': 'macos', 'scheme': 'MirrorMac', 'sdk': 'macosx',
               'destination': 'platform=macOS,arch=arm64', 'commit': environment['GITHUB_SHA'],
               'run_id': '101', 'run_attempt': '2', 'build_number': '30'}
    context_bytes = json.dumps(context).encode()
    (root / 'unit-context.json').write_bytes(context_bytes)
    digest = hashlib.sha256(executable.read_bytes()).hexdigest()
    receipt = {'format_version': 1, 'context': context, 'configuration': 'Debug',
               'ui_scheme': 'MirrorMacUI', 'code_signing_allowed': False, 'code_coverage': False,
               'unit_context_sha256': hashlib.sha256(context_bytes).hexdigest(),
               'app': {'build_number': '30',
                       'executable': {'path': relative, 'resolved_path': relative, 'sha256': digest}}}
    (root / 'ui-build-receipt.json').write_text(json.dumps(receipt))
    return root, executable, digest, environment, receipt


class LiveSampleMarkerTests(unittest.TestCase):
    def test_only_the_owned_pending_query_reaches_the_fifteen_second_boundary(self):
        state = helper.MarkerState()
        self.assertFalse(state.ready(100.0))
        state.feed(event(), 1.0)
        self.assertFalse(state.ready(100.0))
        state.feed(PENDING, 10.0)
        self.assertFalse(state.ready(24.999))
        self.assertTrue(state.ready(25.0))
        self.assertFalse(state.done)

    def test_completed_query_cannot_be_reactivated_by_later_pending_markers(self):
        state = waiting_marker()
        state.feed(COMPLETE, 24.0)
        self.assertTrue(state.done)
        self.assertFalse(state.ready(25.0))
        state.feed(PENDING, 30.0)
        self.assertFalse(state.ready(100.0))
        self.assertTrue(state.done)

    def test_case_terminal_other_case_and_duplicate_markers_close_the_gate(self):
        rows = [event(state=terminal) for terminal in ('passed', 'failed', 'skipped')]
        rows += [event('testTomorrowPlanSurvivesRestart'), event(), PENDING]
        for index, row in enumerate(rows):
            with self.subTest(boundary=index):
                state = waiting_marker()
                state.feed(row, 11.0)
                self.assertTrue(state.done)
                self.assertFalse(state.ready(100.0))

    def test_unowned_and_unknown_query_markers_never_arm_the_sampler(self):
        for rows in ([PENDING], [event(owner='ForeignTests.MirrorUITests'), PENDING],
                     [event(owner='MirrorMacUITests.ForeignTests'), event(), PENDING],
                     [event('testOtherCase'), PENDING],
                     [event(), 'UI native query pending: ' + PRIVATE],
                     [event(), PENDING + ' ' + PRIVATE],
                     [event(), COMPLETE],
                     [event(), PENDING, 'UI native query complete: ' + PRIVATE]):
            with self.subTest(boundary=len(rows)):
                state = helper.MarkerState()
                for offset, row in enumerate(rows):
                    state.feed(row, float(offset))
                self.assertFalse(state.ready(100.0))


class LiveSampleOwnershipTests(unittest.TestCase):
    def test_receipt_binds_current_identity_unsigned_configuration_and_executable_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            root, executable, digest, environment, receipt = receipt_fixture(directory)
            found, actual_hash, identity = helper.verify_receipt(root, environment)
            self.assertTrue(found == executable)
            self.assertEqual(actual_hash, digest)
            self.assertEqual(identity, {'commit': 'a' * 40, 'run_id': '101',
                                        'run_attempt': '2', 'build_number': '30'})
            for key in environment:
                with self.subTest(field=key), self.assertRaises(ERRORS):
                    helper.verify_receipt(root, {**environment, key: '9' * 40})
            for key, value in (('format_version', True), ('configuration', 'Release'),
                               ('ui_scheme', 'MirrorMacUIDark'), ('code_signing_allowed', True),
                               ('code_coverage', 0), ('unit_context_sha256', 'b' * 64)):
                (root / 'ui-build-receipt.json').write_text(json.dumps({**receipt, key: value}))
                with self.subTest(field=key), self.assertRaises(ERRORS):
                    helper.verify_receipt(root, environment)
            (root / 'ui-build-receipt.json').write_text(json.dumps(receipt))
            executable.write_bytes(PRIVATE.encode())
            with self.assertRaises(ERRORS):
                helper.verify_receipt(root, environment)

    def test_malformed_duplicate_and_symlink_receipts_and_context_are_rejected(self):
        for filename in ('ui-build-receipt.json', 'unit-context.json'):
            for kind in ('truncated', 'duplicate', 'symlink', 'missing'):
                with self.subTest(file=filename, kind=kind), tempfile.TemporaryDirectory() as directory:
                    root, _, _, environment, _ = receipt_fixture(directory)
                    target = root / filename
                    original = target.read_bytes()
                    target.unlink()
                    if kind == 'truncated':
                        target.write_bytes(b'{')
                    elif kind == 'duplicate':
                        target.write_text('{"duplicate":1,"duplicate":2}')
                    elif kind == 'symlink':
                        other = root / 'private-target'
                        other.write_bytes(original)
                        target.symlink_to(other)
                    with self.assertRaises(ERRORS):
                        helper.verify_receipt(root, environment)

    def test_executable_escape_changed_resolution_and_symlink_are_rejected(self):
        for kind in ('absolute', 'traversal', 'resolution', 'symlink', 'build'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root, executable, _, environment, receipt = receipt_fixture(directory)
                record = receipt['app']['executable']
                if kind == 'absolute':
                    record['path'] = record['resolved_path'] = str(executable)
                elif kind == 'traversal':
                    record['path'] = record['resolved_path'] = '../' + PRIVATE
                elif kind == 'resolution':
                    record['resolved_path'] = 'Debug/' + PRIVATE
                elif kind == 'build':
                    receipt['app']['build_number'] = '31'
                else:
                    other = root / 'private-executable'
                    executable.rename(other)
                    executable.symlink_to(other)
                (root / 'ui-build-receipt.json').write_text(json.dumps(receipt))
                with self.assertRaises(ERRORS):
                    helper.verify_receipt(root, environment)

    def test_process_selection_requires_exact_path_uid_strict_birth_and_one_candidate(self):
        executable = Path('/synthetic/fixture/Mirror')
        paths = {10: executable, 11: Path('/synthetic/other/Mirror'),
                 12: executable, 13: executable, 14: executable}
        rows = [(10, 501, 101.0), (11, 501, 102.0), (12, 502, 103.0), (13, 501, 100.0)]
        self.assertEqual(helper.select_process(rows, executable, 100.0, 501, paths.get), (10, 101.0))
        for candidates in (rows[1:], rows + [(14, 501, 104.0)], [(0, 501, 101.0)],
                           [(10, 501, 99.0)], [(10, 501, 100.0)]):
            with self.subTest(count=len(candidates)), self.assertRaises(ValueError):
                helper.select_process(candidates, executable, 100.0, 501, paths.get)
        with self.assertRaises(ValueError):
            helper.select_process(rows, executable, 100.0, 501, lambda _: None)

    def test_process_list_uses_private_lstart_and_no_command_line_fields(self):
        completed = subprocess.CompletedProcess([], 0,
            stdout=b'  17 501 Sun Oct  4 12:00:00 2026\n', stderr=PRIVATE.encode())
        with mock.patch.object(helper.subprocess, 'run', return_value=completed) as run:
            rows = helper.process_rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][:2], (17, 501))
        self.assertIsInstance(rows[0][2], float)
        self.assertEqual(run.call_args.args[0], ['/bin/ps', '-axo', 'pid=,uid=,lstart='])
        self.assertEqual(run.call_args.kwargs['env']['LC_ALL'], 'C')
        self.assertEqual(run.call_args.kwargs['env']['TZ'], 'UTC')
        for output, code in ((b'\xff', 0), (b'17 501 unknown time\n', 0), (b'', 1)):
            with mock.patch.object(helper.subprocess, 'run',
                    return_value=subprocess.CompletedProcess([], code, stdout=output, stderr=PRIVATE.encode())), \
                    self.assertRaises(ValueError):
                helper.process_rows()


class LiveSamplePrivacyTests(unittest.TestCase):
    def test_failure_metadata_uses_types_and_internal_codes_without_copying_exception_content(self):
        failures = [(json.JSONDecodeError(PRIVATE, PRIVATE, 0), 'jsonInvalid'),
                    (UnicodeDecodeError('ascii', b'\xff', 0, 1, PRIVATE), 'textInvalid'),
                    (PermissionError(PRIVATE), 'permissionDenied'),
                    (FileNotFoundError(PRIVATE), 'fileUnavailable'),
                    (subprocess.TimeoutExpired(PRIVATE, 3, output=PRIVATE, stderr=PRIVATE), 'processTimeout'),
                    (subprocess.CalledProcessError(73, PRIVATE, output=PRIVATE, stderr=PRIVATE), 'processError'),
                    (OSError(PRIVATE), 'osError'), (KeyError(PRIVATE), 'fieldMissing'),
                    (TypeError(PRIVATE), 'typeInvalid'), (AttributeError(PRIVATE), 'attributeUnavailable'),
                    (ValueError('receiptMismatch'), 'valueInvalid'),
                    (helper.CheckFailure(PRIVATE), 'valueInvalid'),
                    (helper.CheckFailure('receiptMismatch', PRIVATE), 'valueInvalid'),
                    (RuntimeError(PRIVATE), 'unknown')]
        for error, kind in failures:
            with self.subTest(kind=kind):
                result = helper.failure_details(error, PRIVATE)
                self.assertEqual(result, {'stage': 'unknown', 'failureKind': kind})
                self.assertNotIn(PRIVATE, json.dumps(result))
        self.assertEqual(helper.failure_details(helper.CheckFailure('receiptMismatch'), 'receiptBefore'),
                         {'stage': 'receiptBefore', 'failureKind': 'receiptMismatch'})

    def test_classification_exposes_fixed_counts_only_for_actual_main_thread_frames(self):
        text = '\n'.join((PRIVATE, 'Call graph:',
            '  10 Thread_0x123 DispatchQueue_1: com.apple.main-thread (serial)',
            '  + 10 mach_msg2_trap (in libsystem_kernel.dylib) + 0',
            '  + 8 __ulock_wait (in libsystem_kernel.dylib) + 0',
            '  + 6 viewBody (in SwiftUICore) + 0',
            '  + 4 ' + PRIVATE + ' (in Mirror.debug.dylib) + 0',
            '  + 2 ' + PRIVATE + ' (in ' + PRIVATE + ') + 0',
            '  + 2 fetch (in CoreData) + 0',
            '  + 2 update (in AttributeGraph) + 0',
            '  + 2 layout (in AppKit) + 0',
            '  + 2 -[NSApplication run] (in AppKit) + 0',
            '  10 Thread_0x456 DispatchQueue_2: worker (serial)',
            '  + 10 semaphore_wait_trap (in libsystem_kernel.dylib) + 0',
            'Binary Images:', PRIVATE))
        result = helper.classify_sample(text)
        self.assertEqual(result, {'mainThreadObserved': True,
            'frameCounts': {'runLoop': 2, 'synchronousWait': 1, 'swiftUI': 1, 'coreData': 1,
                            'attributeGraph': 1, 'appKit': 1, 'app': 1, 'other': 1}})
        self.assertNotIn(PRIVATE, json.dumps(result))
        self.assertNotIn('Thread_0x123', json.dumps(result))
        absent = helper.classify_sample(PRIVATE + '\n  + 1 __ulock_wait (in libsystem_kernel.dylib)')
        self.assertFalse(absent['mainThreadObserved'])
        self.assertTrue(all(value == 0 for value in absent['frameCounts'].values()))

    def test_sample_exit_remains_native_and_raw_command_output_stays_private(self):
        for code in (0, 73, -15):
            with self.subTest(exit=code), tempfile.TemporaryDirectory() as directory:
                private = Path(directory)
                process = mock.Mock(returncode=code)
                process.poll.return_value = code
                def launch(arguments, stdout, stderr):
                    self.assertIs(stdout, stderr)
                    stdout.write(PRIVATE.encode())
                    self.assertEqual(arguments[:5], ['/usr/bin/sample', '17', '3', '10', '-file'])
                    return process
                with mock.patch.object(helper.subprocess, 'Popen', side_effect=launch), \
                        contextlib.redirect_stdout(io.StringIO()) as output, \
                        contextlib.redirect_stderr(io.StringIO()) as errors:
                    result = helper.sample_once(17, private, lambda: False)
                self.assertEqual(result, code)
                self.assertEqual(output.getvalue() + errors.getvalue(), '')
                self.assertEqual(stat.S_IMODE((private / 'sample.txt').stat().st_mode), 0o600)
                self.assertEqual(stat.S_IMODE((private / 'sample-command.txt').stat().st_mode), 0o600)
                process.terminate.assert_not_called()
                process.kill.assert_not_called()
                process.wait.assert_called_once_with()

    def test_stop_and_deadline_kill_unresponsive_sampler_and_reap_it(self):
        for stopped in (False, True):
            with self.subTest(stopped=stopped), tempfile.TemporaryDirectory() as directory:
                process = mock.Mock()
                process.poll.return_value = None
                process.wait.side_effect = [subprocess.TimeoutExpired('sample', 1), 0]
                with mock.patch.object(helper.subprocess, 'Popen', return_value=process), \
                        mock.patch.object(helper.time, 'monotonic', side_effect=[0.0, 8.0]), \
                        mock.patch.object(helper.time, 'sleep') as sleep:
                    result = helper.sample_once(17, Path(directory), lambda: stopped)
                self.assertIsNone(result)
                process.terminate.assert_called_once_with()
                self.assertGreaterEqual(process.kill.call_count, 1)
                self.assertEqual(process.wait.call_args_list, [mock.call(timeout=1), mock.call()])
                sleep.assert_not_called()


class LiveSampleWatchTests(unittest.TestCase):
    def run_watch(self, directory, *, mode='observed', code=0, diagnostic=None):
        root, executable, _, environment, _ = receipt_fixture(directory)
        runner_temp = root / 'private-runner-temp'
        runner_temp.mkdir()
        environment['RUNNER_TEMP'] = str(runner_temp)
        marker, log = root / 'ui-start.marker', root / 'ui.log'
        marker.touch()
        os.utime(marker, (100.0, 100.0))
        log.write_text(event() + '\n' + PENDING + '\n')
        os.utime(log, (200.0, 200.0))
        directories = []
        def sample(pid, private, stopped):
            self.assertEqual(pid, 17)
            self.assertFalse(stopped())
            self.assertEqual(stat.S_IMODE(private.stat().st_mode), 0o700)
            directories.append(private)
            output = private / 'sample.txt'
            output.write_text(PRIVATE + '\nCall graph:\n'
                '  10 Thread_0x123 DispatchQueue_1: com.apple.main-thread (serial)\n'
                '  + 10 __ulock_wait (in libsystem_kernel.dylib) + 0\n')
            (private / 'sample-command.txt').write_text(PRIVATE)
            if mode == 'complete':
                with log.open('a') as stream:
                    stream.write(COMPLETE + '\n')
            elif mode == 'buildChanged':
                executable.write_bytes(PRIVATE.encode())
            elif mode == 'sampleSymlink':
                output.unlink()
                output.symlink_to(executable)
            elif mode == 'sampleOversized':
                with output.open('wb') as stream:
                    stream.truncate(4 * 1024 * 1024 + 1)
            elif mode == 'sampleRaises':
                raise OSError(PRIVATE)
            elif mode == 'unclassified':
                output.write_text(PRIVATE)
            elif mode == 'mainWithoutFrames':
                output.write_text('Call graph:\n'
                    '  10 Thread_0x123 DispatchQueue_1: com.apple.main-thread (serial)\n' + PRIVATE)
            return code
        rows = [[(17, 501, 101.0)], [(17, 501, 102.0 if mode == 'pidReused' else 101.0)]]
        if mode == 'postRowsRaises':
            rows[1] = subprocess.TimeoutExpired(PRIVATE, 3, output=PRIVATE, stderr=PRIVATE)
        elif mode == 'postOwnerMissing':
            rows[1] = []
        with mock.patch.dict(helper.os.environ, environment, clear=True), \
                mock.patch.object(helper.signal, 'signal'), \
                mock.patch.object(helper.os, 'getppid', return_value=42), \
                mock.patch.object(helper.os, 'getuid', return_value=501), \
                mock.patch.object(helper.time, 'monotonic', side_effect=[0.0, 0.0, 15.0, 15.0, 15.0, 15.0]), \
                mock.patch.object(helper.time, 'sleep') as sleep, \
                mock.patch.object(helper, 'process_rows', side_effect=rows), \
                mock.patch.object(helper, 'process_path_reader', return_value=lambda _: executable), \
                mock.patch.object(helper, 'sample_once', side_effect=sample) as sampler, \
                contextlib.redirect_stdout(io.StringIO()) as output, \
                contextlib.redirect_stderr(io.StringIO()) as errors:
            try:
                result = helper.watch(root, 42, diagnostic)
            finally:
                self.assertTrue(directories)
                self.assertTrue(all(not private.exists() for private in directories))
                self.assertFalse(any(runner_temp.iterdir()))
                self.assertEqual(output.getvalue() + errors.getvalue(), '')
            sampler.assert_called_once()
            sleep.assert_not_called()
        self.assertNotIn(PRIVATE, json.dumps(result))
        self.assertNotIn(str(root), json.dumps(result))
        return result

    def test_one_owned_sample_exports_counts_and_removes_all_private_files(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_watch(directory)
        self.assertEqual(result['status'], 'sampleObserved')
        self.assertEqual(result['sampleExit'], 0)
        self.assertTrue(result['mainThreadObserved'])
        self.assertEqual(result['frameCounts']['synchronousWait'], 1)
        self.assertEqual(set(result), {'status', 'sampleExit', 'commit', 'run_id', 'run_attempt',
                                      'build_number', 'mainThreadObserved', 'frameCounts'})

    def test_query_completed_during_process_selection_is_rechecked_before_sampling(self):
        with tempfile.TemporaryDirectory() as directory:
            root, executable, _, environment, _ = receipt_fixture(directory)
            private = root / 'private-runner-temp'
            private.mkdir()
            environment['RUNNER_TEMP'] = str(private)
            marker, log = root / 'ui-start.marker', root / 'ui.log'
            marker.touch()
            os.utime(marker, (100.0, 100.0))
            log.write_text(event() + '\n' + PENDING + '\n')
            def process_rows():
                with log.open('a') as stream:
                    stream.write(COMPLETE + '\n')
                return [(17, 501, 101.0)]
            with mock.patch.dict(helper.os.environ, environment, clear=True), \
                    mock.patch.object(helper.signal, 'signal'), \
                    mock.patch.object(helper.os, 'getppid', return_value=42), \
                    mock.patch.object(helper.os, 'getuid', return_value=501), \
                    mock.patch.object(helper.time, 'monotonic', side_effect=[0.0, 0.0, 15.0, 15.0, 15.0]), \
                    mock.patch.object(helper, 'process_rows', side_effect=process_rows), \
                    mock.patch.object(helper, 'process_path_reader', return_value=lambda _: executable), \
                    mock.patch.object(helper, 'sample_once') as sample:
                result = helper.watch(root, 42)
            self.assertEqual(result['status'], 'queryEndedBeforeSample')
            self.assertNotIn('sampleExit', result)
            sample.assert_not_called()
            self.assertFalse(any(private.iterdir()))

    def test_finished_query_changed_owner_and_invalid_sample_never_publish_frames(self):
        variants = [('complete', 0, 'queryEndedDuringSample'), ('pidReused', 0, 'ownerChanged'),
                    ('buildChanged', 0, 'ownerChanged'), ('sampleSymlink', 0, 'sampleFormatUnavailable'),
                    ('sampleOversized', 0, 'sampleFormatUnavailable'), ('observed', 73, 'sampleUnavailable'),
                    ('observed', None, 'sampleUnavailable')]
        for mode, code, status in variants:
            with self.subTest(mode=mode, exit=code), tempfile.TemporaryDirectory() as directory:
                result = self.run_watch(directory, mode=mode, code=code)
            self.assertEqual(result['status'], status)
            self.assertEqual(result['sampleExit'], code)
            self.assertNotIn('frameCounts', result)

    def test_cleanup_also_runs_when_private_sample_creation_throws(self):
        diagnostic = {}
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(OSError) as failure:
            self.run_watch(directory, mode='sampleRaises', diagnostic=diagnostic)
        self.assertEqual(helper.failure_details(failure.exception, diagnostic['stage']),
                         {'stage': 'sample', 'failureKind': 'osError'})

    def test_post_sample_failures_keep_owner_changed_native_exit_and_cleanup(self):
        for mode, stage, kind in (('postRowsRaises', 'processListAfter', 'processTimeout'),
                                  ('postOwnerMissing', 'processOwnerAfter', 'processOwnerUnavailable'),
                                  ('buildChanged', 'receiptAfter', 'executableMismatch')):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                result = self.run_watch(directory, mode=mode, code=73)
            self.assertEqual(result['status'], 'ownerChanged')
            self.assertEqual(result['sampleExit'], 73)
            self.assertEqual(result['stage'], stage)
            self.assertEqual(result['failureKind'], kind)
            self.assertNotIn('frameCounts', result)

    def test_main_identifies_pre_sample_boundaries_without_relaxing_sampling_ownership(self):
        for boundary, kind in (('receiptBefore', 'receiptMismatch'),
                               ('processPathReader', 'permissionDenied'),
                               ('processListBefore', 'processTimeout'),
                               ('processOwnerBefore', 'processOwnerUnavailable'),
                               ('temporaryDirectory', 'fieldMissing')):
            with self.subTest(boundary=boundary), tempfile.TemporaryDirectory() as directory:
                root, executable, _, environment, receipt = receipt_fixture(directory)
                marker, log = root / 'ui-start.marker', root / 'ui.log'
                marker.touch()
                os.utime(marker, (100.0, 100.0))
                log.write_text(event() + '\n' + PENDING + '\n')
                if boundary == 'receiptBefore':
                    receipt['configuration'] = PRIVATE
                    (root / 'ui-build-receipt.json').write_text(json.dumps(receipt))
                with mock.patch.dict(helper.os.environ, environment, clear=True), \
                        mock.patch.object(helper.sys, 'platform', 'darwin'), \
                        mock.patch.object(helper.sys, 'argv', ['helper', str(root), '42']), \
                        mock.patch.object(helper.signal, 'signal'), \
                        mock.patch.object(helper.os, 'getppid', return_value=42), \
                        mock.patch.object(helper.os, 'getuid', return_value=501), \
                        mock.patch.object(helper.time, 'monotonic', side_effect=[0.0, 0.0, 15.0, 15.0]), \
                        mock.patch.object(helper, 'process_path_reader', return_value=lambda _: executable) as reader, \
                        mock.patch.object(helper, 'process_rows', return_value=[(17, 501, 101.0)]) as rows, \
                        mock.patch.object(helper, 'sample_once') as sample, \
                        contextlib.redirect_stdout(io.StringIO()) as output, \
                        contextlib.redirect_stderr(io.StringIO()) as errors:
                    if boundary == 'processPathReader':
                        reader.side_effect = PermissionError(PRIVATE)
                    elif boundary == 'processListBefore':
                        rows.side_effect = subprocess.TimeoutExpired(PRIVATE, 3, output=PRIVATE, stderr=PRIVATE)
                    elif boundary == 'processOwnerBefore':
                        rows.return_value = []
                    helper.main()
                expected = {'status': 'diagnosticUnavailable', 'stage': boundary, 'failureKind': kind}
                self.assertEqual(output.getvalue(), '::notice::Mac live sample: ' + json.dumps(expected, sort_keys=True) + '\n')
                self.assertEqual(errors.getvalue(), '')
                sample.assert_not_called()

    def test_successful_native_exit_with_unrecognized_format_is_not_observed_evidence(self):
        for mode in ('unclassified', 'mainWithoutFrames'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                result = self.run_watch(directory, mode=mode)
            self.assertEqual(result['status'], 'sampleUnclassified')
            self.assertEqual(result['sampleExit'], 0)
            self.assertEqual(result['mainThreadObserved'], mode == 'mainWithoutFrames')
            self.assertTrue(all(value == 0 for value in result['frameCounts'].values()))

    def test_stale_and_symlink_logs_or_start_markers_cannot_select_a_process(self):
        for kind in ('staleLog', 'logSymlink', 'markerSymlink'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                marker, log = root / 'ui-start.marker', root / 'ui.log'
                marker.touch()
                os.utime(marker, (100.0, 100.0))
                log.write_text(event() + '\n' + PENDING + '\n')
                os.utime(log, (99.0 if kind == 'staleLog' else 101.0,) * 2)
                if kind != 'staleLog':
                    target = log if kind == 'logSymlink' else marker
                    real = root / 'private-file'
                    target.rename(real)
                    target.symlink_to(real)
                with mock.patch.object(helper.signal, 'signal'), \
                        mock.patch.object(helper.os, 'getppid', return_value=42), \
                        mock.patch.object(helper, 'process_rows') as rows, \
                        mock.patch.object(helper, 'sample_once') as sample, self.assertRaises(ValueError):
                    helper.watch(root, 42)
                rows.assert_not_called()
                sample.assert_not_called()

    def test_partial_pending_line_is_not_consumed_as_a_complete_query_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / 'ui-start.marker'
            marker.touch()
            os.utime(marker, (100.0, 100.0))
            (root / 'ui.log').write_text(event() + '\n' + PENDING)
            with mock.patch.object(helper.signal, 'signal'), \
                    mock.patch.object(helper.os, 'getppid', side_effect=[42, 0]), \
                    mock.patch.object(helper.time, 'monotonic', side_effect=[0.0, 15.0]), \
                    mock.patch.object(helper.time, 'sleep'), \
                    mock.patch.object(helper, 'sample_once') as sample:
                result = helper.watch(root, 42)
            self.assertEqual(result, {'status': 'watchStopped'})
            sample.assert_not_called()

    def test_main_never_prints_private_exception_or_native_sample_text(self):
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(helper.sys, 'platform', 'darwin'), \
                mock.patch.object(helper.sys, 'argv', ['helper', directory, '42']), \
                mock.patch.object(helper, 'watch', side_effect=ValueError(PRIVATE)), \
                contextlib.redirect_stdout(io.StringIO()) as output, \
                contextlib.redirect_stderr(io.StringIO()) as errors:
            helper.main()
        self.assertEqual(output.getvalue(), '::notice::Mac live sample: '
                         '{"failureKind": "valueInvalid", "stage": "arguments", "status": "diagnosticUnavailable"}\n')
        self.assertEqual(errors.getvalue(), '')


if __name__ == '__main__':
    unittest.main()
