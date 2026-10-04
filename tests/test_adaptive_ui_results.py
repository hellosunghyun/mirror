"""적응형 UI 게이트의 오수용·PNG 경계 회귀. GitHub Actions에서 실행한다."""

import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest import mock
import zlib

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('mirror_adaptive_results', ROOT / 'scripts/ci-adaptive-ui-results.py')
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
NOTICE_SPEC = importlib.util.spec_from_file_location('mirror_adaptive_sdk_notice', ROOT / 'scripts/ci-adaptive-ui-public-sdk-notice.py')
sdk_notice = importlib.util.module_from_spec(NOTICE_SPEC)
NOTICE_SPEC.loader.exec_module(sdk_notice)
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
    def test_checkout_checks_remain_ordered_and_each_git_call_is_bounded(self):
        expected = {'commitSHA': 'a' * 40}
        with mock.patch.object(helper.subprocess, 'check_output', side_effect=['a' * 40 + '\n', b'']) as output, \
                mock.patch.object(helper.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
            helper.checkout_matches(expected)
            self.assertEqual([call.args[0][1] for call in output.call_args_list], ['rev-parse', 'ls-files'])
            self.assertEqual(run.call_args.args[0],
                             ['git', '--no-optional-locks', 'diff', '--no-ext-diff', '--no-textconv', '--quiet', 'HEAD', '--'])
            self.assertTrue(all(call.kwargs['timeout'] == 5 for call in (*output.call_args_list, run.call_args)))
        for sha, dirty, untracked in (('b' * 40, 0, b''), ('a' * 40, 1, b''), ('a' * 40, 0, PRIVATE.encode())):
            with mock.patch.object(helper.subprocess, 'check_output', side_effect=[sha, untracked]), \
                    mock.patch.object(helper.subprocess, 'run', return_value=subprocess.CompletedProcess([], dirty)), \
                    self.assertRaises(helper.AdaptiveError):
                helper.checkout_matches(expected)

    def test_each_checkout_timeout_stops_before_later_git_checks(self):
        for stage in range(3):
            timeout = subprocess.TimeoutExpired(PRIVATE, 5, output=PRIVATE, stderr=PRIVATE)
            outputs = [timeout] if stage == 0 else ['a' * 40, timeout if stage == 2 else b'']
            with self.subTest(stage=stage), \
                    mock.patch.object(helper.subprocess, 'check_output', side_effect=outputs) as output, \
                    mock.patch.object(helper.subprocess, 'run', side_effect=timeout if stage == 1 else None,
                                      return_value=subprocess.CompletedProcess([], 0)) as run, \
                    self.assertRaises(subprocess.TimeoutExpired):
                helper.checkout_matches({'commitSHA': 'a' * 40})
            self.assertEqual(output.call_count, 2 if stage == 2 else 1)
            self.assertEqual(run.call_count, 0 if stage == 0 else 1)

    def checkout_repository_fixture(self, directory):
        repository = Path(directory) / 'repository'
        repository.mkdir()
        environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        environment.update({'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull,
                            'GIT_TERMINAL_PROMPT': '0'})

        def git(*arguments):
            return subprocess.run(['git', *arguments], cwd=repository, env=environment,
                                  check=True, capture_output=True, text=True, timeout=5)

        git('init', '--quiet', '--template=')
        git('config', 'user.name', 'Mirror CI Fixture')
        git('config', 'user.email', 'mirror-ci@example.invalid')
        git('config', 'commit.gpgsign', 'false')
        (repository / 'App').mkdir()
        (repository / 'App/Fixture.swift').write_text('fixture original\n')
        (repository / 'README.md').write_text('tracked fixture documentation\n')
        (repository / '.gitattributes').write_text('*.swift diff=mirrorfixture\n')
        git('add', '--all')
        git('commit', '--quiet', '-m', 'fixed checkout fixture')
        expected = {'commitSHA': git('rev-parse', 'HEAD').stdout.strip()}
        return repository, expected, environment, git

    def test_checkout_real_repository_preserves_clean_stat_only_and_all_tracked_guards(self):
        with tempfile.TemporaryDirectory() as directory:
            repository, expected, environment, git = self.checkout_repository_fixture(directory)
            with mock.patch.object(helper, 'ROOT', repository), mock.patch.dict(os.environ, environment, clear=True):
                self.assertIsNone(helper.checkout_matches(expected))
                tracked = repository / 'App/Fixture.swift'
                before = tracked.stat()
                os.utime(tracked, ns=(before.st_atime_ns, before.st_mtime_ns + 2_000_000_000))
                self.assertIsNone(helper.checkout_matches(expected))
                for path in ('App/Fixture.swift', 'README.md'):
                    for staged in (False, True):
                        with self.subTest(path=path, staged=staged):
                            git('reset', '--hard', 'HEAD')
                            (repository / path).write_text('changed tracked fixture\n')
                            if staged:
                                git('add', '--', path)
                            with self.assertRaisesRegex(helper.AdaptiveError, '^modifiedCheckout$'):
                                helper.checkout_matches(expected)
                git('reset', '--hard', 'HEAD')
                with self.assertRaisesRegex(helper.AdaptiveError, '^checkoutSHAMismatch$'):
                    helper.checkout_matches({'commitSHA': '0' * 40})
                (repository / 'App/Untracked.swift').write_text('untracked fixture\n')
                with self.assertRaisesRegex(helper.AdaptiveError, '^untrackedAppSource$'):
                    helper.checkout_matches(expected)

    def test_checkout_real_repository_does_not_run_external_diff_or_textconv(self):
        for mode in ('external', 'textconv', 'both'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                repository, expected, environment, git = self.checkout_repository_fixture(directory)
                marker = Path(directory) / 'unexpected-conversion'
                command = Path(directory) / 'fixed conversion.sh'
                command.write_text('#!/bin/sh\nprintf invoked > "$MIRROR_CHECKOUT_TEST_MARKER"\nprintf "same fixture conversion\\n"\n')
                command.chmod(0o700)
                environment['MIRROR_CHECKOUT_TEST_MARKER'] = str(marker)
                if mode in ('external', 'both'):
                    git('config', 'diff.external', shlex.quote(str(command)))
                    git('config', 'diff.trustExitCode', 'true')
                if mode in ('textconv', 'both'):
                    git('config', 'diff.mirrorfixture.textconv', shlex.quote(str(command)))
                with mock.patch.object(helper, 'ROOT', repository), mock.patch.dict(os.environ, environment, clear=True):
                    self.assertIsNone(helper.checkout_matches(expected))
                    self.assertFalse(marker.exists())
                    (repository / 'App/Fixture.swift').write_text('changed despite configured conversion\n')
                    for staged in (False, True):
                        if staged:
                            git('add', '--', 'App/Fixture.swift')
                        with self.assertRaisesRegex(helper.AdaptiveError, '^modifiedCheckout$'):
                            helper.checkout_matches(expected)
                        self.assertFalse(marker.exists())
                # 명시적으로 허용한 대조 호출은 같은 고정 도구를 실제로 실행한다.
                if mode == 'external':
                    git('diff', '--ext-diff', '--no-textconv', 'HEAD', '--')
                else:
                    git('diff', '--no-ext-diff', '--textconv', 'HEAD', '--')
                self.assertTrue(marker.exists())

    def processing_failure(self, action):
        with mock.patch.object(helper, 'main', side_effect=action), \
                mock.patch('builtins.print') as printed, self.assertRaises(SystemExit) as failed:
            helper.cli()
        self.assertEqual(failed.exception.code, 1)
        self.assertEqual(len(printed.call_args_list), 2)
        self.assertEqual(printed.call_args_list[0].args, ('::error::adaptiveProcessingFailed',))
        self.assertTrue(all(call.kwargs['file'] is helper.sys.stderr for call in printed.call_args_list))
        notice = printed.call_args_list[1]
        self.assertIs(notice.kwargs['flush'], True)
        prefix = '::notice::Adaptive UI processing failure: '
        self.assertTrue(notice.args[0].startswith(prefix))
        self.assertNotIn(PRIVATE, '\n'.join(call.args[0] for call in printed.call_args_list))
        payload = json.loads(notice.args[0][len(prefix):])
        self.assertEqual(set(payload), {'exceptionKind', 'operation'})
        return payload

    def test_cli_checkout_timeouts_identify_only_the_exact_failed_operation(self):
        for stage, operation in enumerate(('head', 'diff', 'untracked')):
            calls = []

            def git_command(command, **kwargs):
                calls.append((command, kwargs))
                if len(calls) == stage + 1:
                    raise subprocess.TimeoutExpired(command, 5, output=PRIVATE, stderr=PRIVATE)
                if command[1] == 'rev-parse':
                    return 'a' * 40 + '\n'
                return subprocess.CompletedProcess(command, 0)

            with self.subTest(operation=operation), \
                    mock.patch.object(helper.subprocess, 'check_output', side_effect=git_command), \
                    mock.patch.object(helper.subprocess, 'run', side_effect=git_command):
                payload = self.processing_failure(lambda: helper.checkout_matches({'commitSHA': 'a' * 40}))
            self.assertEqual(payload, {'exceptionKind': 'timeout', 'operation': operation})
            self.assertEqual(len(calls), stage + 1)
            self.assertTrue(all(kwargs['timeout'] == 5 for _, kwargs in calls))

    def test_cli_processing_failures_classify_without_rendering_private_exception_data(self):
        class OpaqueValueError(ValueError):
            def __str__(self):
                raise AssertionError('exception text must not be read')

        errors = (
            (subprocess.CalledProcessError(1, ['git', 'rev-parse', 'HEAD'],
                                           output=PRIVATE, stderr=PRIVATE), 'commandFailed'),
            (FileNotFoundError(2, PRIVATE, '/private/' + PRIVATE), 'fileNotFound'),
            (PermissionError(13, PRIVATE, '/private/' + PRIVATE), 'permissionDenied'),
            (json.JSONDecodeError(PRIVATE, PRIVATE, 0), 'invalidJSON'),
            (UnicodeDecodeError('utf-8', PRIVATE.encode(), 0, 1, PRIVATE), 'invalidEncoding'),
            (struct.error(PRIVATE), 'invalidFormat'),
            (helper.plistlib.InvalidFileException(PRIVATE), 'invalidFormat'),
            (zlib.error(PRIVATE), 'invalidFormat'),
            (OpaqueValueError(PRIVATE), 'invalidValue'),
            (TypeError(PRIVATE), 'invalidType'),
            (KeyError(PRIVATE), 'missingKey'),
            (AttributeError(PRIVATE), 'missingAttribute'),
            (RecursionError(PRIVATE), 'recursionLimit'),
            (OSError(5, PRIVATE, '/private/' + PRIVATE), 'osError'),
            (subprocess.SubprocessError(PRIVATE), 'subprocessError'),
        )
        for error, kind in errors:
            with self.subTest(kind=kind):
                self.assertEqual(self.processing_failure(error),
                                 {'exceptionKind': kind, 'operation': 'unknown'})

    def test_cli_timeout_commands_require_complete_plain_checkout_argv(self):
        class OpaqueCommand:
            def __str__(self):
                raise AssertionError('command text must not be read')

        commands = (PRIVATE, 'git rev-parse HEAD', ['/usr/bin/git', 'rev-parse', 'HEAD'],
                    ['git', 'rev-parse', 'HEAD', PRIVATE], ['git', 'rev-parse', PRIVATE],
                    [b'git', 'rev-parse', 'HEAD'], ['git', ['rev-parse'], 'HEAD'],
                    ['git', 'diff', '--quiet', 'HEAD', '--'],
                    ['git', '--no-optional-locks', 'diff', '--no-ext-diff', '--quiet', 'HEAD', '--'],
                    ['git', '--no-optional-locks', 'diff', '--no-textconv', '--no-ext-diff', '--quiet', 'HEAD', '--'],
                    ['git', '--no-optional-locks', 'diff', '--no-ext-diff', '--no-textconv', '--quiet', 'HEAD', PRIVATE],
                    OpaqueCommand(), None)
        for command in commands:
            error = subprocess.TimeoutExpired(command, 5, output=PRIVATE, stderr=PRIVATE)
            self.assertEqual(self.processing_failure(error),
                             {'exceptionKind': 'timeout', 'operation': 'unknown'})

    def test_cli_keeps_success_expected_rejection_and_uncaught_exception_contracts(self):
        with mock.patch.object(helper, 'main') as main, mock.patch('builtins.print') as printed:
            self.assertIsNone(helper.cli())
            main.assert_called_once_with()
            printed.assert_not_called()
        with mock.patch.object(helper, 'main', side_effect=helper.AdaptiveError('checkoutSHAMismatch')), \
                mock.patch('builtins.print') as printed, self.assertRaises(SystemExit) as failed:
            helper.cli()
        self.assertEqual(failed.exception.code, 1)
        printed.assert_called_once_with('::error::checkoutSHAMismatch', file=helper.sys.stderr)
        unexpected = RuntimeError(PRIVATE)
        with mock.patch.object(helper, 'main', side_effect=unexpected), \
                mock.patch('builtins.print') as printed, self.assertRaises(RuntimeError) as failed:
            helper.cli()
        self.assertIs(failed.exception, unexpected)
        printed.assert_not_called()

    def compiler_fixture(self, directory):
        root = Path(directory).resolve()
        path = root / 'App/Synthetic.swift'
        path.parent.mkdir()
        path.write_text(('let value = 1 // synthetic compile diagnostic source\n') * 30)
        return root, path

    def test_compiler_diagnostics_emit_only_verified_location_and_fixed_kind(self):
        with tempfile.TemporaryDirectory() as directory:
            root, path = self.compiler_fixture(directory)
            messages = ("call can throw but is not marked with 'try'",
                        "variable 'self." + PRIVATE + "' used before being initialized",
                        "immutable value 'self." + PRIVATE + "' may only be initialized once",
                        'unknown compiler message containing ' + PRIVATE)
            log = '\n'.join(str(path) + ':' + str(index) + ':5: error: ' + message
                            for index, message in enumerate(messages, 1))
            reports = helper.compiler_diagnostics(log, root)
            self.assertEqual(reports, [{'file': 'App/Synthetic.swift', 'line': index, 'column': 5, 'kind': kind}
                for index, kind in enumerate(('missingTry', 'usedBeforeInitialization',
                                              'immutableInitializedTwice', 'unknownCompilerError'), 1)])
            serialized = json.dumps(reports)
            self.assertNotIn(PRIVATE, serialized)
            self.assertNotIn(str(root), serialized)
            self.assertNotIn('message', serialized)

    def test_compiler_diagnostics_reject_wrong_missing_traversal_and_symlink_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root, path = self.compiler_fixture(directory)
            (root / 'App/Link.swift').symlink_to(path)
            paths = ('/private/App/Synthetic.swift', 'App/../App/Synthetic.swift', 'App//Synthetic.swift',
                     'App/Missing.swift', 'Extensions/Synthetic.swift', 'App/Link.swift',
                     'prefix ' + str(path), 'App/Synthetic.swift/' + PRIVATE)
            log = '\n'.join(value + ':1:5: error: ' + PRIVATE for value in paths)
            self.assertEqual(helper.compiler_diagnostics(log, root), [])
            self.assertEqual(helper.compiler_diagnostics('App/Synthetic.swift:1:5: error: ' + PRIVATE, root),
                             [{'file': 'App/Synthetic.swift', 'line': 1, 'column': 5, 'kind': 'unknownCompilerError'}])

    def test_compiler_diagnostics_bound_coordinates_count_and_deduplicate(self):
        with tempfile.TemporaryDirectory() as directory:
            root, _ = self.compiler_fixture(directory)
            invalid = '\n'.join('App/Synthetic.swift:' + coordinates + ': error: ' + PRIVATE
                                for coordinates in ('0:5', '100001:5', '1:0', '1:100001', '29:999', '32:1'))
            self.assertEqual(helper.compiler_diagnostics(invalid, root), [])
            lines = ['App/Synthetic.swift:' + str(index) + ':5: error: ' + PRIVATE for index in range(1, 20)]
            reports = helper.compiler_diagnostics('\n'.join(value for line in lines for value in (line, line)), root)
            self.assertEqual(len(reports), 12)
            self.assertEqual([report['line'] for report in reports], list(range(1, 13)))
            with mock.patch.object(helper, 'MAX_LOG', 32), self.assertRaises(helper.AdaptiveError):
                helper.compiler_diagnostics('x' * 33, root)

    def test_compiler_diagnostics_regular_log_and_context_are_required_before_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root, _ = self.compiler_fixture(directory)
            (root / 'build.log').write_text('App/Synthetic.swift:1:5: error: ' + PRIVATE)
            with mock.patch.object(helper, 'context_for', side_effect=helper.AdaptiveError('contextMismatch')), \
                    mock.patch.object(helper, 'read_regular') as read, self.assertRaises(helper.AdaptiveError):
                helper.diagnostics(root, EXPECTED)
            read.assert_not_called()
            (root / 'link.log').symlink_to(root / 'build.log')
            with self.assertRaises(OSError):
                helper.read_regular(root / 'link.log', helper.MAX_LOG)
            with self.assertRaises(helper.AdaptiveError):
                helper.read_regular(root / 'build.log', 1)

    def xctest_fixture(self, directory):
        root = Path(directory).resolve()
        path = root / 'Tests/MirrorAdaptiveUITests/MirrorAdaptiveUITests.swift'
        path.parent.mkdir(parents=True)
        path.write_text(('let value = 1 // synthetic XCTest diagnostic source\n') * 30)
        return root, path

    def xctest_row(self, path, line=1, column=5, owner=BUNDLE + '.MirrorAdaptiveUITests',
                   case=CASE, payload='XCTAssertEqual failed: ' + PRIVATE):
        coordinates = str(line) + (':' + str(column) if column is not None else '')
        return str(path) + ':' + coordinates + ': error: -[' + owner + ' ' + case + '] : ' + payload

    def test_xctest_diagnostics_emit_only_verified_coordinates_and_fixed_assertion_kinds(self):
        with tempfile.TemporaryDirectory() as directory:
            root, path = self.xctest_fixture(directory)
            rows = (self.xctest_row(path),
                    self.xctest_row(helper.UI_FAILURE_SOURCE_FILE, 2, None, payload='failed - ' + PRIVATE),
                    self.xctest_row(path, 3, 7, payload='XCTAssert' + PRIVATE + ' failed: ' + PRIVATE))
            log = '\n'.join((event(), *rows, event(state='failed')))
            expected = [
                {'scope': 'stdoutOnly', 'method': CASE, 'sourceFile': helper.UI_FAILURE_SOURCE_FILE,
                 'line': 1, 'column': 5, 'assertionKind': 'XCTAssertEqual'},
                {'scope': 'stdoutOnly', 'method': CASE, 'sourceFile': helper.UI_FAILURE_SOURCE_FILE,
                 'line': 2, 'assertionKind': 'XCTFail'},
                {'scope': 'stdoutOnly', 'method': CASE, 'sourceFile': helper.UI_FAILURE_SOURCE_FILE,
                 'line': 3, 'column': 7, 'failureKind': 'unclassified'},
            ]
            reports = helper.xctest_failure_diagnostics(log, EXPECTED, root)
            self.assertEqual(reports, expected)
            self.assertEqual(helper.xctest_failure_diagnostics(log.replace('-[', '+['), EXPECTED, root), expected)
            serialized = json.dumps(reports)
            for forbidden in (PRIVATE, str(root), 'unknown XCTest', 'message', 'payload'):
                self.assertNotIn(forbidden, serialized)

    def test_xctest_diagnostics_require_the_exact_platform_bundle_and_case_allowlist(self):
        with tempfile.TemporaryDirectory() as directory:
            root, path = self.xctest_fixture(directory)
            owner = 'MirrorMacAdaptiveUITests.MirrorAdaptiveUITests'
            row = self.xctest_row(path, owner=owner, case=helper.NARROW)
            log = '\n'.join((event(helper.NARROW, owner), row, event(helper.NARROW, owner, 'failed')))
            reports = helper.xctest_failure_diagnostics(log, {'platform': 'macos', 'appearance': 'dark'}, root)
            self.assertEqual(len(reports), 1)
            self.assertEqual(reports[0]['method'], helper.NARROW)
            self.assertEqual(helper.xctest_failure_diagnostics(log, EXPECTED, root), [])
            mobile_log = log.replace('MirrorMacAdaptiveUITests', BUNDLE)
            self.assertEqual(helper.xctest_failure_diagnostics(mobile_log, EXPECTED, root), [])
            common = '\n'.join((event(), self.xctest_row(path), event(state='failed')))
            self.assertEqual(len(helper.xctest_failure_diagnostics(common, {'platform': 'ipad', 'appearance': 'dark'}, root)), 1)

    def test_lookup_failure_reasons_emit_only_owned_fixed_reason_without_private_suffix(self):
        with tempfile.TemporaryDirectory() as directory:
            root, path = self.xctest_fixture(directory)
            contexts = ((EXPECTED, BUNDLE + '.MirrorAdaptiveUITests', CASE),
                        ({'platform': 'macos', 'appearance': 'dark'},
                         'MirrorMacAdaptiveUITests.MirrorAdaptiveUITests', helper.NARROW))
            for expected, owner, case in contexts:
                for reason in ('missing', 'nonUnique'):
                    for suffix in ('', ' /private/' + PRIVATE + ' AX label=' + PRIVATE,
                                   '\t' + PRIVATE):
                        with self.subTest(platform=expected['platform'], reason=reason, suffix=bool(suffix)):
                            payload = 'failed - Adaptive UI lookup failure: ' + reason + suffix
                            row = self.xctest_row(path, owner=owner, case=case, payload=payload)
                            log = '\n'.join((event(case, owner), row, event(case, owner, 'failed')))
                            reports = helper.xctest_failure_diagnostics(log, expected, root)
                            self.assertEqual(reports, [{
                                'scope': 'stdoutOnly', 'method': case, 'sourceFile': helper.UI_FAILURE_SOURCE_FILE,
                                'line': 1, 'column': 5, 'assertionKind': 'XCTFail', 'lookupFailureReason': reason,
                            }])
                            serialized = json.dumps(reports)
                            for forbidden in (PRIVATE, str(root), '/private/', 'AX label=',
                                              'Adaptive UI lookup failure:', 'payload', 'message'):
                                self.assertNotIn(forbidden, serialized)

    def test_lookup_failure_reasons_do_not_guess_unknown_embedded_sdk_or_other_assertion_messages(self):
        with tempfile.TemporaryDirectory() as directory:
            root, path = self.xctest_fixture(directory)
            payloads = (
                'failed - Adaptive UI lookup failure: unknown ' + PRIVATE,
                'failed - Adaptive UI lookup failure: Missing ' + PRIVATE,
                'failed - Adaptive UI lookup failure: nonunique ' + PRIVATE,
                'failed - Adaptive UI lookup failure: missingSuffix ' + PRIVATE,
                'failed - Adaptive UI lookup failure: nonUniqueSuffix ' + PRIVATE,
                'failed - Adaptive UI lookup failure: missing:' + PRIVATE,
                'failed - Adaptive UI lookup failure:  missing ' + PRIVATE,
                'failed - prefix Adaptive UI lookup failure: missing ' + PRIVATE,
                'failed - No matches found for SDK query ' + PRIVATE,
                'failed - Multiple matching elements found ' + PRIVATE,
                'XCTAssertTrue failed - Adaptive UI lookup failure: missing ' + PRIVATE,
                'XCTAssertEqual failed: Adaptive UI lookup failure: nonUnique ' + PRIVATE,
                'Adaptive UI lookup failure: missing ' + PRIVATE,
                'Caught error: Adaptive UI lookup failure: nonUnique ' + PRIVATE,
            )
            for payload in payloads:
                with self.subTest(payload=payload):
                    log = '\n'.join((event(), self.xctest_row(path, payload=payload), event(state='failed')))
                    reports = helper.xctest_failure_diagnostics(log, EXPECTED, root)
                    self.assertEqual(len(reports), 1)
                    self.assertNotIn('lookupFailureReason', reports[0])
                    self.assertNotIn(PRIVATE, json.dumps(reports))

    def test_lookup_failure_reasons_require_verified_source_and_explicit_matching_case(self):
        with tempfile.TemporaryDirectory() as directory:
            root, path = self.xctest_fixture(directory)
            link = path.parent / 'Link.swift'
            link.symlink_to(path)
            payload = 'failed - Adaptive UI lookup failure: missing ' + PRIVATE
            rows = (
                self.xctest_row('/private/' + helper.UI_FAILURE_SOURCE_FILE, payload=payload),
                self.xctest_row('Tests/../' + helper.UI_FAILURE_SOURCE_FILE, payload=payload),
                self.xctest_row(link, payload=payload),
                self.xctest_row(path, line=31, payload=payload),
                self.xctest_row(path, owner='MirrorMacAdaptiveUITests.MirrorAdaptiveUITests', payload=payload),
                self.xctest_row(path, case='testMaximumTypeReviewAndWeekPicker', payload=payload),
                self.xctest_row(path, case='test' + PRIVATE, payload=payload),
                str(path) + ':1:5: error: ' + payload,
                payload,
            )
            for row in rows:
                with self.subTest(row=row):
                    log = '\n'.join((event(), row, event(state='failed')))
                    self.assertEqual(helper.xctest_failure_diagnostics(log, EXPECTED, root), [])

    def test_lookup_failure_reasons_still_require_failed_terminal_and_unambiguous_event_stream(self):
        with tempfile.TemporaryDirectory() as directory:
            root, path = self.xctest_fixture(directory)
            row = self.xctest_row(path, payload='failed - Adaptive UI lookup failure: nonUnique ' + PRIVATE)
            good = (event(), row, event(state='failed'))
            for rows in ((event(), row), (event(), row, event(state='passed')),
                         (event(), row, event(state='skipped')), (row, event(), event(state='failed')),
                         (event(), event(state='failed'), row), (*good, *good), (*good, event())):
                with self.subTest(rows=rows):
                    self.assertEqual(helper.xctest_failure_diagnostics('\n'.join(rows), EXPECTED, root), [])

    def test_xctest_diagnostics_require_observed_failed_terminal_for_the_same_instance(self):
        with tempfile.TemporaryDirectory() as directory:
            root, path = self.xctest_fixture(directory)
            row = self.xctest_row(path)
            for lines in ((event(), row), (event(), row, event(state='passed')),
                          (event(), row, event(state='skipped')), (row, event(), event(state='failed')),
                          (event(), event(state='failed'), row)):
                with self.subTest(lines=lines):
                    self.assertEqual(helper.xctest_failure_diagnostics('\n'.join(lines), EXPECTED, root), [])

    def test_xctest_diagnostics_reject_ambiguous_duplicate_foreign_and_silent_events(self):
        with tempfile.TemporaryDirectory() as directory:
            root, path = self.xctest_fixture(directory)
            row = self.xctest_row(path)
            good = (event(), row, event(state='failed'))
            other = 'testMaximumTypeReviewAndWeekPicker'
            invalid = (
                (event(), event(), row, event(state='failed')),
                (*good, *good),
                (event(), event(other), row, event(state='failed')),
                (event(owner='MirrorIOSUITests.MirrorUITests'), row, event(state='failed')),
                (event(case='test' + PRIVATE), row, event(state='failed')),
                (event() + ' ' + event(state='failed'), row),
                (event(state='failed'), row),
                (*good, event(state='failed')),
                (*good, "Test Case '-[" + BUNDLE + '.MirrorAdaptiveUITests ' + CASE + "]' finished."),
                (*good, event(other)),
                (*good, event(owner='MirrorMacAdaptiveUITests.MirrorAdaptiveUITests')),
            )
            for lines in invalid:
                with self.subTest(lines=lines):
                    self.assertEqual(helper.xctest_failure_diagnostics('\n'.join(lines), EXPECTED, root), [])

    def test_xctest_diagnostics_reject_implicit_wrong_owner_and_unverified_source_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            root, path = self.xctest_fixture(directory)
            (path.parent / 'Link.swift').symlink_to(path)
            other = root / 'Tests/MirrorUITests/MirrorUITests.swift'
            other.parent.mkdir()
            other.write_text('let value = 1\n')
            paths = ('MirrorAdaptiveUITests.swift', '/private/' + helper.UI_FAILURE_SOURCE_FILE,
                     'Tests/../' + helper.UI_FAILURE_SOURCE_FILE, 'Tests//MirrorAdaptiveUITests/MirrorAdaptiveUITests.swift',
                     'Tests/MirrorAdaptiveUITests/Missing.swift', 'Tests/MirrorAdaptiveUITests/Link.swift',
                     str(other), 'prefix ' + str(path), str(path) + '/' + PRIVATE)
            rows = [self.xctest_row(value) for value in paths]
            rows.extend((self.xctest_row(path, owner='MirrorMacAdaptiveUITests.MirrorAdaptiveUITests'),
                         self.xctest_row(path, owner='MirrorAdaptiveUITests'),
                         self.xctest_row(path, case='test' + PRIVATE),
                         str(path) + ':1:5: error: XCTAssertEqual failed: ' + PRIVATE,
                         str(path) + ':1:5: error: -[malformed] : failed - ' + PRIVATE))
            log = '\n'.join((event(), *rows, event(state='failed')))
            self.assertEqual(helper.xctest_failure_diagnostics(log, EXPECTED, root), [])
            self.assertEqual(helper.xctest_failure_diagnostics(log, {'platform': 'macos', 'appearance': 'dark'}, root), [])

    def test_xctest_diagnostics_bound_actual_coordinates_unique_count_and_entire_event_stream(self):
        with tempfile.TemporaryDirectory() as directory:
            root, path = self.xctest_fixture(directory)
            invalid = [self.xctest_row(path, line, column) for line, column in
                       ((0, 5), (100001, 5), (1, 0), (1, 100001), (29, 999), (31, 1), (31, None))]
            self.assertEqual(helper.xctest_failure_diagnostics('\n'.join((event(), *invalid, event(state='failed'))),
                                                              EXPECTED, root), [])
            rows = [self.xctest_row(path, index) for index in range(1, 20)]
            log = '\n'.join((event(), *(row for row in rows for _ in range(2)), event(state='failed')))
            reports = helper.xctest_failure_diagnostics(log, EXPECTED, root)
            self.assertEqual(len(reports), 12)
            self.assertEqual([report['line'] for report in reports], list(range(1, 13)))
            self.assertEqual(helper.xctest_failure_diagnostics(log + '\n' + event(), EXPECTED, root), [])
            with mock.patch.object(helper, 'MAX_LOG', 32), self.assertRaises(helper.AdaptiveError):
                helper.xctest_failure_diagnostics('x' * 33, EXPECTED, root)

    def test_xctest_diagnostics_require_context_and_a_bounded_regular_test_log(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / 'test.log'
            log.write_text(PRIVATE)
            with mock.patch.object(helper, 'context_for', side_effect=helper.AdaptiveError('contextMismatch')), \
                    mock.patch.object(helper, 'read_regular') as read, self.assertRaises(helper.AdaptiveError):
                helper.test_diagnostics(root, EXPECTED)
            read.assert_not_called()
            with mock.patch.object(helper, 'context_for'), \
                    mock.patch.object(helper, 'xctest_failure_diagnostics', return_value=[]) as parse, \
                    mock.patch('builtins.print') as output:
                helper.test_diagnostics(root, EXPECTED)
            parse.assert_called_once_with(PRIVATE, EXPECTED)
            self.assertNotIn(PRIVATE, output.call_args[0][0])
            self.assertIn('noAcceptedXCTestFailureDiagnostics', output.call_args[0][0])
            target = root / 'original.log'
            log.rename(target)
            log.symlink_to(target)
            with mock.patch.object(helper, 'context_for'), self.assertRaises(OSError):
                helper.test_diagnostics(root, EXPECTED)
            log.unlink()
            log.write_text(PRIVATE)
            with mock.patch.object(helper, 'context_for'), mock.patch.object(helper, 'MAX_LOG', 1), \
                    self.assertRaises(helper.AdaptiveError):
                helper.test_diagnostics(root, EXPECTED)

    def progress_fixture(self):
        lines = ['import XCTest', '', 'final class MirrorAdaptiveUITests: XCTestCase {']
        for case in helper.CASES:
            lines.extend(('    @MainActor', '    func ' + case + '() throws {', '    }'))
        lines.append('}')
        source = '\n'.join(lines) + '\n'
        return source, helper.source_method_entries(source, 'iphone')

    def progress_row(self, case=CASE, phase='started', sequence=1, step=0, **extra):
        return helper.PROGRESS_MARKER + json.dumps({'method': case + '()', 'phase': phase,
                                                    'sequence': sequence, 'step': step, **extra})

    def test_progress_reports_observed_prefix_without_a_terminal_or_result_inference(self):
        _, entries = self.progress_fixture()
        log = '\n'.join((event(), self.progress_row(), self.progress_row(phase='launchComplete', sequence=2)))
        expected = {'method': CASE, 'sourceFile': helper.UI_FAILURE_SOURCE_FILE, 'entryLine': 5,
                    'phase': 'launchComplete', 'sequence': 2, 'step': 0}
        self.assertEqual(helper.xctest_progress_diagnostics(log, EXPECTED, entries), expected)
        for state in ('passed', 'failed', 'skipped'):
            report = helper.xctest_progress_diagnostics(log + '\n' + event(state=state), EXPECTED, entries)
            self.assertEqual(report, expected)
            self.assertNotIn(state, json.dumps(report))
        start = helper.xctest_progress_diagnostics(event(), EXPECTED, entries)
        self.assertEqual(start, {'method': CASE, 'sourceFile': helper.UI_FAILURE_SOURCE_FILE, 'entryLine': 5})
        self.assertEqual(helper.xctest_progress_diagnostics(log.replace('-[', '+['), EXPECTED, entries), expected)
        other = 'testMaximumTypeReviewAndWeekPicker'
        switched = '\n'.join((log, event(state='failed'), event(other), self.progress_row(other)))
        self.assertEqual(helper.xctest_progress_diagnostics(switched, EXPECTED, entries),
                         {'method': other, 'sourceFile': helper.UI_FAILURE_SOURCE_FILE, 'entryLine': 8,
                          'phase': 'started', 'sequence': 1, 'step': 0})

    def test_progress_accepts_only_the_fixed_contiguous_per_method_phase_and_step_prefix(self):
        source, _ = self.progress_fixture()
        mac = {'platform': 'macos', 'appearance': 'dark'}
        entries = helper.source_method_entries(source, 'macos')
        owner = 'MirrorMacAdaptiveUITests.MirrorAdaptiveUITests'
        for case in helper.required_cases('macos'):
            rows = [event(case, owner)]
            for sequence, (phase, step) in enumerate(helper.PROGRESS_PROTOCOL[case], 1):
                rows.append(self.progress_row(case, phase, sequence, step))
                report = helper.xctest_progress_diagnostics('\n'.join(rows), mac, entries)
                self.assertEqual((report['method'], report['phase'], report['sequence'], report['step']),
                                 (case, phase, sequence, step))
        review = 'testMaximumTypeReviewAndWeekPicker'
        rows = [event(review)] + [self.progress_row(review, phase, sequence, step)
            for sequence, (phase, step) in enumerate(helper.PROGRESS_PROTOCOL[review][:11], 1)]
        for phase, step in (('weekDayStarted', 4), ('weekDayVerified', 5), ('weekDayStarted', 6)):
            with self.subTest(phase=phase, step=step):
                self.assertIsNone(helper.xctest_progress_diagnostics(
                    '\n'.join((*rows, self.progress_row(review, phase, 12, step))), EXPECTED,
                    helper.source_method_entries(source, 'iphone')))

    def test_progress_rejects_duplicate_reordered_foreign_malformed_and_noninteger_markers(self):
        _, entries = self.progress_fixture()
        start = (event(), self.progress_row())
        invalid = (
            (*start, self.progress_row()),
            (*start, self.progress_row(phase='captureOpenStarted', sequence=2)),
            (*start, self.progress_row(phase='launchComplete', sequence=3)),
            (*start, self.progress_row(phase='launchComplete', sequence=True)),
            (*start, self.progress_row(phase='launchComplete', sequence=2, step=False)),
            (*start, self.progress_row(phase=PRIVATE, sequence=2)),
            (*start, self.progress_row(case='test' + PRIVATE, phase='launchComplete', sequence=2)),
            (*start, self.progress_row(phase='launchComplete', sequence=2, private=PRIVATE)),
            (*start, helper.PROGRESS_MARKER + '{"method":"' + CASE + '()","phase":"started",'
             '"sequence":2,"sequence":1,"step":0}'),
            (*start, helper.PROGRESS_MARKER + PRIVATE),
            (*start, 'prefix ' + self.progress_row(phase='launchComplete', sequence=2)),
            (*start, 'UI adaptive progress ' + PRIVATE),
            (self.progress_row(),),
            (*start, event(state='failed'), self.progress_row(phase='launchComplete', sequence=2)),
        )
        for lines in invalid:
            with self.subTest(lines=lines):
                self.assertIsNone(helper.xctest_progress_diagnostics('\n'.join(lines), EXPECTED, entries))

    def test_progress_rejects_ambiguous_native_events_and_requires_the_strict_event_prefix(self):
        _, entries = self.progress_fixture()
        good = (event(), self.progress_row(), event(state='failed'))
        other = 'testMaximumTypeReviewAndWeekPicker'
        invalid = ((*good, event()), (event(), event(other)), (event(state='failed'),),
                   (event(owner='MirrorIOSUITests.MirrorUITests'), self.progress_row()),
                   (event(case='test' + PRIVATE),), ('prefix ' + event(),), (' ' + event(),),
                   (event() + ' ' + event(state='failed'),),
                   (*good, "Test Case '-[" + BUNDLE + '.MirrorAdaptiveUITests ' + CASE + "]' finished."))
        for lines in invalid:
            with self.subTest(lines=lines):
                self.assertIsNone(helper.xctest_progress_diagnostics('\n'.join(lines), EXPECTED, entries))
        with mock.patch.object(helper, 'MAX_LOG', 32), self.assertRaises(helper.AdaptiveError):
            helper.xctest_progress_diagnostics('x' * 33, EXPECTED, entries)

    def test_progress_entry_line_binds_current_method_declarations_and_rejects_missing_or_duplicate_source(self):
        source, entries = self.progress_fixture()
        self.assertEqual(entries[CASE], 5)
        for malformed in (source.replace('final class MirrorAdaptiveUITests: XCTestCase {', 'class Other {'),
                          source.replace('    func ' + CASE + '() throws {', '    func ' + CASE + '() {'),
                          source + '    func ' + CASE + '() throws {\n'):
            self.assertIsNone(helper.source_method_entries(malformed, 'iphone'))
        with self.assertRaises(helper.AdaptiveError):
            helper.xctest_progress_diagnostics(event(), EXPECTED, {CASE: True})

    def test_progress_always_emits_only_pinned_notice_when_context_log_or_source_is_unavailable(self):
        source, _ = self.progress_fixture()
        expected = {**EXPECTED, 'commitSHA': 'a' * 40, 'buildNumber': '12', 'runID': '34', 'runAttempt': '1'}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            path = root / helper.UI_FAILURE_SOURCE_FILE
            path.parent.mkdir(parents=True)
            path.write_text(source)
            with mock.patch.object(helper, 'context_for', side_effect=helper.AdaptiveError(PRIVATE)), \
                    mock.patch.object(helper, 'read_regular') as read, mock.patch('builtins.print') as output:
                helper.progress_diagnostics(root, expected)
            read.assert_not_called()
            self.assertIn('contextUnavailable', output.call_args[0][0])
            self.assertNotIn(PRIVATE, output.call_args[0][0])
            with mock.patch.object(helper, 'ROOT', root), mock.patch.object(helper, 'context_for'), \
                    mock.patch('builtins.print') as output:
                helper.progress_diagnostics(root, expected)
                self.assertIn('testLogUnavailable', output.call_args[0][0])
                (root / 'test.log').write_text('\n'.join((event(), self.progress_row())))
                helper.progress_diagnostics(root, expected)
                notice = output.call_args[0][0]
                self.assertIn('reachedCodeBoundaryOnly', notice)
                self.assertIn(expected['commitSHA'], notice)
                for forbidden in (str(root), PRIVATE, 'xcodebuildExitCode', 'passedTests', 'failedTests'):
                    self.assertNotIn(forbidden, notice)
                log = root / 'test.log'
                log.rename(root / 'original.log')
                log.symlink_to(root / 'original.log')
                helper.progress_diagnostics(root, expected)
                self.assertIn('testLogUnavailable', output.call_args[0][0])
                log.unlink()
                log.write_text(PRIVATE)
                with mock.patch.object(helper, 'MAX_LOG', 1):
                    helper.progress_diagnostics(root, expected)
                self.assertIn('testLogUnavailable', output.call_args[0][0])
                path.unlink()
                helper.progress_diagnostics(root, expected)
                self.assertIn('sourceUnavailable', output.call_args[0][0])

    def configuration_measurement_row(self, case=CASE, **changes):
        value = {'method': case + '()', 'valueKind': 'string', 'castKind': 'enum', 'castName': 'accessibility5',
                 'environmentKind': 'enum', 'environmentName': 'accessibility5', **changes}
        return helper.CONFIGURATION_MEASUREMENT_MARKER + json.dumps(value)

    def resize_measurement_row(self, **changes):
        value = {'method': helper.NARROW + '()', 'beforeFrame': [-20, 40, 1200, 800],
                 'observedFrame': [-20, 40, 780, 600], 'samples': 17,
                 'waitResult': 'timedOut', 'waitCompleted': False, **changes}
        return helper.RESIZE_MEASUREMENT_MARKER + json.dumps(value)

    def test_measurements_accept_only_fixed_categories_and_font_names_without_raw_text(self):
        _, entries = self.progress_fixture()
        variations = ({}, {'valueKind': 'nil', 'castKind': 'nil', 'castName': None,
                           'environmentKind': 'empty', 'environmentName': None},
                      {'environmentKind': 'unrecognized', 'environmentName': None},
                      {'valueKind': 'number', 'castKind': 'nil', 'castName': None},
                      {'valueKind': 'other', 'castKind': 'nil', 'castName': None},
                      {'castKind': 'empty', 'castName': None, 'environmentKind': 'unrecognized', 'environmentName': None},
                      {'castKind': 'otherString', 'castName': None})
        for changes in variations:
            log = '\n'.join((event(), self.configuration_measurement_row(**changes)))
            reports = helper.xctest_measurement_diagnostics(log, EXPECTED, entries)
            self.assertEqual(len(reports), 1)
            self.assertEqual((reports[0]['kind'], reports[0]['method'], reports[0]['entryLine']), ('configuration', CASE, 5))
            for key, value in changes.items():
                self.assertEqual(reports[0][key], value)
            self.assertNotIn(PRIVATE, json.dumps(reports))
        for name in ('xSmall', 'small', 'medium', 'large', 'xLarge', 'xxLarge', 'xxxLarge',
                     'accessibility1', 'accessibility2', 'accessibility3', 'accessibility4', 'accessibility5'):
            log = '\n'.join((event(), self.configuration_measurement_row(castName=name, environmentName=name)))
            self.assertEqual(helper.xctest_measurement_diagnostics(log, EXPECTED, entries)[0]['castName'], name)

    def test_measurements_reject_unknown_names_categories_keys_and_nonnull_unclassified_strings(self):
        _, entries = self.progress_fixture()
        invalid = ({'valueKind': PRIVATE}, {'castKind': PRIVATE}, {'castName': PRIVATE},
                   {'environmentKind': PRIVATE}, {'environmentName': PRIVATE},
                   {'castKind': 'otherString', 'castName': PRIVATE},
                   {'environmentKind': 'unrecognized', 'environmentName': PRIVATE},
                   {'castName': None}, {'castName': []}, {'environmentName': {}},
                   {'valueKind': False}, {'environmentKind': 'empty', 'environmentName': 'large'},
                   {'valueKind': 'string', 'castKind': 'nil', 'castName': None},
                   {'valueKind': 'nil'}, {'valueKind': 'number', 'castKind': 'empty', 'castName': None},
                   {'valueKind': 'other', 'castKind': 'otherString', 'castName': None},
                   {'private': PRIVATE}, {'method': 'test' + PRIVATE + '()'})
        for changes in invalid:
            with self.subTest(changes=changes):
                log = '\n'.join((event(), self.configuration_measurement_row(**changes), event(state='failed')))
                self.assertIsNone(helper.xctest_measurement_diagnostics(log, EXPECTED, entries))
        duplicate = helper.CONFIGURATION_MEASUREMENT_MARKER + ('{"method":"' + CASE + '()",'
                    '"valueKind":"string","valueKind":"nil","castKind":"nil","castName":null,'
                    '"environmentKind":"empty","environmentName":null}')
        self.assertIsNone(helper.xctest_measurement_diagnostics('\n'.join((event(), duplicate)), EXPECTED, entries))

    def test_measurements_require_unique_owned_native_instances_and_a_valid_progress_prefix(self):
        _, entries = self.progress_fixture()
        row = self.configuration_measurement_row()
        for state in ('passed', 'failed', 'skipped'):
            reports = helper.xctest_measurement_diagnostics('\n'.join((event(), row, event(state=state))), EXPECTED, entries)
            self.assertEqual(len(reports), 1)
            self.assertNotIn('nativeState', reports[0])
        invalid = ((row,), (event(state='failed'), row), (event(), row, row),
                   (event(), row, event(state='failed'), row),
                   (event(), row, event(state='failed'), event()),
                   (event(owner='MirrorIOSUITests.MirrorUITests'), row),
                   (event(), event('testMaximumTypeReviewAndWeekPicker'), row),
                   ('prefix ' + event(), row), (event(), 'prefix ' + row),
                   (event(), 'UI adaptive configuration measurement ' + PRIVATE),
                   (event() + ' ' + self.progress_row(), row),
                   (event() + ' UI adaptive progress: not-json', row),
                   (event() + ' ' + row, row),
                   (event() + ' UI adaptive configuration measurement: not-json', row),
                   (event() + ' ' + self.resize_measurement_row(), row),
                   (event() + ' UI adaptive resize measurement: not-json', row),
                   (event(), row, event(state='failed') + ' ' + row),
                   (event(), self.progress_row(), self.progress_row(), row),
                   (event(), self.resize_measurement_row(method=CASE + '()')))
        for lines in invalid:
            with self.subTest(lines=lines):
                self.assertIsNone(helper.xctest_measurement_diagnostics('\n'.join(lines), EXPECTED, entries))
        with mock.patch.object(helper, 'MAX_LOG', 32), self.assertRaises(helper.AdaptiveError):
            helper.xctest_measurement_diagnostics('x' * 33, EXPECTED, entries)

    def test_resize_measurements_preserve_finite_frames_sample_counts_and_observed_wait_result_only(self):
        source, _ = self.progress_fixture()
        expected = {'platform': 'macos', 'appearance': 'dark'}
        entries = helper.source_method_entries(source, 'macos')
        owner = 'MirrorMacAdaptiveUITests.MirrorAdaptiveUITests'
        for result in ('completed', 'timedOut', 'incorrectOrder', 'invertedFulfillment', 'interrupted'):
            row = self.resize_measurement_row(waitResult=result, waitCompleted=result == 'completed')
            log = '\n'.join((event(helper.NARROW, owner), row))
            reports = helper.xctest_measurement_diagnostics(log, expected, entries)
            self.assertEqual(reports[0]['beforeFrame'], [-20, 40, 1200, 800])
            self.assertEqual(reports[0]['observedFrame'], [-20, 40, 780, 600])
            self.assertEqual(reports[0]['samples'], 17)
            self.assertEqual(reports[0]['waitResult'], result)
        for changes in ({'samples': 0, 'observedFrame': None}, {'samples': 10_000, 'observedFrame': [0, -40, 0, 0]}):
            log = '\n'.join((event(helper.NARROW, owner), self.resize_measurement_row(**changes)))
            self.assertEqual(len(helper.xctest_measurement_diagnostics(log, expected, entries)), 1)
        rows = []
        for case in helper.required_cases('macos'):
            rows.append(event(case, owner))
            if case == helper.NARROW:
                rows.append(self.resize_measurement_row())
            rows.extend((self.configuration_measurement_row(case), event(case, owner, 'passed')))
        self.assertEqual(len(helper.xctest_measurement_diagnostics('\n'.join(rows), expected, entries)), 6)

    def test_resize_measurements_reject_invalid_frames_bounds_boolean_numbers_and_wait_inconsistency(self):
        source, _ = self.progress_fixture()
        expected = {'platform': 'macos', 'appearance': 'system'}
        entries = helper.source_method_entries(source, 'macos')
        owner = 'MirrorMacAdaptiveUITests.MirrorAdaptiveUITests'
        invalid = ({'beforeFrame': [0, 0, 0, 800]}, {'beforeFrame': [0, 0, -1, 800]},
                   {'beforeFrame': [False, 0, 1200, 800]}, {'beforeFrame': [0, 0, 1200]},
                   {'beforeFrame': [0, 0, '1200', 800]}, {'beforeFrame': [0, 0, 10 ** 500, 800]},
                   {'observedFrame': [0, 0, -1, 600]}, {'observedFrame': [0, 0, 780, float('inf')]},
                   {'observedFrame': None}, {'samples': 0}, {'samples': True}, {'samples': -1},
                   {'samples': 10_001}, {'waitResult': PRIVATE}, {'waitCompleted': True}, {'waitCompleted': 0},
                   {'private': PRIVATE}, {'method': CASE + '()'})
        for changes in invalid:
            with self.subTest(changes=changes):
                log = '\n'.join((event(helper.NARROW, owner), self.resize_measurement_row(**changes)))
                self.assertIsNone(helper.xctest_measurement_diagnostics(log, expected, entries))
        row = self.resize_measurement_row()
        self.assertIsNone(helper.xctest_measurement_diagnostics('\n'.join((event(helper.NARROW, owner), row, row)),
                                                              expected, entries))
        self.assertIsNone(helper.xctest_measurement_diagnostics('\n'.join((event(helper.NARROW, owner), row)),
                                                              EXPECTED, self.progress_fixture()[1]))

    def test_measurement_notices_preserve_pinned_context_and_reject_unsafe_or_missing_evidence(self):
        source, _ = self.progress_fixture()
        expected = {**EXPECTED, 'commitSHA': 'a' * 40, 'buildNumber': '12', 'runID': '34', 'runAttempt': '1'}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            path = root / helper.UI_FAILURE_SOURCE_FILE
            path.parent.mkdir(parents=True)
            path.write_text(source)
            with mock.patch.object(helper, 'context_for', side_effect=helper.AdaptiveError(PRIVATE)), \
                    mock.patch.object(helper, 'read_regular') as read, mock.patch('builtins.print') as output:
                helper.measurement_diagnostics(root, expected)
            read.assert_not_called()
            self.assertIn('contextUnavailable', output.call_args[0][0])
            self.assertNotIn(PRIVATE, output.call_args[0][0])
            with mock.patch.object(helper, 'ROOT', root), mock.patch.object(helper, 'context_for'), \
                    mock.patch('builtins.print') as output:
                helper.measurement_diagnostics(root, expected)
                self.assertIn('testLogUnavailable', output.call_args[0][0])
                log = root / 'test.log'
                log.write_text('\n'.join((event(), self.configuration_measurement_row())))
                helper.measurement_diagnostics(root, expected)
                notice = output.call_args[0][0]
                self.assertIn('observedMeasurementsOnly', notice)
                self.assertIn(expected['commitSHA'], notice)
                for forbidden in (str(root), PRIVATE, 'xcodebuildExitCode', 'passedTests', 'failedTests', 'message'):
                    self.assertNotIn(forbidden, notice)
                log.rename(root / 'original.log')
                log.symlink_to(root / 'original.log')
                helper.measurement_diagnostics(root, expected)
                self.assertIn('testLogUnavailable', output.call_args[0][0])
                log.unlink()
                log.write_text(PRIVATE)
                with mock.patch.object(helper, 'MAX_LOG', 1):
                    helper.measurement_diagnostics(root, expected)
                self.assertIn('testLogUnavailable', output.call_args[0][0])
                path.unlink()
                helper.measurement_diagnostics(root, expected)
                self.assertIn('sourceUnavailable', output.call_args[0][0])

    def test_shell_preserves_original_native_failure_even_when_diagnostics_fail(self):
        self.run_stubbed_shell('build', native=65, receipt=0, expected_exit=65, expected_diagnostics=True)

    def test_shell_does_not_diagnose_a_helper_failure_after_native_success(self):
        self.run_stubbed_shell('build', native=0, receipt=72, expected_exit=72, expected_diagnostics=False)

    def test_shell_preserves_original_native_failure_when_xctest_diagnostics_fail(self):
        self.run_stubbed_shell('test', native=65, receipt=0, expected_exit=65, expected_diagnostics=False,
                               expected_test_diagnostics=True)

    def test_dynamic_preboot_hook_precedes_build_and_preserves_native_or_preboot_failure(self):
        self.run_stubbed_shell('build', native=65, receipt=0, expected_exit=65, expected_diagnostics=True,
                               platform='ipad', preboot='1', expected_preboot=True)
        self.run_stubbed_shell('build', native=65, receipt=0, expected_exit=73, expected_diagnostics=False,
                               platform='ipad', preboot='1', preboot_exit=73, expected_preboot=True,
                               expected_native_called=False)
        self.run_stubbed_shell('build', native=65, receipt=0, expected_exit=2, expected_diagnostics=False,
                               platform='iphone', preboot='1', expected_native_called=False)

    def run_stubbed_shell(self, mode, native, receipt, expected_exit, expected_diagnostics,
                          expected_test_diagnostics=False, platform='iphone', preboot='', preboot_exit=0,
                          expected_preboot=False, expected_native_called=True):
        # 실제 shell을 격리된 복사본에서 실행하고 모든 Python/Xcode 경계를 stub한다.
        # SDK·앱·네트워크를 실행하지 않고 EXIT trap의 원래 종료 코드 보존을 검증한다.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            (root / 'bin').mkdir()
            (root / ('.build/ci-adaptive-ui/' + platform + '-system')).mkdir(parents=True)
            script = root / 'scripts/ci-adaptive-ui.sh'
            shutil.copyfile(ROOT / 'scripts/ci-adaptive-ui.sh', script)
            python = root / 'bin/python3'
            python.write_text('''#!/bin/bash
printf '%s\\n' "$2" >> "$ADAPTIVE_STUB_EVENTS"
case "$2" in
  context) printf 'MirrorIOSAdaptiveUI\\tiphonesimulator\\tplatform=iOS Simulator,id=11111111-1111-1111-1111-111111111111\\n' ;;
  diagnostics) exit 73 ;;
  test-diagnostics) exit 75 ;;
  preboot) exit "$ADAPTIVE_STUB_PREBOOT" ;;
  receipt-record) exit "$ADAPTIVE_STUB_RECEIPT" ;;
  failure) printf '%s\\n' "$*" >> "$ADAPTIVE_STUB_FAILURE"; exit 74 ;;
esac
''')
            xcode = root / 'bin/xcodebuild'
            xcode.write_text('#!/bin/bash\nprintf "%s\\n" xcodebuild >> "$ADAPTIVE_STUB_EVENTS"\nexit "$ADAPTIVE_STUB_NATIVE"\n')
            python.chmod(0o700)
            xcode.chmod(0o700)
            environment = {**os.environ, 'GITHUB_ACTIONS': 'true', 'GITHUB_RUN_NUMBER': '1',
                           'GITHUB_OUTPUT': str(root / 'output'), 'PATH': str(root / 'bin') + os.pathsep + os.environ['PATH'],
                           'ADAPTIVE_STUB_EVENTS': str(root / 'events'), 'ADAPTIVE_STUB_FAILURE': str(root / 'failure'),
                           'ADAPTIVE_STUB_NATIVE': str(native), 'ADAPTIVE_STUB_RECEIPT': str(receipt),
                           'MIRROR_DYNAMIC_TYPE_PREBOOT': preboot, 'ADAPTIVE_STUB_PREBOOT': str(preboot_exit)}
            result = subprocess.run(['bash', str(script), platform, 'system', mode], env=environment,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)
            self.assertEqual(result.returncode, expected_exit)
            events = (root / 'events').read_text().splitlines()
            self.assertEqual(events.count('diagnostics'), int(expected_diagnostics))
            self.assertEqual(events.count('test-diagnostics'), int(expected_test_diagnostics))
            self.assertEqual(events.count('preboot'), int(expected_preboot))
            self.assertEqual(events.count('xcodebuild'), int(expected_native_called))
            if expected_preboot:
                self.assertLess(events.index('context'), events.index('preboot'))
                if expected_native_called:
                    self.assertLess(events.index('preboot'), events.index('xcodebuild'))
            if expected_diagnostics:
                self.assertLess(events.index('diagnostics'), events.index('failure'))
            if expected_test_diagnostics:
                self.assertLess(events.index('test-diagnostics'), events.index('failure'))
            failure = (root / 'failure').read_text()
            self.assertIn('--exit-code ' + str(expected_exit), failure)
            self.assertIn('--native-exit-code ' + str(native if expected_native_called else -1), failure)

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
        for key, value in (('runID', '33'), ('status', PRIVATE), ('xcodebuildExitCode', 65), ('xcodebuildExitCode', None),
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

    def case_diagnostic_row(self, case=CASE, sequence=0, element=None, **extra):
        return helper.CASE_DIAGNOSTIC_MARKER + json.dumps(
            {'schemaVersion': 1, 'case': helper.CASE_DIAGNOSTIC_NAMES[case],
             'requestSequence': sequence, 'requestedElement': element, **extra})

    def audit_boundary_row(self, case=CASE, sequence=1, outcome='returned', **extra):
        return helper.AUDIT_BOUNDARY_MARKER + json.dumps(
            {'schemaVersion': 1, 'case': helper.CASE_DIAGNOSTIC_NAMES[case],
             'auditSequence': sequence, 'outcome': outcome, **extra})

    def case_protocol_rows(self, case=CASE, platform='iphone', outcome='returned'):
        owner = ('MirrorMacAdaptiveUITests' if platform == 'macos' else BUNDLE) + '.MirrorAdaptiveUITests'
        rows = [event(case, owner), self.case_diagnostic_row(case)]
        for sequence, (phase, step) in enumerate(helper.PROGRESS_PROTOCOL[case], 1):
            rows.append(self.progress_row(case, phase, sequence, step))
            if phase == 'auditStarted':
                rows.append(self.audit_boundary_row(case, step, outcome))
                if outcome == 'threw':
                    break
        return rows

    def test_case_diagnostics_preserve_four_failed_case_requests_after_narrow_starts(self):
        source, _ = self.progress_fixture()
        entries = helper.source_method_entries(source, 'macos')
        expected = {'platform': 'macos', 'appearance': 'system'}
        owner = 'MirrorMacAdaptiveUITests.MirrorAdaptiveUITests'
        rows = []
        common = list(helper.required_cases('macos'))
        for case in [case for case in common if case != helper.NARROW]:
            rows.extend((event(case, owner), self.case_diagnostic_row(case), self.progress_row(case),
                         self.progress_row(case, 'launchComplete', 2),
                         self.case_diagnostic_row(case, 1, 'captureOpen'), event(case, owner, 'failed')))
        rows.extend((event(helper.NARROW, owner), self.case_diagnostic_row(helper.NARROW),
                     self.progress_row(helper.NARROW), self.progress_row(helper.NARROW, 'launchComplete', 2),
                     self.progress_row(helper.NARROW, 'windowResizeStarted', 3)))
        reports = helper.xctest_case_diagnostics('\n'.join(rows), expected, entries)
        self.assertEqual(len(reports), 5)
        for report in reports[:4]:
            self.assertEqual(report['requestedElement'], 'captureOpen')
            self.assertEqual(report['requestSequence'], 1)
            self.assertEqual(report['lastProgress'], {'phase': 'launchComplete', 'sequence': 2, 'step': 0})
        self.assertEqual(reports[-1]['lastProgress']['phase'], 'windowResizeStarted')
        self.assertIsNone(reports[-1]['requestedElement'])
        self.assertEqual(reports[-1]['case'], 'narrowMac')
        for forbidden in ('passedTests', 'failedTests', 'xcodebuildExitCode', PRIVATE):
            self.assertNotIn(forbidden, json.dumps(reports))

    def test_case_diagnostics_allow_entry_only_and_unterminated_observed_prefix(self):
        _, entries = self.progress_fixture()
        rows = [event(), self.case_diagnostic_row()]
        report = helper.xctest_case_diagnostics('\n'.join(rows), EXPECTED, entries)[0]
        self.assertIsNone(report['lastProgress'])
        self.assertIsNone(report['requestedElement'])
        self.assertEqual(report['auditBoundaries'], [])
        rows.extend((self.progress_row(), self.case_diagnostic_row(sequence=1, element='todayList')))
        for state in (None, 'passed', 'failed', 'skipped'):
            log = '\n'.join(rows + ([] if state is None else [event(state=state)]))
            report = helper.xctest_case_diagnostics(log, EXPECTED, entries)[0]
            self.assertEqual(report['requestSequence'], 1)
            self.assertEqual(report['requestedElement'], 'todayList')
            self.assertNotIn('result', report)

    def test_case_diagnostics_allow_contiguous_repeated_requests_without_extra_observation_fields(self):
        _, entries = self.progress_fixture()
        rows = [event(), self.case_diagnostic_row(), self.progress_row()]
        rows.extend(self.case_diagnostic_row(sequence=sequence, element='captureTitle') for sequence in range(1, 4))
        report = helper.xctest_case_diagnostics('\n'.join(rows), EXPECTED, entries)[0]
        self.assertEqual((report['requestSequence'], report['requestedElement']), (3, 'captureTitle'))
        self.assertEqual(set(report), {'case', 'method', 'sourceFile', 'entryLine', 'lastProgress',
                                       'requestSequence', 'requestedElement', 'auditBoundaries'})

    def test_case_diagnostics_reject_unknown_private_enums_extra_and_duplicate_json_keys(self):
        _, entries = self.progress_fixture()
        prefix = [event(), self.case_diagnostic_row(), self.progress_row()]
        bad = [self.case_diagnostic_row(sequence=1, element=PRIVATE),
               self.case_diagnostic_row(sequence=1, element='task.row.12345678-1234-1234-1234-123456789ABC'),
               self.case_diagnostic_row(sequence=1, element='captureOpen', label=PRIVATE),
               self.case_diagnostic_row(sequence=1, element='captureOpen', schemaVersion=True),
               self.case_diagnostic_row(sequence=1, element='captureOpen', schemaVersion=2),
               helper.CASE_DIAGNOSTIC_MARKER + '{"schemaVersion":1,"case":"captureValidation","case":"' + PRIVATE + '","requestSequence":1,"requestedElement":"captureOpen"}',
               helper.CASE_DIAGNOSTIC_MARKER + '{"schemaVersion":1,"case":"' + PRIVATE + '","requestSequence":1,"requestedElement":"captureOpen"}',
               helper.CASE_DIAGNOSTIC_MARKER + PRIVATE]
        for row in bad:
            with self.subTest(row=row):
                self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(prefix + [row]), EXPECTED, entries))

    def test_case_diagnostics_reject_missing_duplicate_wrong_and_out_of_bound_request_sequences(self):
        _, entries = self.progress_fixture()
        prefix = [event(), self.case_diagnostic_row(), self.progress_row()]
        for sequence in (-1, True, 1.0, 2, 10_001):
            row = self.case_diagnostic_row(sequence=sequence, element='captureOpen')
            self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(prefix + [row]), EXPECTED, entries))
        first = self.case_diagnostic_row(sequence=1, element='captureOpen')
        for row in (first, self.case_diagnostic_row(), self.case_diagnostic_row(sequence=0, element='captureOpen')):
            self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(prefix + [first, row]), EXPECTED, entries))
        self.assertIsNone(helper.xctest_case_diagnostics('\n'.join([event(), first]), EXPECTED, entries))
        self.assertIsNone(helper.xctest_case_diagnostics('\n'.join([event(), self.progress_row(), self.case_diagnostic_row()]), EXPECTED, entries))
        long = first + ' ' * 2049
        self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(prefix + [long]), EXPECTED, entries))
        with mock.patch.object(helper, 'MAX_LOG', 1), self.assertRaises(helper.AdaptiveError):
            helper.xctest_case_diagnostics('\n'.join(prefix), EXPECTED, entries)

    def test_case_diagnostics_reject_wrong_case_platform_bundle_and_late_malformed_stream(self):
        source, entries = self.progress_fixture()
        prefix = [event(), self.case_diagnostic_row(), self.progress_row()]
        wrong = self.case_diagnostic_row('testMaximumTypeReviewAndWeekPicker', 1, 'reviewCard')
        self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(prefix + [wrong]), EXPECTED, entries))
        self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(prefix + [self.case_diagnostic_row(sequence=1, element='reviewCard')]), EXPECTED, entries))
        for platform in ('iphone', 'ipad'):
            expected = {**EXPECTED, 'platform': platform}
            self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(prefix + [self.case_diagnostic_row(sequence=1, element='captureMoreDisclosure')]), expected, entries))
        mac = {'platform': 'macos', 'appearance': 'system'}
        mac_entries = helper.source_method_entries(source, 'macos')
        for element in ('nativeStatusBar', 'selectAll', 'keyboardContinue'):
            rows = [event(owner='MirrorMacAdaptiveUITests.MirrorAdaptiveUITests'), self.case_diagnostic_row(),
                    self.progress_row(), self.case_diagnostic_row(sequence=1, element=element)]
            self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(rows), mac, mac_entries))
        foreign = '\n'.join(prefix).replace(BUNDLE, 'ForeignUITests')
        self.assertIsNone(helper.xctest_case_diagnostics(foreign, EXPECTED, entries))
        valid = prefix + [self.case_diagnostic_row(sequence=1, element='captureOpen'), event(state='failed')]
        self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(valid + [helper.CASE_DIAGNOSTIC_MARKER + PRIVATE]), EXPECTED, entries))

    def test_case_diagnostics_reject_native_event_marker_mixing_and_noncontiguous_progress(self):
        _, entries = self.progress_fixture()
        entry = self.case_diagnostic_row()
        request = self.case_diagnostic_row(sequence=1, element='todayList')
        audit = self.audit_boundary_row()
        for rows in ([event() + ' ' + entry], [event() + ' ' + audit],
                     [event() + ' UI adaptive configuration measurement: not-json', entry, self.progress_row()],
                     [event() + ' UI adaptive resize measurement: not-json', entry, self.progress_row()],
                     [event() + ' ' + self.progress_row(), entry],
                     [event(), entry, self.progress_row(), event(state='failed') + ' ' + request],
                     [event(), entry, self.progress_row(), self.progress_row(phase='launchComplete', sequence=3)],
                     [event(), entry, self.progress_row() + ' ' + request],
                     [event(), entry, self.progress_row(), event() + ' ' + event(state='failed')]):
            self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(rows), EXPECTED, entries))

    def test_audit_boundaries_preserve_all_nine_returns_without_case_pass_inference(self):
        source, _ = self.progress_fixture()
        expected = {'platform': 'macos', 'appearance': 'system'}
        entries = helper.source_method_entries(source, 'macos')
        owner = 'MirrorMacAdaptiveUITests.MirrorAdaptiveUITests'
        rows = []
        for case in helper.required_cases('macos'):
            rows.extend(self.case_protocol_rows(case, 'macos'))
            rows.append(event(case, owner, 'passed'))
        reports = helper.xctest_case_diagnostics('\n'.join(rows), expected, entries)
        self.assertEqual(sum(len(report['auditBoundaries']) for report in reports), 9)
        self.assertEqual([len(report['auditBoundaries']) for report in reports],
                         [sum(phase == 'auditStarted' for phase, _ in helper.PROGRESS_PROTOCOL[case])
                          for case in helper.required_cases('macos')])
        for report in reports:
            self.assertTrue(all(boundary['outcome'] == 'returned' for boundary in report['auditBoundaries']))
            for key in ('passedTests', 'failedTests', 'result', 'issue', 'message', 'timeout'):
                self.assertNotIn(key, report)

    def test_audit_throw_is_owned_per_case_and_preserved_when_a_later_case_starts(self):
        _, entries = self.progress_fixture()
        other = 'testMaximumTypeReviewAndWeekPicker'
        rows = self.case_protocol_rows(outcome='threw') + [event(state='failed'), event(other),
                self.case_diagnostic_row(other), self.progress_row(other)]
        reports = helper.xctest_case_diagnostics('\n'.join(rows), EXPECTED, entries)
        self.assertEqual(reports[0]['auditBoundaries'], [{'auditSequence': 1, 'outcome': 'threw'}])
        self.assertEqual(reports[0]['lastProgress']['phase'], 'auditStarted')
        self.assertEqual(reports[1]['auditBoundaries'], [])
        self.assertNotIn(PRIVATE, json.dumps(reports))

    def test_audit_boundaries_reject_wrong_context_sequences_private_outcomes_and_repeated_returns(self):
        _, entries = self.progress_fixture()
        prefix = self.case_protocol_rows()
        boundary_index = next(index for index, row in enumerate(prefix) if row.startswith(helper.AUDIT_BOUNDARY_MARKER))
        before = prefix[:boundary_index]
        for row in (self.audit_boundary_row(sequence=0), self.audit_boundary_row(sequence=True),
                    self.audit_boundary_row(sequence=2), self.audit_boundary_row(outcome=PRIVATE),
                    self.audit_boundary_row(issue=PRIVATE), self.audit_boundary_row(schemaVersion=True),
                    self.audit_boundary_row(case='testMaximumTypeReviewAndWeekPicker')):
            self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(before + [row]), EXPECTED, entries))
        self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(before + [self.audit_boundary_row()] * 2), EXPECTED, entries))
        self.assertIsNone(helper.xctest_case_diagnostics('\n'.join([event(), self.case_diagnostic_row(), self.progress_row(), self.audit_boundary_row()]), EXPECTED, entries))
        missing_return = prefix[:boundary_index] + prefix[boundary_index + 1:]
        self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(missing_return), EXPECTED, entries))
        thrown = self.case_protocol_rows(outcome='threw')
        self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(thrown + [self.progress_row(phase='auditComplete', sequence=10, step=1)]), EXPECTED, entries))
        self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(thrown + [self.case_diagnostic_row(sequence=1, element='captureOpen')]), EXPECTED, entries))

    def test_case_diagnostic_legacy_absence_preserves_original_progress_and_measurement_parsers(self):
        _, entries = self.progress_fixture()
        rows = [event(), self.progress_row(), self.configuration_measurement_row()]
        legacy = '\n'.join(rows)
        self.assertIsNone(helper.xctest_case_diagnostics(legacy, EXPECTED, entries))
        self.assertEqual(helper.xctest_progress_diagnostics(legacy, EXPECTED, entries)['phase'], 'started')
        self.assertEqual(len(helper.xctest_measurement_diagnostics(legacy, EXPECTED, entries)), 1)
        new = '\n'.join([event(), self.case_diagnostic_row(), self.progress_row(), self.configuration_measurement_row()])
        self.assertEqual(helper.xctest_progress_diagnostics(new, EXPECTED, entries)['phase'], 'started')
        self.assertEqual(len(helper.xctest_measurement_diagnostics(new, EXPECTED, entries)), 1)
        self.assertEqual(helper.xctest_case_diagnostics(new, EXPECTED, entries)[0]['case'], 'captureValidation')

    def test_case_diagnostic_notice_requires_bounded_source_log_and_pinned_context_without_raw_text(self):
        source, _ = self.progress_fixture()
        expected = {**EXPECTED, 'commitSHA': 'a' * 40, 'buildNumber': '12', 'runID': '34', 'runAttempt': '1'}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            path = root / helper.UI_FAILURE_SOURCE_FILE
            path.parent.mkdir(parents=True)
            path.write_text(source)
            with mock.patch.object(helper, 'context_for', side_effect=helper.AdaptiveError(PRIVATE)), \
                    mock.patch.object(helper, 'read_regular') as read, mock.patch('builtins.print') as output:
                helper.case_progress_diagnostics(root, expected)
            read.assert_not_called()
            self.assertIn('contextUnavailable', output.call_args[0][0])
            self.assertNotIn(PRIVATE, output.call_args[0][0])
            with mock.patch.object(helper, 'ROOT', root), mock.patch.object(helper, 'context_for'), \
                    mock.patch('builtins.print') as output:
                helper.case_progress_diagnostics(root, expected)
                self.assertIn('testLogUnavailable', output.call_args[0][0])
                log = root / 'test.log'
                log.write_text('\n'.join([event(), self.case_diagnostic_row(), self.progress_row(),
                                          self.case_diagnostic_row(sequence=1, element='captureOpen')]))
                helper.case_progress_diagnostics(root, expected)
                notice = output.call_args[0][0]
                self.assertIn('observedCaseBoundariesOnly', notice)
                self.assertIn(expected['commitSHA'], notice)
                for forbidden in (str(root), PRIVATE, 'passedTests', 'failedTests', 'message', 'xcodebuildExitCode'):
                    self.assertNotIn(forbidden, notice)
                log.write_text('\n'.join([event(), self.case_diagnostic_row(), self.progress_row(),
                                          self.case_diagnostic_row(sequence=1, element=PRIVATE)]))
                helper.case_progress_diagnostics(root, expected)
                self.assertIn('noAcceptedCaseDiagnostics', output.call_args[0][0])
                self.assertNotIn(PRIVATE, output.call_args[0][0])
                log.rename(root / 'original.log')
                log.symlink_to(root / 'original.log')
                helper.case_progress_diagnostics(root, expected)
                self.assertIn('testLogUnavailable', output.call_args[0][0])
                log.unlink()
                log.write_text(PRIVATE)
                with mock.patch.object(helper, 'MAX_LOG', 1):
                    helper.case_progress_diagnostics(root, expected)
                self.assertIn('testLogUnavailable', output.call_args[0][0])
                path.unlink()
                helper.case_progress_diagnostics(root, expected)
                self.assertIn('sourceUnavailable', output.call_args[0][0])

    def capture_save_failure_row(self, **extra):
        return helper.CAPTURE_SAVE_FAILURE_MARKER + json.dumps({
            'schemaVersion': 1, 'case': helper.CASE_DIAGNOSTIC_NAMES[CASE], 'requestSequence': 1,
            'requestedElement': 'captureSave', 'boundary': 'reveal', 'exists': True,
            'enabled': True, 'hittable': False, 'windowOwnerCount': 1, 'ownerHasCaptureClose': True,
            'scrollCandidateCount': 2, 'scrollOwnerCount': 0,
            'frame': [412, 441, 200, 52], 'viewport': None, **extra})

    def test_capture_save_failure_is_owned_by_failed_case_request_and_preserves_unknown_state(self):
        source, _ = self.progress_fixture()
        for platform in ('iphone', 'ipad', 'macos'):
            entries = helper.source_method_entries(source, platform)
            expected = {'platform': platform, 'appearance': 'system'}
            owner = ('MirrorMacAdaptiveUITests' if platform == 'macos' else BUNDLE) + '.MirrorAdaptiveUITests'
            for fields in ({}, {'boundary': 'assertVisible', 'enabled': False},
                           {'boundary': 'assertVisible', 'exists': False, 'enabled': None, 'hittable': None,
                            'windowOwnerCount': 0, 'ownerHasCaptureClose': None, 'frame': None}):
                rows = [event(owner=owner), self.case_diagnostic_row(), self.progress_row(),
                        self.case_diagnostic_row(sequence=1, element='captureSave'),
                        self.capture_save_failure_row(**fields), event(owner=owner, state='failed')]
                report = helper.xctest_case_diagnostics('\n'.join(rows), expected, entries)[0]
                observed = report['captureSaveFailure']
                self.assertEqual(observed, json.loads(rows[-2][len(helper.CAPTURE_SAVE_FAILURE_MARKER):]))
                self.assertEqual(report['sourceFile'], helper.UI_FAILURE_SOURCE_FILE)
                self.assertEqual(report['requestSequence'], observed['requestSequence'])
                self.assertNotIn(PRIVATE, json.dumps(report))

    def test_capture_save_failure_rejects_private_fields_wrong_types_geometry_and_ownership(self):
        source, _ = self.progress_fixture()
        entries = helper.source_method_entries(source, 'iphone')
        prefix = [event(), self.case_diagnostic_row(), self.progress_row(),
                  self.case_diagnostic_row(sequence=1, element='captureSave')]
        invalid = ({'label': PRIVATE}, {'boundary': PRIVATE}, {'case': PRIVATE},
                   {'requestedElement': 'captureOpen'}, {'requestSequence': 2}, {'requestSequence': True},
                   {'exists': 1}, {'enabled': PRIVATE}, {'exists': False, 'enabled': False},
                   {'enabled': None}, {'hittable': None}, {'windowOwnerCount': True},
                   {'windowOwnerCount': -1}, {'windowOwnerCount': 10_001}, {'ownerHasCaptureClose': None},
                   {'windowOwnerCount': 0}, {'scrollCandidateCount': 0, 'scrollOwnerCount': 1},
                   {'scrollOwnerCount': True}, {'scrollCandidateCount': '2'},
                   {'frame': [0, 0, True, 44]}, {'frame': [0, 0, 100_001, 44]},
                   {'frame': [0, 0, 10 ** 200, 44]}, {'frame': [0, 0, float('inf'), 44]},
                   {'viewport': [0, 0, 44]}, {'boundary': 'assertVisible', 'hittable': True})
        for fields in invalid:
            with self.subTest(fields=fields):
                log = '\n'.join(prefix + [self.capture_save_failure_row(**fields), event(state='failed')])
                self.assertIsNone(helper.xctest_case_diagnostics(log, EXPECTED, entries))
        duplicate = self.capture_save_failure_row().replace('"exists": true', '"exists": true, "exists": false')
        self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(prefix + [duplicate, event(state='failed')]), EXPECTED, entries))

    def test_capture_save_failure_rejects_missing_request_wrong_terminal_and_postfailure_activity(self):
        source, _ = self.progress_fixture()
        entries = helper.source_method_entries(source, 'iphone')
        prefix = [event(), self.case_diagnostic_row(), self.progress_row()]
        request = self.case_diagnostic_row(sequence=1, element='captureSave')
        failure = self.capture_save_failure_row()
        invalid = [prefix + [failure, event(state='failed')],
                   prefix + [self.case_diagnostic_row(sequence=1, element='captureTitle'), failure, event(state='failed')],
                   prefix + [request, failure],
                   prefix + [request, failure, event(state='passed')],
                   prefix + [request, failure, event(state='skipped')],
                   prefix + [request, failure, failure, event(state='failed')],
                   prefix + [request, failure, self.progress_row(phase='launchComplete', sequence=2), event(state='failed')],
                   prefix + [request, failure, self.case_diagnostic_row(sequence=2, element='captureTitle'), event(state='failed')],
                   prefix + [request, event(state='failed'), failure]]
        for rows in invalid:
            with self.subTest(rows=rows):
                self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(rows), EXPECTED, entries))



    def reveal_owner_row(self, **extra):
        return helper.REVEAL_OWNER_MARKER + json.dumps({
            'schemaVersion': 1, 'case': 'captureValidation', 'requestSequence': 1,
            'requestedElement': 'captureSave', 'candidateCount': 6, 'areaCount': 5,
            'hittableCount': 4, 'typedTargetCount': 3, 'columnCount': 2, 'intersectCount': 1,
            'keyboardCount': 1, 'keyboardFrame': [0, 550, 402, 324], **extra})

    def test_reveal_owner_counts_preserve_mobile_keyboard_and_mac_unknown_geometry(self):
        source, _ = self.progress_fixture()
        for platform in ('iphone', 'ipad', 'macos'):
            expected = {**EXPECTED, 'platform': platform}
            owner = ('MirrorMacAdaptiveUITests' if platform == 'macos' else BUNDLE) + '.MirrorAdaptiveUITests'
            fields = {'keyboardCount': None, 'keyboardFrame': None} if platform == 'macos' else {}
            row = self.reveal_owner_row(**fields)
            rows = [event(owner=owner), self.case_diagnostic_row(), self.progress_row(),
                    self.case_diagnostic_row(sequence=1, element='captureSave'), row,
                    self.capture_save_failure_row(scrollCandidateCount=6, scrollOwnerCount=1),
                    event(owner=owner, state='failed')]
            result = helper.xctest_case_diagnostics('\n'.join(rows), expected,
                                                   helper.source_method_entries(source, platform))[0]
            self.assertEqual(result['revealOwnerFailure'], json.loads(row[len(helper.REVEAL_OWNER_MARKER):]))
            self.assertIn('captureSaveFailure', result)
            self.assertNotIn(PRIVATE, json.dumps(result))

    def test_reveal_owner_failure_accepts_current_task_postpone_request_only(self):
        source, _ = self.progress_fixture()
        case = 'testMaximumTypeSearchDetailCompletionAndUndo'
        entries = helper.source_method_entries(source, 'iphone')
        row = self.reveal_owner_row(case='searchDetailUndo', requestedElement='taskPostpone',
                                    candidateCount=0, areaCount=0, hittableCount=0,
                                    typedTargetCount=0, columnCount=0, intersectCount=0,
                                    keyboardCount=0, keyboardFrame=None)
        rows = [event(case=case), self.case_diagnostic_row(case=case), self.progress_row(case=case),
                self.case_diagnostic_row(case=case, sequence=1, element='taskPostpone'), row,
                event(case=case, state='failed')]
        result = helper.xctest_case_diagnostics('\n'.join(rows), EXPECTED, entries)[0]
        self.assertEqual(result['revealOwnerFailure']['intersectCount'], 0)
        self.assertEqual(result['requestedElement'], 'taskPostpone')
        self.assertIsNone(result['revealOwnerFailure']['keyboardFrame'])

    def test_reveal_owner_counts_reject_private_types_bounds_and_increasing_filters(self):
        source, _ = self.progress_fixture()
        entries = helper.source_method_entries(source, 'iphone')
        prefix = [event(), self.case_diagnostic_row(), self.progress_row(),
                  self.case_diagnostic_row(sequence=1, element='captureSave')]
        bad = ({'label': PRIVATE}, {'case': PRIVATE}, {'requestedElement': PRIVATE},
               {'requestSequence': True}, {'requestSequence': 2}, {'candidateCount': True},
               {'candidateCount': -1}, {'candidateCount': 10_001}, {'areaCount': 7},
               {'hittableCount': 6}, {'typedTargetCount': 5}, {'columnCount': 4}, {'intersectCount': 3},
               {'keyboardCount': True}, {'keyboardCount': None}, {'keyboardCount': -1},
               {'keyboardCount': 10_001}, {'keyboardCount': 0}, {'keyboardCount': 2},
               {'keyboardFrame': [0, 0, -1, 10]}, {'keyboardFrame': [0, 0, 10, -1]},
               {'keyboardFrame': [0, 0, True, 10]}, {'keyboardFrame': [0, 0, 10 ** 1000, 10]},
               {'keyboardFrame': [0, 0, float('inf'), 10]}, {'keyboardFrame': [0, 0, 10]})
        for fields in bad:
            with self.subTest(fields=fields):
                self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(
                    prefix + [self.reveal_owner_row(**fields), event(state='failed')]), EXPECTED, entries))
        duplicate = self.reveal_owner_row().replace('"areaCount": 5', '"areaCount": 5, "areaCount": 4')
        self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(prefix + [duplicate, event(state='failed')]), EXPECTED, entries))

    def test_reveal_owner_failure_requires_failed_terminal_and_no_later_activity(self):
        source, _ = self.progress_fixture()
        entries = helper.source_method_entries(source, 'iphone')
        prefix = [event(), self.case_diagnostic_row(), self.progress_row(),
                  self.case_diagnostic_row(sequence=1, element='captureSave')]
        row = self.reveal_owner_row()
        for suffix in ([], [event(state='passed')], [event(state='skipped')],
                       [row, event(state='failed')],
                       [self.case_diagnostic_row(sequence=2, element='captureTitle'), event(state='failed')],
                       [self.progress_row(phase='launchComplete', sequence=2), event(state='failed')]):
            self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(prefix + [row] + suffix), EXPECTED, entries))
        self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(prefix[:-1] + [row, event(state='failed')]), EXPECTED, entries))

    def test_reveal_owner_schema_two_keeps_nonhittable_parent_with_owned_typed_target(self):
        source, _ = self.progress_fixture()
        for platform in ('iphone', 'ipad', 'macos'):
            owner = ('MirrorMacAdaptiveUITests' if platform == 'macos' else BUNDLE) + '.MirrorAdaptiveUITests'
            expected = {**EXPECTED, 'platform': platform}
            entries = helper.source_method_entries(source, platform)
            fields = {'candidateCount': 1, 'areaCount': 1, 'hittableCount': 0,
                      'typedTargetCount': 1, 'columnCount': 1, 'intersectCount': 1,
                      'keyboardCount': None if platform == 'macos' else 0, 'keyboardFrame': None}
            prefix = [event(owner=owner), self.case_diagnostic_row(), self.progress_row(),
                      self.case_diagnostic_row(sequence=1, element='captureSave')]
            for version in (1, 2):
                row = self.reveal_owner_row(schemaVersion=version, **fields)
                result = helper.xctest_case_diagnostics('\n'.join(
                    prefix + [row, event(owner=owner, state='failed')]), expected, entries)
                if version == 1:
                    self.assertIsNone(result, '이전 schema의 필터 감소 계약은 그대로 유지한다.')
                else:
                    self.assertEqual(result[0]['revealOwnerFailure'], json.loads(row[len(helper.REVEAL_OWNER_MARKER):]))

    def test_reveal_owner_schema_two_rejects_invalid_independent_counts_and_case_ownership(self):
        source, _ = self.progress_fixture()
        entries = helper.source_method_entries(source, 'iphone')
        prefix = [event(), self.case_diagnostic_row(), self.progress_row(),
                  self.case_diagnostic_row(sequence=1, element='captureSave')]
        fields = {'schemaVersion': 2, 'candidateCount': 1, 'areaCount': 1, 'hittableCount': 0,
                  'typedTargetCount': 1, 'columnCount': 1, 'intersectCount': 1,
                  'keyboardCount': 0, 'keyboardFrame': None}
        bad = ({'schemaVersion': True}, {'schemaVersion': 0}, {'schemaVersion': 3},
               {'candidateCount': True}, {'candidateCount': 10_001}, {'areaCount': 2},
               {'hittableCount': -1}, {'hittableCount': 2}, {'typedTargetCount': 2},
               {'columnCount': 2}, {'intersectCount': 2}, {'case': 'searchDetailUndo'},
               {'requestedElement': 'captureTitle'}, {'requestSequence': 2}, {'label': PRIVATE})
        for change in bad:
            with self.subTest(change=change):
                row = self.reveal_owner_row(**{**fields, **change})
                self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(
                    prefix + [row, event(state='failed')]), EXPECTED, entries))
        row = self.reveal_owner_row(**fields)
        for suffix in ([], [event(state='passed')], [event(state='skipped')],
                       [row, event(state='failed')],
                       [self.case_diagnostic_row(sequence=2, element='captureTitle'), event(state='failed')]):
            self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(prefix + [row] + suffix), EXPECTED, entries))

    def test_reveal_owner_schema_two_does_not_change_other_marker_versions(self):
        source, _ = self.progress_fixture()
        entries = helper.source_method_entries(source, 'iphone')
        prefix = [event(), self.case_diagnostic_row(), self.progress_row(),
                  self.case_diagnostic_row(sequence=1, element='captureSave')]
        good = prefix + [self.capture_save_failure_row(), event(state='failed')]
        self.assertIsNotNone(helper.xctest_case_diagnostics('\n'.join(good), EXPECTED, entries))
        for index in (1, 4):
            changed = list(good)
            changed[index] = changed[index].replace('"schemaVersion": 1', '"schemaVersion": 2')
            self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(changed), EXPECTED, entries))
        good_audit = self.case_protocol_rows()
        self.assertIsNotNone(helper.xctest_case_diagnostics('\n'.join(good_audit), EXPECTED, entries))
        changed_audit = [row.replace('"schemaVersion": 1', '"schemaVersion": 2')
                         if row.startswith(helper.AUDIT_BOUNDARY_MARKER) else row for row in good_audit]
        self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(changed_audit), EXPECTED, entries))

    def phone_reveal_obstruction_row(self, **extra):
        return helper.PHONE_REVEAL_OBSTRUCTION_MARKER + json.dumps({
            'schemaVersion': 1, 'case': 'searchDetailUndo', 'requestSequence': 1,
            'requestedElement': 'taskPostpone', 'observationCount': 3, 'swipeDirections': ['up', 'up'],
            'first': {'target': [16, 880, 152, 61], 'owner': [0, 62, 402, 760]},
            'previous': {'target': [16, 820, 152, 61], 'owner': [0, 62, 402, 760]},
            'last': {'target': [16, 760, 152, 61], 'owner': [0, 62, 402, 760]},
            'windowFrame': [0, 0, 402, 874],
            'elements': {
                'feedback': {'count': 1, 'frame': [0, 740, 402, 75], 'intersectsTarget': True},
                'dismissFeedback': {'count': 1, 'frame': [340, 742, 44, 44], 'intersectsTarget': False},
                'undo': {'count': 1, 'frame': [16, 744, 140, 44], 'intersectsTarget': True},
                'retry': {'count': 0, 'frame': None, 'intersectsTarget': None},
                'tabBar': {'count': 1, 'frame': [0, 821, 402, 53], 'intersectsTarget': False},
            }, **extra})

    def phone_reveal_obstruction_prefix(self):
        case = 'testMaximumTypeSearchDetailCompletionAndUndo'
        rows = [event(case=case), self.case_diagnostic_row(case=case)]
        for sequence, (phase, step) in enumerate(helper.PROGRESS_PROTOCOL[case], 1):
            rows.append(self.progress_row(case, phase, sequence, step))
            if phase == 'postponeStarted':
                break
        rows.extend((self.case_diagnostic_row(case=case, sequence=1, element='taskPostpone'),
            self.reveal_owner_row(schemaVersion=2, case='searchDetailUndo', requestedElement='taskPostpone',
                candidateCount=1, areaCount=1, hittableCount=0, typedTargetCount=1, columnCount=1,
                intersectCount=1, keyboardCount=0, keyboardFrame=None)))
        return case, rows

    def test_phone_obstruction_preserves_owned_failure_geometry_and_positive_area_intersection(self):
        source, _ = self.progress_fixture()
        entries = helper.source_method_entries(source, 'iphone')
        case, prefix = self.phone_reveal_obstruction_prefix()
        base = json.loads(self.phone_reveal_obstruction_row()[len(helper.PHONE_REVEAL_OBSTRUCTION_MARKER):])
        unknown = {name: {**value, 'intersectsTarget': None} for name, value in base['elements'].items()}
        unknown['undo'] = {'count': 2, 'frame': None, 'intersectsTarget': None}
        unknown['feedback'] = {'count': 1, 'frame': None, 'intersectsTarget': None}
        variants = ({}, {'observationCount': 1, 'swipeDirections': [], 'first': base['last'], 'previous': None},
                    {'observationCount': 2, 'swipeDirections': ['down'], 'previous': base['first']},
                    {'observationCount': 8, 'swipeDirections': ['up'] * 7},
                    {'last': {'target': None, 'owner': None}, 'elements': unknown})
        for fields in variants:
            with self.subTest(fields=fields):
                row = self.phone_reveal_obstruction_row(**fields)
                result = helper.xctest_case_diagnostics('\n'.join(prefix + [row, event(case=case, state='failed')]),
                                                       EXPECTED, entries)[0]
                self.assertEqual(result['phoneRevealObstruction'],
                                 json.loads(row[len(helper.PHONE_REVEAL_OBSTRUCTION_MARKER):]))
                self.assertEqual(result['lastProgress']['phase'], 'postponeStarted')
                self.assertIn('revealOwnerFailure', result)
                for forbidden in (PRIVATE, 'passedTests', 'failedTests', 'xcodebuildExitCode'):
                    self.assertNotIn(forbidden, json.dumps(result))

    def test_phone_obstruction_rejects_private_fields_types_bounds_and_contradictory_geometry(self):
        source, _ = self.progress_fixture()
        entries = helper.source_method_entries(source, 'iphone')
        case, prefix = self.phone_reveal_obstruction_prefix()
        base = json.loads(self.phone_reveal_obstruction_row()[len(helper.PHONE_REVEAL_OBSTRUCTION_MARKER):])
        bad = [{'label': PRIVATE}, {'schemaVersion': True}, {'schemaVersion': 2}, {'case': PRIVATE},
               {'case': 'captureValidation'},
               {'requestedElement': PRIVATE}, {'requestSequence': True}, {'requestSequence': 2},
               {'observationCount': True}, {'observationCount': 0}, {'observationCount': 9},
               {'swipeDirections': ['up']}, {'swipeDirections': ['up', PRIVATE]},
               {'swipeDirections': ['up', True]}, {'previous': None},
               {'observationCount': 1, 'swipeDirections': [], 'previous': None},
               {'observationCount': 2, 'swipeDirections': ['up']},
               {'first': {**base['first'], 'title': PRIVATE}},
               {'windowFrame': None}, {'windowFrame': [0, 0, 0, 874]},
               {'windowFrame': [0, 0, 402, -1]}, {'windowFrame': [0, 0, True, 874]},
               {'windowFrame': [0, 0, 402, float('inf')]},
               {'elements': {**base['elements'], 'privateElement': base['elements']['undo']}},
               {'elements': {name: value for name, value in base['elements'].items() if name != 'retry'}}]
        for frame in ([0, 0, -1, 10], [0, 0, 10, -1], [0, 0, True, 10], [0, 0, 10],
                      [0, 0, 10 ** 1000, 10], [0, 0, float('nan'), 10]):
            bad.append({'last': {'target': frame, 'owner': base['last']['owner']}})
        for element in ({'count': True, 'frame': None, 'intersectsTarget': None},
                        {'count': -1, 'frame': None, 'intersectsTarget': None},
                        {'count': 10_001, 'frame': None, 'intersectsTarget': None},
                        {'count': 2, 'frame': [0, 740, 402, 75], 'intersectsTarget': True},
                        {'count': 1, 'frame': None, 'intersectsTarget': False},
                        {**base['elements']['feedback'], 'intersectsTarget': False},
                        {**base['elements']['feedback'], 'intersectsTarget': None},
                        {**base['elements']['feedback'], 'intersectsTarget': 1},
                        {**base['elements']['feedback'], 'label': PRIVATE}):
            bad.append({'elements': {**base['elements'], 'feedback': element}})
        bad.append({'elements': {**base['elements'], 'tabBar': {**base['elements']['tabBar'], 'intersectsTarget': True}}})
        for fields in bad:
            with self.subTest(fields=fields):
                self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(
                    prefix + [self.phone_reveal_obstruction_row(**fields), event(case=case, state='failed')]), EXPECTED, entries))

    def test_phone_swipe_limit_preserves_ninth_observation_after_eight_actions(self):
        source, _ = self.progress_fixture()
        entries = helper.source_method_entries(source, 'iphone')
        case, prefix = self.phone_reveal_obstruction_prefix()
        row = self.phone_reveal_obstruction_row(schemaVersion=2, boundary='swipeLimit',
                                               observationCount=9, swipeDirections=['up'] * 8)
        result = helper.xctest_case_diagnostics('\n'.join(prefix + [row, event(case=case, state='failed')]),
                                               EXPECTED, entries)[0]['phoneRevealObstruction']
        self.assertEqual(result, json.loads(row[len(helper.PHONE_REVEAL_OBSTRUCTION_MARKER):]))
        self.assertNotEqual(result['previous']['target'], result['last']['target'])
        self.assertEqual(result['boundary'], 'swipeLimit')
        for terminal in ('passed', 'skipped'):
            self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(prefix + [row, event(case=case, state=terminal)]),
                                                           EXPECTED, entries))
        self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(prefix + [row]), EXPECTED, entries))
        self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(prefix + [row, event(case=case, state='failed')]),
                                                       {**EXPECTED, 'platform': 'ipad'}, entries))

    def test_phone_swipe_limit_rejects_other_boundary_count_pairs_and_legacy_shape_changes(self):
        source, _ = self.progress_fixture()
        entries = helper.source_method_entries(source, 'iphone')
        case, prefix = self.phone_reveal_obstruction_prefix()
        base = {'schemaVersion': 2, 'boundary': 'swipeLimit', 'observationCount': 9, 'swipeDirections': ['up'] * 8}
        invalid = ({'schemaVersion': 1}, {'schemaVersion': 3}, {'schemaVersion': True},
                   {'boundary': PRIVATE}, {'boundary': None}, {'observationCount': 8}, {'observationCount': 10},
                   {'observationCount': True}, {'swipeDirections': ['up'] * 7}, {'swipeDirections': ['up'] * 9},
                   {'swipeDirections': ['up'] * 7 + [PRIVATE]}, {'previous': None}, {'private': PRIVATE})
        rows = [self.phone_reveal_obstruction_row(**{**base, **change}) for change in invalid]
        rows.append(self.phone_reveal_obstruction_row(schemaVersion=2, observationCount=9, swipeDirections=['up'] * 8))
        for row in rows:
            self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(prefix + [row, event(case=case, state='failed')]),
                                                           EXPECTED, entries))

    def test_phone_obstruction_requires_phone_current_request_postpone_boundary_and_failed_terminal(self):
        source, _ = self.progress_fixture()
        entries = helper.source_method_entries(source, 'iphone')
        case, prefix = self.phone_reveal_obstruction_prefix()
        row = self.phone_reveal_obstruction_row()
        failed = event(case=case, state='failed')
        for suffix in ([], [event(case=case, state='passed')], [event(case=case, state='skipped')],
                       [row, failed], [self.progress_row(case, 'postponeComplete', 6), failed],
                       [self.case_diagnostic_row(case, 2, 'librarySearch'), failed],
                       [prefix[-1], failed]):
            self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(prefix + [row] + suffix), EXPECTED, entries))
        wrong_phase = [text for text in prefix if '"phase": "postponeStarted"' not in text]
        wrong_request = [text.replace('"taskPostpone"', '"librarySearch"') for text in prefix]
        invalid = (prefix[:-1] + [row, failed], prefix[:-1] + [row, prefix[-1], failed],
                   wrong_phase + [row, failed], wrong_request + [row, failed],
                   prefix + [failed, row], [row] + prefix + [failed],
                   prefix + ['quoted ' + row, failed], prefix + [row + PRIVATE, failed],
                   prefix + [row.replace('"observationCount": 3', '"observationCount": 3, "observationCount": 3'), failed])
        for rows in invalid:
            self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(rows), EXPECTED, entries))
        for platform in ('ipad', 'macos'):
            rows = prefix + [row, failed]
            if platform == 'macos':
                rows = [text.replace(BUNDLE, 'MirrorMacAdaptiveUITests') for text in rows]
                rows[-3] = self.reveal_owner_row(schemaVersion=2, case='searchDetailUndo', requestedElement='taskPostpone',
                    candidateCount=1, areaCount=1, hittableCount=0, typedTargetCount=1, columnCount=1,
                    intersectCount=1, keyboardCount=None, keyboardFrame=None)
            self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(rows), {**EXPECTED, 'platform': platform},
                                                           helper.source_method_entries(source, platform)))

    def phone_reveal_guard_row(self, **extra):
        return helper.PHONE_REVEAL_OBSTRUCTION_MARKER + json.dumps({
            'schemaVersion': 3, 'case': 'searchDetailUndo', 'requestSequence': 1,
            'requestedElement': 'taskPostpone', 'status': 'guardRejected', 'reason': 'ownerWindowCount',
            'boundary': 'swipeLimit', 'observationCount': 9, 'swipeDirections': ['up'] * 8,
            'counts': {'appTargets': 1, 'ownerWindows': 2, 'windowTargets': None}, **extra})

    def test_phone_obstruction_guard_rejection_preserves_only_fixed_partial_observations(self):
        source, _ = self.progress_fixture()
        entries = helper.source_method_entries(source, 'iphone')
        case, prefix = self.phone_reveal_obstruction_prefix()
        variants = [('appForeground', (None, None, None)), ('appForeground', (1, 1, 1)),
                    ('targetIdentity', (None, None, None)), ('targetUniqueness', (0, None, None)),
                    ('targetUniqueness', (1, None, None)), ('targetUniqueness', (None, None, None)),
                    ('ownerWindowCount', (1, 0, None)), ('ownerWindowCount', (1, 2, None)),
                    ('ownerWindowCount', (1, None, None)), ('anchorUniqueness', (1, 1, 0)),
                    ('anchorUniqueness', (1, 1, None)), ('anchorUniqueness', (1, 1, 1)),
                    ('windowGeometry', (1, 1, 1)), ('measurementBounds', (1, 1, 1)),
                    ('payloadBounds', (1, 1, 1))]
        for reason, counts in variants:
            for boundary in ({}, {'boundary': 'reveal', 'observationCount': 1, 'swipeDirections': []},
                             {'boundary': 'reveal', 'observationCount': 8, 'swipeDirections': ['down'] * 7}):
                with self.subTest(reason=reason, counts=counts, boundary=boundary):
                    row = self.phone_reveal_guard_row(reason=reason, **boundary,
                        counts=dict(zip(('appTargets', 'ownerWindows', 'windowTargets'), counts)))
                    report = helper.xctest_case_diagnostics('\n'.join(prefix + [row, event(case=case, state='failed')]),
                                                           EXPECTED, entries)[0]
                    self.assertEqual(report['phoneRevealObstruction'],
                                     json.loads(row[len(helper.PHONE_REVEAL_OBSTRUCTION_MARKER):]))
                    self.assertEqual(report['lastProgress']['phase'], 'postponeStarted')
                    self.assertIn('revealOwnerFailure', report)
                    for forbidden in ('windowFrame', 'first', 'last', 'elements', 'label', 'value',
                                      'passedTests', 'failedTests', 'xcodebuildExitCode', PRIVATE):
                        self.assertNotIn(forbidden, json.dumps(report['phoneRevealObstruction']))

    def test_phone_obstruction_guard_rejection_rejects_private_or_impossible_fields(self):
        source, _ = self.progress_fixture()
        entries = helper.source_method_entries(source, 'iphone')
        case, prefix = self.phone_reveal_obstruction_prefix()
        counts = {'appTargets': 1, 'ownerWindows': 2, 'windowTargets': None}
        changes = [{'status': 'observed'}, {'status': PRIVATE}, {'reason': PRIVATE}, {'reason': True},
                   {'schemaVersion': 1}, {'schemaVersion': 2}, {'schemaVersion': 4}, {'schemaVersion': True},
                   {'case': PRIVATE}, {'requestedElement': PRIVATE}, {'requestSequence': True},
                   {'requestSequence': 2}, {'label': PRIVATE}, {'identifier': PRIVATE}, {'value': PRIVATE},
                   {'windowFrame': [0, 0, 402, 874]}, {'boundary': PRIVATE}, {'boundary': 'reveal'},
                   {'observationCount': 8}, {'observationCount': 10}, {'observationCount': True},
                   {'swipeDirections': ['up'] * 7}, {'swipeDirections': ['up'] * 7 + [PRIVATE]},
                   {'counts': None}, {'counts': {**counts, 'private': PRIVATE}},
                   {'counts': {'appTargets': 1, 'ownerWindows': 2}},
                   {'counts': {**counts, 'appTargets': 0}}, {'counts': {**counts, 'ownerWindows': 1}},
                   {'counts': {**counts, 'windowTargets': 0}}]
        for key in counts:
            for invalid in (-1, 10_001, True, 1.0, PRIVATE, [], {}):
                changes.append({'counts': {**counts, key: invalid}})
        for reason in ('appForeground', 'targetIdentity', 'targetUniqueness', 'anchorUniqueness',
                       'windowGeometry', 'measurementBounds', 'payloadBounds'):
            changes.append({'reason': reason})
        for change in changes:
            with self.subTest(change=change):
                self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(
                    prefix + [self.phone_reveal_guard_row(**change), event(case=case, state='failed')]), EXPECTED, entries))

    def test_phone_obstruction_guard_rejection_requires_owned_failure_and_cannot_replace_pass_evidence(self):
        source, _ = self.progress_fixture()
        entries = helper.source_method_entries(source, 'iphone')
        case, prefix = self.phone_reveal_obstruction_prefix()
        row, failed = self.phone_reveal_guard_row(), event(case=case, state='failed')
        wrong_phase = [text for text in prefix if '"phase": "postponeStarted"' not in text]
        wrong_request = [text.replace('"taskPostpone"', '"librarySearch"') for text in prefix]
        invalid = (prefix + [row], prefix + [row, event(case=case, state='passed')],
                   prefix + [row, event(case=case, state='skipped')], prefix + [row, row, failed],
                   prefix + [row, self.phone_reveal_obstruction_row(), failed],
                   prefix + [row, self.progress_row(case, 'postponeComplete', 6), failed],
                   prefix + [row, self.case_diagnostic_row(case, 2, 'librarySearch'), failed],
                   prefix + [failed, row], prefix[:-1] + [row, failed],
                   prefix[:-1] + [row, prefix[-1], failed], wrong_phase + [row, failed],
                   wrong_request + [row, failed], [row] + prefix + [failed],
                   prefix + ['quoted ' + row, failed], prefix + [row + PRIVATE, failed],
                   prefix + [row.replace('"reason":', '"reason": "ownerWindowCount", "reason":'), failed])
        for rows in invalid:
            self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(rows), EXPECTED, entries))
        for platform in ('ipad', 'macos'):
            rows = prefix + [row, failed]
            if platform == 'macos':
                rows = [text.replace(BUNDLE, 'MirrorMacAdaptiveUITests') for text in rows]
                rows[-3] = self.reveal_owner_row(schemaVersion=2, case='searchDetailUndo', requestedElement='taskPostpone',
                    candidateCount=1, areaCount=1, hittableCount=0, typedTargetCount=1, columnCount=1,
                    intersectCount=1, keyboardCount=None, keyboardFrame=None)
            self.assertIsNone(helper.xctest_case_diagnostics('\n'.join(rows), {**EXPECTED, 'platform': platform},
                                                           helper.source_method_entries(source, platform)))

    def failure_image_fixture(self, directory):
        root = Path(directory).resolve()
        source, _ = self.progress_fixture()
        path = root / helper.UI_FAILURE_SOURCE_FILE
        path.parent.mkdir(parents=True)
        path.write_text(source)
        expected = {**EXPECTED, 'commitSHA': 'a' * 40, 'buildNumber': '23', 'runID': '34', 'runAttempt': '1'}
        rows = [event(), helper.CONFIG_MARKER + json.dumps(helper.configuration(expected, CASE))]
        for sequence, (phase, step) in enumerate(helper.PROGRESS_PROTOCOL[CASE], 1):
            rows.append(self.progress_row(phase=phase, sequence=sequence, step=step))
            if phase == 'recordComplete':
                break
        rows.append(event(state='failed'))
        (root / 'test.log').write_text('\n'.join(rows))
        outcome = {**expected, 'phase': 'test', 'status': 'failed', 'commandExitCode': 65, 'xcodebuildExitCode': 65}
        (root / 'safe-outcome.json').write_text(json.dumps(outcome))
        attachments = root / 'failure-attachments'
        attachments.mkdir()
        records = export()[:1]
        records[0]['attachments'] = records[0]['attachments'][:1]
        (attachments / 'manifest.json').write_text(json.dumps(records))
        original = png(helper.chunk(b'tEXt', b'Comment\0' + PRIVATE.encode()), helper.chunk(b'eXIf', PRIVATE.encode()))
        (attachments / records[0]['attachments'][0]['exportedFileName']).write_bytes(original)
        return root, expected, outcome, records, original

    def test_failure_images_are_source_bound_partial_diagnostics_without_acceptance_or_private_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root, expected, _, _, original = self.failure_image_fixture(directory)
            with mock.patch.object(helper, 'ROOT', root), mock.patch.object(helper, 'verify_receipt', return_value='b' * 64), \
                    mock.patch('builtins.print') as output:
                helper.failure_evidence(root, expected)
            review = root / 'failure-review'
            manifest = json.loads((review / 'manifest.json').read_text())
            self.assertEqual({key: manifest[key] for key in expected}, expected)
            self.assertEqual((manifest['kind'], manifest['scope'], manifest['semantics']),
                             ('adaptive-failure-diagnostic', 'recordedFixtureAppImagesOnly', 'diagnosticOnlyNotAcceptanceOrAuditCause'))
            self.assertEqual(len(manifest['screenshots']), 1)
            shot = manifest['screenshots'][0]
            self.assertEqual((shot['case'], shot['stage'], shot['sequence']), (CASE, 'max-capture', 1))
            self.assertEqual((review / shot['file']).read_bytes(), helper.clean_png(original)[0])
            self.assertNotIn(PRIVATE.encode(), (review / shot['file']).read_bytes())
            for forbidden in (PRIVATE, str(root), 'testName', 'testIdentifier', 'passedTests', 'failedTests', 'auditType'):
                self.assertNotIn(forbidden, json.dumps(manifest))
                self.assertNotIn(forbidden, output.call_args[0][0])
            self.assertEqual({p.name for p in review.iterdir()}, {'manifest.json', 'SHA256SUMS', 'screenshots'})
            self.assertEqual((root / 'safe-outcome.json').read_text(), json.dumps({**expected, 'phase': 'test', 'status': 'failed', 'commandExitCode': 65, 'xcodebuildExitCode': 65}))
            with self.assertRaises(helper.AdaptiveError):
                helper.validate_outcome(manifest, expected)
            with mock.patch.object(helper, 'ROOT', root), mock.patch.object(helper, 'verify_receipt', return_value='b' * 64), \
                    self.assertRaises(helper.AdaptiveError) as error:
                helper.failure_evidence(root, expected)
            self.assertEqual(str(error.exception), 'staleReviewDirectory')

    def test_failure_images_preserve_recorded_png_when_native_status_was_not_collected(self):
        for terminal in ('failed', None):
            with self.subTest(terminal=terminal), tempfile.TemporaryDirectory() as directory:
                root, expected, outcome, _, original = self.failure_image_fixture(directory)
                # shell의 초기 -1은 기존 failure schema에서 null로 저장된다.
                outcome.update(commandExitCode=130, xcodebuildExitCode=None)
                outcome_bytes = json.dumps(outcome)
                (root / 'safe-outcome.json').write_text(outcome_bytes)
                if terminal is None:
                    rows = (root / 'test.log').read_text().splitlines()
                    (root / 'test.log').write_text('\n'.join(rows[:-1]))
                with mock.patch.object(helper, 'ROOT', root), mock.patch.object(helper, 'verify_receipt', return_value='b' * 64), \
                        mock.patch('builtins.print') as output:
                    helper.failure_evidence(root, expected)
                review = root / 'failure-review'
                manifest = json.loads((review / 'manifest.json').read_text())
                self.assertEqual({key: manifest[key] for key in expected}, expected)
                self.assertEqual((manifest['kind'], manifest['scope'], manifest['semantics']),
                                 ('adaptive-failure-diagnostic', 'recordedFixtureAppImagesOnly', 'diagnosticOnlyNotAcceptanceOrAuditCause'))
                self.assertEqual(len(manifest['screenshots']), 1)
                shot = manifest['screenshots'][0]
                self.assertEqual((shot['case'], shot['stage'], shot['sequence']), (CASE, 'max-capture', 1))
                self.assertEqual((review / shot['file']).read_bytes(), helper.clean_png(original)[0])
                self.assertNotIn(PRIVATE.encode(), (review / shot['file']).read_bytes())
                self.assertEqual({p.name for p in review.iterdir()}, {'manifest.json', 'SHA256SUMS', 'screenshots'})
                self.assertEqual((root / 'safe-outcome.json').read_text(), outcome_bytes)
                self.assertFalse((root / 'review').exists())
                self.assertIn('"status": "diagnosticOnly"', output.call_args[0][0])
                for forbidden in (PRIVATE, str(root), 'passedTests', 'failedTests', 'auditType'):
                    self.assertNotIn(forbidden, json.dumps(manifest))
                    self.assertNotIn(forbidden, output.call_args[0][0])
                with self.assertRaises(helper.AdaptiveError):
                    helper.validate_outcome(manifest, expected)
                with mock.patch.object(helper, 'ROOT', root), mock.patch.object(helper, 'verify_receipt', return_value='b' * 64), \
                        self.assertRaises(helper.AdaptiveError) as error:
                    helper.failure_evidence(root, expected)
                self.assertEqual(str(error.exception), 'staleReviewDirectory')

    def test_missing_native_status_needs_an_owned_failed_or_interrupted_case_before_export(self):
        for kind in ('passed', 'skipped', 'unknown', 'foreignOwner', 'incompleteRecording', 'missingConfiguration'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root, expected, outcome, _, _ = self.failure_image_fixture(directory)
                outcome.update(commandExitCode=130, xcodebuildExitCode=None)
                (root / 'safe-outcome.json').write_text(json.dumps(outcome))
                rows = (root / 'test.log').read_text().splitlines()
                if kind in ('passed', 'skipped'):
                    rows[-1] = event(state=kind)
                elif kind == 'unknown':
                    rows = [PRIVATE]
                elif kind == 'foreignOwner':
                    rows[0] = event(owner='Foreign.MirrorAdaptiveUITests')
                elif kind == 'incompleteRecording':
                    rows.pop(-2)
                elif kind == 'missingConfiguration':
                    rows.pop(1)
                (root / 'test.log').write_text('\n'.join(rows))
                with mock.patch.object(helper, 'ROOT', root), mock.patch.object(helper, 'verify_receipt', return_value='b' * 64), \
                        mock.patch.object(helper, 'directory_files') as files, self.assertRaises(helper.AdaptiveError):
                    helper.failure_evidence(root, expected)
                files.assert_not_called()
                self.assertFalse((root / 'failure-review').exists())

    def test_failure_images_reject_success_build_invalid_native_and_every_foreign_identity_before_export(self):
        with tempfile.TemporaryDirectory() as directory:
            root, expected, outcome, _, _ = self.failure_image_fixture(directory)
            variants = [{**outcome, 'status': 'buildComplete', 'phase': 'build', 'commandExitCode': 0, 'xcodebuildExitCode': 0},
                        {**outcome, 'phase': 'build'}, {**outcome, 'phase': 'build', 'xcodebuildExitCode': None},
                        {**outcome, 'status': 'passed', 'xcodebuildExitCode': None},
                        {**outcome, 'commandExitCode': 0, 'xcodebuildExitCode': None},
                        {**outcome, 'status': PRIVATE, 'xcodebuildExitCode': None},
                        {**outcome, 'xcodebuildExitCode': -1}, {**outcome, 'xcodebuildExitCode': 0},
                        {**outcome, 'xcodebuildExitCode': True}]
            variants += [{**outcome, 'xcodebuildExitCode': native, key: 'foreign'}
                         for native in (65, None) for key in expected]
            for value in variants:
                with self.subTest(keys=tuple(value)):
                    (root / 'safe-outcome.json').write_text(json.dumps(value))
                    with mock.patch.object(helper, 'ROOT', root), mock.patch.object(helper, 'verify_receipt', return_value='b' * 64), \
                            mock.patch.object(helper, 'directory_files') as files, self.assertRaises(helper.AdaptiveError):
                        helper.failure_evidence(root, expected)
                    files.assert_not_called()
                    self.assertFalse((root / 'failure-review').exists())
            for native in (65, None):
                (root / 'safe-outcome.json').write_text(json.dumps({**outcome, 'xcodebuildExitCode': native}))
                with mock.patch.object(helper, 'verify_receipt', side_effect=helper.AdaptiveError('buildReceiptMismatch')), \
                        mock.patch.object(helper, 'directory_files') as files, self.assertRaises(helper.AdaptiveError):
                    helper.failure_evidence(root, expected)
                files.assert_not_called()

    def test_failure_images_require_actual_complete_phase_fixture_configuration_and_native_owner(self):
        source, entries = self.progress_fixture()
        expected = {**EXPECTED, 'commitSHA': 'a' * 40, 'buildNumber': '23', 'runID': '34', 'runAttempt': '1'}
        rows = [event(), helper.CONFIG_MARKER + json.dumps(helper.configuration(expected, CASE))]
        for sequence, (phase, step) in enumerate(helper.PROGRESS_PROTOCOL[CASE], 1):
            rows.append(self.progress_row(phase=phase, sequence=sequence, step=step))
            if phase == 'recordComplete':
                break
        self.assertEqual(helper.failure_recorded_screenshots('\n'.join(rows), expected, entries), {'mirror-adaptive-max-capture-1': CASE})
        invalid = (rows[:-1], rows[:1] + rows[2:], [event(owner='Foreign.MirrorAdaptiveUITests')] + rows[1:],
                   rows + [rows[-1]], rows[:1] + [helper.CONFIG_MARKER + json.dumps({**helper.configuration(expected, CASE), 'appearance': 'dark'})] + rows[2:],
                   rows[:1] + ['prefix ' + rows[1]] + rows[2:])
        for values in invalid:
            with self.assertRaises(helper.AdaptiveError):
                helper.failure_recorded_screenshots('\n'.join(values), expected, entries)
        with self.assertRaises(helper.AdaptiveError):
            helper.failure_recorded_screenshots('\n'.join(rows), expected, {CASE: 1})

    def test_failure_export_rejects_traversal_duplicate_missing_and_wrong_type_and_ignores_system_images(self):
        selected = {'mirror-adaptive-max-capture-1': CASE}
        value = export()[:1]
        value[0]['attachments'] = value[0]['attachments'][:1]
        original = value[0]['attachments'][0]
        automatic = {'name': PRIVATE, 'exportedFileName': '../' + PRIVATE, 'uniformTypeIdentifier': PRIVATE}
        value[0]['attachments'].append(automatic)
        self.assertEqual(helper.failure_export_entries(value, selected), [(CASE, 'mirror-adaptive-max-capture-1', 'shot-1-1.png')])
        for changes in ({'exportedFileName': '../outside.png'}, {'exportedFileName': '/private/outside.png'},
                        {'uniformTypeIdentifier': PRIVATE}, {'name': PRIVATE}):
            with self.assertRaises(helper.AdaptiveError):
                helper.failure_export_entries([{'attachments': [{**original, **changes}]}], selected)
        for bad in ([{'attachments': [original, original]}], [{'attachments': []}], {'nested': value}, []):
            with self.assertRaises(helper.AdaptiveError):
                helper.failure_export_entries(bad, selected)

    def test_failure_images_reject_symlinks_missing_source_and_bad_png_without_partial_review(self):
        for kind in ('symlink', 'missingSource', 'badPNG'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root, expected, _, records, _ = self.failure_image_fixture(directory)
                image = root / 'failure-attachments' / records[0]['attachments'][0]['exportedFileName']
                if kind == 'symlink':
                    image.rename(root / 'private-original.png')
                    image.symlink_to(root / 'private-original.png')
                elif kind == 'missingSource':
                    (root / helper.UI_FAILURE_SOURCE_FILE).unlink()
                else:
                    image.write_bytes(b'not a PNG ' + PRIVATE.encode())
                with mock.patch.object(helper, 'ROOT', root), mock.patch.object(helper, 'verify_receipt', return_value='b' * 64), \
                        self.assertRaises(helper.AdaptiveError):
                    helper.failure_evidence(root, expected)
                self.assertFalse((root / 'failure-review').exists())


class PublicSDKNoticeBoundsTests(unittest.TestCase):
    def excerpt(self, first, text):
        return {'firstLine': first, 'text': text,
                'symbols': [symbol for symbol in sdk_notice.SYMBOLS if symbol in text]}

    def record(self, *excerpts, name='SyntheticPublic.h'):
        return {'file': name, 'sha256': 'a' * 64, 'excerpts': list(excerpts)}

    def run_notice(self, value=None, raw=None):
        if raw is None:
            raw = json.dumps(value, ensure_ascii=True).encode('ascii')
        stdin = mock.Mock()
        stdin.buffer.read.return_value = raw
        environment = {'GITHUB_ACTIONS': 'true', 'GITHUB_SHA': 'a' * 40,
                       'GITHUB_RUN_ID': '1', 'GITHUB_RUN_ATTEMPT': '1'}
        with mock.patch.dict(os.environ, environment, clear=True), mock.patch.object(sdk_notice.sys, 'platform', 'darwin'), \
                mock.patch.object(sdk_notice.sys, 'stdin', stdin), mock.patch('builtins.print') as printed:
            code = sdk_notice.main()
        stdin.buffer.read.assert_called_once_with(sdk_notice.MAX_INPUT + 1)
        return code, [call.args[0] for call in printed.call_args_list]

    def decoded_report(self, notice):
        self.assertTrue(notice.startswith(sdk_notice.PREFIX))
        body = notice[len(sdk_notice.PREFIX):].replace('%0D', '\r').replace('%0A', '\n').replace('%25', '%')
        return json.loads(body)

    def test_sdk_notice_preserves_all_symbols_and_actual_lines_inside_whole_escaped_ascii_budget(self):
        target = 'public ' + ' '.join(sdk_notice.SYMBOLS) + ' // synthetic declaration line'
        lines = ['// synthetic public context % \\ " 한글 ' + 'x' * 400] * 10 + [target] + ['// trailing context'] * 10
        original = self.excerpt(120, '\r\n'.join(lines))
        value = {'status': 'found', 'files': [self.record(original)]}
        self.assertTrue(sdk_notice.valid_files(value['files']))
        full_report = {'schemaVersion': 1, 'sourceSHA': 'a' * 40, 'runID': '1', 'attempt': '1', **value}
        full_message = json.dumps(full_report, ensure_ascii=True, separators=(',', ':'))
        full_notice = sdk_notice.PREFIX + full_message.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
        self.assertGreater(len(full_notice.encode('ascii')) + 1, 3800)
        code, notices = self.run_notice(value)
        self.assertEqual(code, 0)
        self.assertEqual(len(notices), 1)
        self.assertLessEqual(len(notices[0].encode('ascii')) + 1, 3800)
        report = self.decoded_report(notices[0])
        self.assertEqual(set(report), {'schemaVersion', 'sourceSHA', 'runID', 'attempt', 'status', 'files'})
        self.assertEqual(report['status'], 'found')
        self.assertTrue(sdk_notice.valid_files(report['files']))
        self.assertEqual({symbol for record in report['files'] for excerpt in record['excerpts'] for symbol in excerpt['symbols']}, set(sdk_notice.SYMBOLS))
        self.assertEqual(report['files'][0]['file'], value['files'][0]['file'])
        self.assertEqual(report['files'][0]['sha256'], value['files'][0]['sha256'])
        self.assertNotEqual(report['files'], value['files'])
        self.assertEqual(report['files'][0]['excerpts'][0]['firstLine'], 129)
        for excerpt in report['files'][0]['excerpts']:
            index = excerpt['firstLine'] - original['firstLine']
            self.assertEqual(excerpt['text'].splitlines(), lines[index:index + len(excerpt['text'].splitlines())])
        small = {'status': 'found', 'files': [self.record(self.excerpt(7, target))]}
        code, notices = self.run_notice(small)
        self.assertEqual(code, 0)
        self.assertEqual(self.decoded_report(notices[0])['files'], small['files'])
        separated = [self.excerpt(200 + 100 * index, '\n'.join(['// context ' + 'x' * 400] * 9
                     + [symbol] + ['// trailing context'] * 9)) for index, symbol in enumerate(sdk_notice.SYMBOLS)]
        code, notices = self.run_notice({'status': 'found', 'files': [self.record(*separated)]})
        self.assertEqual(code, 0)
        self.assertEqual(len(notices), 1)
        self.assertLessEqual(len(notices[0].encode('ascii')) + 1, 3800)
        self.assertEqual({symbol for record in self.decoded_report(notices[0])['files']
                          for excerpt in record['excerpts'] for symbol in excerpt['symbols']}, set(sdk_notice.SYMBOLS))

    def test_sdk_notice_skips_unfittable_whole_target_line_for_later_real_smaller_fragment(self):
        oversized = sdk_notice.SYMBOLS[0] + '\0' * 900
        small = 'public ' + ' '.join(sdk_notice.SYMBOLS)
        value = {'status': 'found', 'files': [self.record(self.excerpt(1, oversized), self.excerpt(90, small))]}
        self.assertTrue(sdk_notice.valid_files(value['files']))
        code, notices = self.run_notice(value)
        self.assertEqual(code, 0)
        self.assertEqual(len(notices), 1)
        self.assertLessEqual(len(notices[0].encode('ascii')) + 1, 3800)
        report = self.decoded_report(notices[0])
        self.assertEqual(report['files'][0]['excerpts'], [self.excerpt(90, small)])
        self.assertNotIn('\\u0000', notices[0])

    def test_sdk_notice_found_with_no_fitting_complete_target_line_has_no_partial_or_fake_not_found(self):
        value = {'status': 'found', 'files': [self.record(self.excerpt(1, sdk_notice.SYMBOLS[0] + '\0' * 900))]}
        self.assertTrue(sdk_notice.valid_files(value['files']))
        self.assertEqual(self.run_notice(value), (2, []))
        code, notices = self.run_notice({'status': 'notFound', 'files': []})
        self.assertEqual(code, 0)
        self.assertEqual(self.decoded_report(notices[0])['status'], 'notFound')
        self.assertEqual(self.decoded_report(notices[0])['files'], [])

    def test_sdk_notice_validates_every_input_record_before_selection_and_keeps_read_bounds(self):
        target = 'public ' + ' '.join(sdk_notice.SYMBOLS)
        good = self.record(self.excerpt(1, target))
        invalid = ({'status': 'found', 'files': [good, self.record(self.excerpt(1, target), name='PrivateSynthetic.h')]},
                   {'status': 'found', 'files': [good, {**self.record(self.excerpt(1, target)), 'sha256': 'wrong'}]},
                   {'status': 'found', 'files': [self.record({**self.excerpt(1, target), 'symbols': []})]},
                   {'status': 'found', 'files': [good], 'privateExtra': PRIVATE},
                   {'status': 'notFound', 'files': [good]})
        for value in invalid:
            with self.subTest(valueKind='invalidWholeInput'):
                self.assertEqual(self.run_notice(value), (2, []))
        duplicate = b'{"status":"found","status":"notFound","files":[]}'
        self.assertEqual(self.run_notice(raw=duplicate), (2, []))
        self.assertEqual(self.run_notice(raw=b' ' * (sdk_notice.MAX_INPUT + 1)), (2, []))


    def test_sdk_notice_oversize_prefers_three_real_declarations_over_function_parameter_references(self):
        from hashlib import sha256
        function = ('@available(macOS 14.0, *) @MainActor public func performAccessibilityAudit('
                    'for auditTypes: XCUIAccessibilityAuditType = .all, '
                    '_ issueHandler: ((XCUIAccessibilityAuditIssue) throws -> Bool)? = nil) throws')
        variants = (('SyntheticTypes.swiftinterface', '@objc public class XCUIAccessibilityAuditIssue : NSObject {',
                     'public struct XCUIAccessibilityAuditType : OptionSet {'),
                    ('SyntheticTypes.swiftinterface', 'public struct XCUIAccessibilityAuditIssue {',
                     'public enum XCUIAccessibilityAuditType : UInt {'),
                    ('SyntheticTypes.h', '@interface XCUIAccessibilityAuditIssue : NSObject',
                     'typedef NS_OPTIONS(NSUInteger, XCUIAccessibilityAuditType) {'))
        context = '// synthetic public context % \\ " 한글 ' + 'x' * 400
        for type_name, issue, audit_type in variants:
            with self.subTest(declarationKinds=(issue.split()[0], audit_type.split()[0])):
                function_lines = [context] * 5 + [function] + [context] * 5
                issue_lines = [context] * 3 + [issue] + ['    // exact adjacent whole body line', '}'] + [context] * 3
                type_lines = [context] * 3 + [audit_type] + ['    // exact adjacent whole body line', '}'] + [context] * 3
                function_whole = ['// synthetic preceding public line'] * 16 + function_lines
                type_whole = ['// synthetic preceding public line'] * 100 + issue_lines
                type_whole += ['// synthetic gap kept outside excerpts'] * (200 - len(type_whole)) + type_lines
                whole_sources = {'SyntheticPublic.swiftinterface': function_whole, type_name: type_whole}
                value = {'status': 'found', 'files': [
                    {**self.record(self.excerpt(17, '\r\n'.join(function_lines)), name='SyntheticPublic.swiftinterface'),
                     'sha256': sha256(('\n'.join(function_whole) + '\n').encode('utf-8')).hexdigest()},
                    {**self.record(self.excerpt(101, '\n'.join(issue_lines)), self.excerpt(201, '\n'.join(type_lines)), name=type_name),
                     'sha256': sha256(('\n'.join(type_whole) + '\n').encode('utf-8')).hexdigest()}]}
                self.assertTrue(sdk_notice.valid_files(value['files']))
                self.assertLessEqual(len(json.dumps(value, ensure_ascii=True).encode('ascii')), sdk_notice.MAX_INPUT)
                full_report = {'schemaVersion': 1, 'sourceSHA': 'a' * 40, 'runID': '1', 'attempt': '1', **value}
                self.assertIsNone(sdk_notice.encoded_notice(full_report))
                code, notices = self.run_notice(value)
                self.assertEqual(code, 0)
                self.assertEqual(len(notices), 1)
                self.assertLessEqual(len(notices[0].encode('ascii')) + 1, sdk_notice.MAX_NOTICE)
                report = self.decoded_report(notices[0])
                self.assertEqual(set(report), {'schemaVersion', 'sourceSHA', 'runID', 'attempt', 'status', 'files'})
                self.assertEqual(report['status'], 'found')
                self.assertTrue(sdk_notice.valid_files(report['files']))
                expected_hashes = {record['file']: record['sha256'] for record in value['files']}
                returned_lines = {}
                for record in report['files']:
                    self.assertEqual(record['sha256'], expected_hashes[record['file']])
                    source_lines = whole_sources[record['file']]
                    for excerpt in record['excerpts']:
                        start = excerpt['firstLine'] - 1
                        lines = excerpt['text'].splitlines()
                        self.assertEqual(lines, source_lines[start:start + len(lines)])
                        for offset, line in enumerate(lines):
                            returned_lines[(record['file'], excerpt['firstLine'] + offset)] = line
                self.assertEqual(returned_lines[('SyntheticPublic.swiftinterface', 22)], function)
                self.assertEqual(returned_lines[(type_name, 104)], issue)
                self.assertEqual(returned_lines[(type_name, 204)], audit_type)
                self.assertLessEqual(len(returned_lines), 9)


class PublicSDKContractContextTests(unittest.TestCase):
    # 기존 fixture helper만 재사용하며 원 다섯 사례를 중복 발견하는 상속은 하지 않는다.
    excerpt = PublicSDKNoticeBoundsTests.excerpt
    record = PublicSDKNoticeBoundsTests.record
    run_notice = PublicSDKNoticeBoundsTests.run_notice

    def contract_reports(self, notices):
        topics = ('auditType', 'element', 'handler')
        prefixes = {topic: '::notice::Public SDK audit ' + topic + ' context: ' for topic in topics}
        self.assertEqual(sdk_notice.CONTRACT_TOPICS, topics)
        self.assertEqual(sdk_notice.CONTRACT_PREFIXES, prefixes)
        self.assertEqual(sdk_notice.MAX_COMBINED_NOTICE, 4 * 3800)
        self.assertEqual(len(notices), 4)
        self.assertTrue(notices[0].startswith(sdk_notice.PREFIX))
        self.assertLessEqual(sum(len(notice.encode('ascii')) + 1 for notice in notices), 15200)
        reports = {}
        for topic, notice in zip(topics, notices[1:]):
            prefix = prefixes[topic]
            self.assertTrue(notice.startswith(prefix))
            self.assertLessEqual(len(notice.encode('ascii')) + 1, 3800)
            self.assertNotIn('\r', notice)
            self.assertNotIn('\n', notice)
            body = notice[len(prefix):].replace('%0D', '\r').replace('%0A', '\n').replace('%25', '%')
            report = json.loads(body)
            self.assertEqual(set(report), {'schemaVersion', 'sourceSHA', 'runID', 'attempt', 'status', 'files'})
            self.assertIs(type(report['schemaVersion']), int)
            self.assertEqual(report['schemaVersion'], 1)
            self.assertEqual((report['sourceSHA'], report['runID'], report['attempt']), ('a' * 40, '1', '1'))
            self.assertIn(report['status'], ('observedContext', 'unknown'))
            self.assertTrue(sdk_notice.valid_files(report['files']))
            if report['status'] == 'unknown':
                self.assertEqual(report['files'], [])
            else:
                self.assertTrue(report['files'])
            reports[topic] = report
        return reports


    def test_contract_notices_are_opt_in_and_preserve_the_legacy_notice_exactly(self):


        # 합성 reference의 원공지 수용은 실제 API 증거가 아니다.
        value = {'status': 'found', 'files': [self.record(self.excerpt(17,
                 'public ' + ' '.join(sdk_notice.SYMBOLS) + ' // synthetic references only'))]}
        legacy_code, legacy = self.run_notice(value)
        enabled_code, enabled = self.run_notice({**value, 'auditContractContext': True})
        self.assertEqual((legacy_code, len(legacy)), (0, 1))
        self.assertEqual(enabled_code, 0)
        self.assertEqual(enabled[0], legacy[0])
        reports = self.contract_reports(enabled)
        self.assertEqual([reports[topic]['status'] for topic in ('auditType', 'element', 'handler')],
                         ['unknown', 'unknown', 'unknown'])
        self.assertNotIn('auditContractContext', PublicSDKNoticeBoundsTests.decoded_report(self, enabled[0]))

    def test_synthetic_swift_and_objc_owner_members_and_handler_comments_keep_actual_whole_lines(self):


        def actual_lines(report, sources, digests):
            returned = []
            for record in report['files']:
                self.assertEqual(record['sha256'], digests[record['file']])
                for excerpt in record['excerpts']:
                    first = excerpt['firstLine'] - 1
                    lines = excerpt['text'].splitlines()
                    self.assertEqual(lines, sources[record['file']][first:first + len(lines)])
                    self.assertEqual(excerpt['symbols'], [symbol for symbol in sdk_notice.SYMBOLS
                                                          if symbol in excerpt['text']])
                    returned.extend(lines)
            return returned


        from hashlib import sha256
        swift_handler = ['/// Synthetic handler context % \\ " 한글; Bool meaning is not asserted.',
                         '@MainActor public func performAccessibilityAudit(',
                         '    for auditTypes: XCUIAccessibilityAuditType = .all,',
                         '    _ issueHandler: ((XCUIAccessibilityAuditIssue) throws -> Bool)? = nil',
                         ') throws']
        objc_handler = ['/** Synthetic handler context % \\ " 한글; BOOL meaning is not asserted. */',
                        '- (void)syntheticPublicAuditSelector:(XCUIAccessibilityAuditType)auditTypes',
                        '                    withIssueHandler:(BOOL (^)(XCUIAccessibilityAuditIssue *issue))issueHandler',
                        '                    NS_SWIFT_NAME(performAccessibilityAudit(for:_:));']
        variants = [('SyntheticIssueClass.swiftinterface', 'public class XCUIAccessibilityAuditIssue : NSObject {',
                     '    public var auditType: XCUIAccessibilityAuditType { get }',
                     '    public var element: XCUIElement? { get }', '}', swift_handler),
                    ('SyntheticIssueStruct.swiftinterface', 'public struct XCUIAccessibilityAuditIssue {',
                     '    public var auditType: XCUIAccessibilityAuditType { get }',
                     '    public var element: XCUIElement? { get }', '}', swift_handler),
                    ('SyntheticIssue.h', '@interface XCUIAccessibilityAuditIssue : NSObject',
                     '@property (nonatomic, readonly) XCUIAccessibilityAuditType auditType;',
                     '@property (nullable, nonatomic, readonly) XCUIElement *element;', '@end', objc_handler),
                    ('SyntheticCollectionHandler.swiftinterface', 'public class XCUIAccessibilityAuditIssue : NSObject {',
                     '    public var auditType: XCUIAccessibilityAuditType { get }',
                     '    public var element: XCUIElement? { get }', '}',
                     ['public func performAccessibilityAudit(for types: XCUIAccessibilityAuditType, '
                      '_ metadata: [SyntheticKey: XCUIAccessibilityAuditIssue], '
                      '_ issueHandler: ((XCUIAccessibilityAuditIssue) throws -> Bool)? = nil) throws'])]
        for name, owner, audit_type, element, end, handler in variants:
            with self.subTest(syntheticPublicFile=name):
                first = 41
                excerpt_lines = [' * synthetic public comment continuation', ' */', owner, '// synthetic owner context', audit_type, element, end, ''] + handler
                whole = ['// synthetic preceding line'] * (first - 1) + excerpt_lines
                digest = sha256(('\n'.join(whole) + '\n').encode('utf-8')).hexdigest()
                record = {**self.record(self.excerpt(first, '\r\n'.join(excerpt_lines)), name=name), 'sha256': digest}
                value = {'status': 'found', 'files': [record], 'auditContractContext': True}
                code, notices = self.run_notice(value)
                self.assertEqual(code, 0)
                reports = self.contract_reports(notices)
                for topic, target in (('auditType', audit_type), ('element', element)):
                    self.assertEqual(reports[topic]['status'], 'observedContext')
                    lines = actual_lines(reports[topic], {name: whole}, {name: digest})
                    self.assertIn(owner, lines)
                    self.assertIn(target, lines)
                self.assertEqual(reports['handler']['status'], 'observedContext')
                lines = actual_lines(reports['handler'], {name: whole}, {name: digest})
                for actual in handler:
                    self.assertIn(actual, lines)
                # 합성 source 발췌이며 Bool 해석이나 실제 API 존재를 판정하지 않는다.
                for report in reports.values():
                    self.assertNotIn('handlerReturnsTrueMeans', report)
                    self.assertNotIn('handlerReturnsFalseMeans', report)
                    self.assertNotIn('apiAvailable', report)

    def test_unrelated_commented_missing_and_unfittable_contracts_stay_unknown(self):


        unrelated = '\n'.join(['public class UnrelatedPublicIssue {',
                     '    public var auditType: XCUIAccessibilityAuditType { get }',
                     '    public var element: XCUIElement? { get }', '}',
                     '// XCUIAccessibilityAuditIssue is only a synthetic reference here.',
                     '// public func performAccessibilityAudit(_ issueHandler: ((XCUIAccessibilityAuditIssue) throws -> Bool)?)',
                     '// ' + PRIVATE])
        missing = '\n'.join(['public class XCUIAccessibilityAuditIssue : NSObject {', '}',
                   'public struct XCUIAccessibilityAuditType : OptionSet { }',
                   '// performAccessibilityAudit is a synthetic reference, without a declaration.'])
        oversized = '\n'.join(['public class XCUIAccessibilityAuditIssue : NSObject {',
                     '    public var auditType: XCUIAccessibilityAuditType { get } // ' + '\0' * 800,
                     '    public var element: XCUIElement? { get } // ' + '\0' * 800, '}',
                     'public struct XCUIAccessibilityAuditType : OptionSet { }',
                     'public func performAccessibilityAudit(_ issueHandler: ((XCUIAccessibilityAuditIssue) throws -> Bool)?) throws // ' + '\0' * 800])
        adjacent_swift = '\n'.join([
            'public func performAccessibilityAudit(for types: XCUIAccessibilityAuditType) throws',
            'public func unrelated(issueHandler: XCUIAccessibilityAuditIssue) throws'])
        interrupted_swift = '\n'.join([
            'public func performAccessibilityAudit(',
            '    for types: XCUIAccessibilityAuditType,',
            'public func unrelated(issueHandler: XCUIAccessibilityAuditIssue) throws'])
        adjacent_objc = '\n'.join([
            '- (void)performAccessibilityAudit:(XCUIAccessibilityAuditType)types;',
            '- (void)unrelatedWithTypes:(XCUIAccessibilityAuditType)types',
            '    withIssueHandler:(BOOL (^)(XCUIAccessibilityAuditIssue *issue))issueHandler;'])
        closed_then_parameter = '\n'.join([
            'public func performAccessibilityAudit(for types: XCUIAccessibilityAuditType) throws',
            '    issueHandler: ((XCUIAccessibilityAuditIssue) throws -> Bool)?'])
        attribute_only = ('@Synthetic(issueHandler: XCUIAccessibilityAuditIssue.self) '
                          'public func performAccessibilityAudit(for types: XCUIAccessibilityAuditType) throws')
        same_line_swift = ('public func performAccessibilityAudit(for types: XCUIAccessibilityAuditType) throws; '
                           'public func unrelated(issueHandler: XCUIAccessibilityAuditIssue) throws')
        same_line_objc = ('- (void)performAccessibilityAudit:(XCUIAccessibilityAuditType)types; '
                         '- (void)unrelatedWithIssueHandler:(XCUIAccessibilityAuditIssue *)issueHandler;')
        nested_tuple = ('public func performAccessibilityAudit(for types: XCUIAccessibilityAuditType, '
                        '_ callback: (issueHandler: XCUIAccessibilityAuditIssue) -> Void) throws')
        dictionary_type = ('public func performAccessibilityAudit(for types: XCUIAccessibilityAuditType, '
                           '_ callback: [issueHandler: XCUIAccessibilityAuditIssue]) throws')
        array_type = ('public func performAccessibilityAudit(for types: XCUIAccessibilityAuditType, '
                      '_ callback: [[issueHandler: XCUIAccessibilityAuditIssue]]) throws')
        multiline_array_type = '\n'.join([
            'public func performAccessibilityAudit(',
            '    for types: XCUIAccessibilityAuditType,',
            '    _ callback: [',
            '        [issueHandler: XCUIAccessibilityAuditIssue]',
            '    ]) throws'])
        # 인접 선언/닫힌 signature/속성/collection 타입의 이름을 실제 handler parameter로 합치지 않는다.
        for kind, text in (('unrelatedAndCommented', unrelated), ('missing', missing), ('unfittable', oversized),
                           ('adjacentSwiftDeclaration', adjacent_swift), ('interruptedSwiftSignature', interrupted_swift),
                           ('adjacentObjectiveCDeclaration', adjacent_objc), ('closedSignatureThenParameter', closed_then_parameter),
                           ('attributeArgumentOnly', attribute_only), ('sameLineSwiftDeclaration', same_line_swift),
                           ('sameLineObjectiveCDeclaration', same_line_objc), ('nestedTupleNameOnly', nested_tuple),
                           ('dictionaryTypeNameOnly', dictionary_type), ('arrayTypeNameOnly', array_type),
                           ('multilineArrayTypeNameOnly', multiline_array_type)):
            with self.subTest(syntheticContext=kind):
                value = {'status': 'found', 'files': [self.record(self.excerpt(31, text), name='SyntheticContext.swiftinterface')],
                         'auditContractContext': True}
                self.assertTrue(sdk_notice.valid_files(value['files']))
                code, notices = self.run_notice(value)
                self.assertEqual(code, 0)
                reports = self.contract_reports(notices)
                self.assertTrue(all(report['status'] == 'unknown' and report['files'] == []
                                    for report in reports.values()))
                for notice in notices[1:]:
                    self.assertNotIn(PRIVATE, notice)
                    self.assertNotIn('\\u0000', notice)
                self.assertEqual(PublicSDKNoticeBoundsTests.decoded_report(self, notices[0])['status'], 'found')
        no_declaration = {'status': 'found', 'files': [self.record(self.excerpt(1,
                          'performAccessibilityAudit' + '\0' * 900))], 'auditContractContext': True}
        self.assertEqual(self.run_notice(no_declaration), (2, []))

    def test_contract_input_is_fully_validated_before_any_notice_and_all_wire_budgets_include_escaping(self):


        context = '// synthetic escaping % \\ " 한글 ' + 'x' * 350
        lines = ['public class XCUIAccessibilityAuditIssue : NSObject {'] + [context] * 4 + [
                 '    public var auditType: XCUIAccessibilityAuditType { get }',
                 '    public var element: XCUIElement? { get }', '}', context,
                 'public func performAccessibilityAudit(_ issueHandler: ((XCUIAccessibilityAuditIssue) throws -> Bool)?) throws']
        good = self.record(self.excerpt(15, '\r\n'.join(lines)), name='SyntheticEscaping.swiftinterface')
        value = {'status': 'found', 'files': [good], 'auditContractContext': True}
        code, notices = self.run_notice(value)
        self.assertEqual(code, 0)
        reports = self.contract_reports(notices)
        self.assertEqual([report['status'] for report in reports.values()], ['observedContext'] * 3)
        self.assertIn('%25', ''.join(notices[1:]))
        self.assertIn('\\u', ''.join(notices[1:]))
        self.assertNotIn('한글', ''.join(notices))
        self.assertLessEqual(sum(len(notice.encode('ascii')) + 1 for notice in notices), 4 * 3800)
        bad_flags = [{**value, 'auditContractContext': flag} for flag in (False, 1, 'true')]
        invalid = bad_flags + [{**value, 'privateExtra': PRIVATE},
                   {**value, 'files': [good, {**good, 'file': 'PrivateSynthetic.swiftinterface'}]},
                   {**value, 'files': [good, {**good, 'file': 'SyntheticBadLast.swiftinterface', 'sha256': 'bad'}]}]
        for bad in invalid:
            with self.subTest(invalidContractInput=True):
                self.assertEqual(self.run_notice(bad), (2, []))
        duplicate = (b'{"status":"notFound","files":[],"auditContractContext":true,'
                     b'"auditContractContext":true}')
        self.assertEqual(self.run_notice(raw=duplicate), (2, []))
        self.assertEqual(self.run_notice(raw=b' ' * (64 * 1024 + 1)), (2, []))

if __name__ == '__main__':
    unittest.main()
