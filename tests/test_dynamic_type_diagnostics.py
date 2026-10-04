"""진단만의 SDK 계약·사례 소유·실제 관측·원문 비공개 경계. Actions에서 실행한다."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('dynamic_type_diagnostics', ROOT / 'scripts/ci-dynamic-type-diagnostics.py')
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
PRIVATE = 'SYNTHETIC_PRIVATE_PATH_OR_AX_VALUE'
EXPECTED = {'platform': 'ipad', 'appearance': 'system', 'commitSHA': 'a' * 40,
            'buildNumber': '1', 'runID': '10', 'runAttempt': '1'}


def event(state):
    suffix = '.' if state == 'started' else ' (1.234 seconds).'
    return "Test Case '-[" + helper.OWNER + ' ' + helper.CASE + "]' " + state + suffix


def probe(scope_name, mode='system', **changes):
    return {'schemaVersion': 1, 'requestedMode': mode, 'actualMode': mode, 'scope': scope_name,
            'swiftUI': 'accessibility5', 'uiKit': 'accessibilityExtraExtraExtraLarge',
            'uiKitSource': 'appSystem', **changes}


def observed_log(mode='system', failed=False):
    lines = [event('started'), helper.PROBE + json.dumps(probe('root', mode)),
             helper.PROBE + json.dumps(probe('capture', mode))]
    if failed:
        lines.append(helper.AUDIT + json.dumps({'schemaVersion': 1, 'requestedMode': mode,
            'auditSequence': 1, 'issueSequence': 1, 'types': ['dynamicType'], 'ignored': False}))
    lines.extend((helper.A.AUDIT_BOUNDARY_MARKER + json.dumps({'schemaVersion': 1,
        'case': 'captureValidation', 'auditSequence': 1, 'outcome': 'threw' if failed else 'returned'}),
        event('failed' if failed else 'passed')))
    return '\n'.join(lines)


def typed(failed=False):
    state = 'Failed' if failed else 'Passed'
    summary = {'totalTestCount': 1, 'passedTests': 0 if failed else 1,
               'failedTests': 1 if failed else 0, 'skippedTests': 0}
    tree = {'testNodes': [{'nodeType': 'UI test bundle', 'name': 'MirrorIOSAdaptiveUITests',
                          'result': state, 'children': [
        {'nodeType': 'Test Case', 'name': helper.CASE + '()', 'result': state}]}]}
    return summary, tree


def public_help(listing=None):
    return ('Usage: simctl ui <device> <option> [<arguments>]\nSupported options:\n  content_size\n'
            + ('\n'.join('    ' + value for value in helper.CATEGORIES) if listing is None else listing))


class DynamicTypeDiagnosticsTests(unittest.TestCase):
    def test_public_help_requires_usage_standalone_operation_and_every_exact_category(self):
        text = public_help()
        self.assertTrue(helper.supports_ui(text))
        for wrong in (text.replace('[<arguments>]', '<arguments>'),
                      text.replace('content_size', 'content_size_extra'),
                      text.replace('  content_size\n', '  content_size\n  another_operation\n'),
                      text.replace(helper.CATEGORIES[-1], helper.CATEGORIES[-1] + '_extra'),
                      'mentions content_size ' + ' '.join(helper.CATEGORIES), '', PRIVATE):
            with self.subTest(wrong=wrong), mock.patch.object(helper, 'native', return_value=0) as native, \
                    mock.patch.object(helper, 'output', side_effect=[wrong, '']), \
                    mock.patch.object(helper.A, 'write_json') as write:
                with self.assertRaises(helper.A.AdaptiveError):
                    helper.execute('help', None, EXPECTED, {})
                self.assertEqual(native.call_args_list, [mock.call(['xcrun', 'simctl', 'help', 'ui'], 'ui-help')])
                write.assert_not_called()

    def test_empty_stdout_and_complete_stderr_verify_the_same_contract_after_one_native_call(self):
        with tempfile.TemporaryDirectory() as temp, mock.patch.object(helper, 'DIRECTORY', Path(temp).resolve()), \
                mock.patch.object(helper, 'native', return_value=0) as native:
            (Path(temp) / 'ui-help.stdout').write_bytes(b'')
            (Path(temp) / 'ui-help.stderr').write_text(public_help())
            report = {}
            helper.execute('help', None, EXPECTED, report)
            self.assertEqual(report['contractFrom'], 'stderr')
            self.assertEqual(report['helpStreams']['stdout']['bytes'], 0)
            self.assertEqual(report['helpStreams']['stderr']['bytes'], len(public_help().encode()))
            self.assertEqual(report['helpStreams']['stderr']['knownCategoryCount'], 12)
            self.assertTrue(report['publicUIContractVerified'])
            self.assertEqual(report['nativeHelpExitCode'], 0)
            self.assertTrue(json.loads((Path(temp) / 'contract.json').read_text())['supported'])
            native.assert_called_once_with(['xcrun', 'simctl', 'help', 'ui'], 'ui-help')

    def test_identical_help_in_two_streams_counts_once_without_combining_partial_or_conflicting_streams(self):
        report, digest = helper.help_contract(public_help(), public_help())
        self.assertEqual(report['contractFrom'], 'both')
        self.assertEqual(report['uniqueHelpCount'], 1)
        self.assertEqual(digest, helper.help_contract(public_help(), '')[1])
        alternate = public_help().replace('<option>', '<operation>')
        report, _ = helper.help_contract(public_help(), alternate)
        self.assertEqual(report['contractFrom'], 'both')
        self.assertEqual(report['uniqueHelpCount'], 2)
        header, body = public_help().split('\n', 1)
        report, digest = helper.help_contract(header, body)
        self.assertEqual(report['contractFrom'], 'none')
        self.assertFalse(report['publicUIContractVerified'])
        self.assertIsNone(digest)
        conflicting = public_help().replace('content_size', 'another_operation')
        report, digest = helper.help_contract(conflicting, public_help())
        self.assertEqual(report['contractFrom'], 'stderr')
        self.assertFalse(report['helpStreams']['stdout']['supported'])
        self.assertEqual(digest, helper.help_contract('', public_help())[1])

    def test_native_nonzero_cannot_be_overridden_by_valid_help_in_either_stream(self):
        with mock.patch.object(helper, 'native', return_value=64), \
                mock.patch.object(helper, 'output', return_value=public_help()), \
                mock.patch.object(helper.A, 'write_json') as write:
            report = {}
            with self.assertRaises(helper.A.AdaptiveError):
                helper.execute('help', None, EXPECTED, report)
            self.assertEqual(report['contractFrom'], 'both')
            self.assertEqual(report['nativeHelpExitCode'], 64)
            write.assert_not_called()

    def test_scoped_complete_category_list_accepts_only_equivalent_separators(self):
        values = helper.CATEGORIES
        listings = {
            'standalone': '\n'.join('    ' + value for value in values),
            'bullet': '\n'.join('    - ' + value for value in values),
            'commaList': '    ' + ', '.join(values),
            'table': '\n'.join('    | ' + ' | '.join(values[index:index + 3]) + ' |'
                               for index in range(0, len(values), 3)),
        }
        for kind, listing in listings.items():
            with self.subTest(kind=kind):
                text = public_help('    Valid values:\n' + '\n'.join('    ' + line for line in listing.splitlines()))
                self.assertTrue(helper.supports_ui(text))
                metadata = helper.help_metadata(text)
                self.assertEqual(metadata['knownCategories'], list(values))
                self.assertEqual(metadata['categoryFormat'], kind)
                self.assertTrue(metadata['categoryListComplete'])
                report, _ = helper.help_contract('', text)
                self.assertEqual(report['contractFrom'], 'stderr')
        wrapped = '\n'.join('    ' + ', '.join(values[index:index + 3]) + (',' if index < 9 else '')
                            for index in range(0, len(values), 3))
        self.assertTrue(helper.supports_ui(public_help(wrapped)))
        columns = '\n'.join('    ' + '\t'.join(values[index:index + 3]) for index in range(0, len(values), 3))
        self.assertTrue(helper.supports_ui(public_help(columns)))

    def test_zero_column_and_indented_headings_require_the_same_complete_scoped_list(self):
        for indent in ('', '  ', '\t'):
            with self.subTest(indent=repr(indent)):
                text = ('Usage: simctl ui <device> <option> [<arguments>]\n'
                        + indent + 'content_size\n\n'
                        + '\n'.join(indent + '    ' + value for value in helper.CATEGORIES)
                        + '\n' + indent + 'appearance\n' + indent + '    ' + PRIVATE)
                metadata = helper.help_metadata(text)
                self.assertTrue(metadata['supported'])
                self.assertEqual(metadata['sectionCount'], 1)
                self.assertEqual(metadata['headingIndent'], len(indent))
                self.assertEqual(metadata['firstFollowingIndent'], len(indent) + 4)
                self.assertEqual(metadata['firstBodyIndent'], len(indent) + 4)
                self.assertEqual(metadata['knownCategoryCount'], 12)
                self.assertEqual(metadata['wholeHelpTokensPresentCount'], 12)
                self.assertNotIn(PRIVATE, json.dumps(metadata))

    def test_zero_column_heading_does_not_merge_other_options_paragraphs_or_streams(self):
        prefix = 'Usage: simctl ui <device> <option> [<arguments>]\ncontent_size\n'
        first = '\n'.join('    ' + value for value in helper.CATEGORIES[:6])
        last = '\n'.join('    ' + value for value in helper.CATEGORIES[6:])
        complete = first + '\n' + last
        for body in (first + '\nappearance\n' + last, first + '\n\n' + last,
                     'appearance\n' + complete, '  appearance\n' + complete,
                     complete + '\n    unknown-category', first + '\n  content_size\n' + last):
            with self.subTest(body=body):
                self.assertFalse(helper.supports_ui(prefix + body))
        report, _ = helper.help_contract(prefix + first, prefix + last)
        self.assertEqual(report['contractFrom'], 'none')
        duplicate = helper.help_metadata(prefix + first + '\n  content_size\n' + last)
        self.assertEqual(duplicate['sectionCount'], 2)
        self.assertIsNone(duplicate['headingIndent'])
        self.assertFalse(duplicate['categoryListComplete'])

    def test_shape_metadata_distinguishes_no_section_outside_tokens_and_unindented_body(self):
        categories = '\n'.join('    ' + value for value in helper.CATEGORIES)
        outside = helper.help_metadata('appearance\n' + categories + '\n' + PRIVATE)
        self.assertEqual(outside['sectionCount'], 0)
        self.assertIsNone(outside['headingIndent'])
        self.assertEqual(outside['wholeHelpTokensPresent'], list(helper.CATEGORIES))
        self.assertEqual(outside['knownTokensPresentCount'], 0)
        self.assertFalse(outside['supported'])
        unindented = helper.help_metadata('content_size\n' + ', '.join(helper.CATEGORIES))
        self.assertEqual(unindented['sectionCount'], 1)
        self.assertEqual(unindented['headingIndent'], 0)
        self.assertEqual(unindented['firstFollowingIndent'], 0)
        self.assertIsNone(unindented['firstBodyIndent'])
        self.assertEqual(unindented['wholeHelpTokensPresentCount'], 12)
        self.assertEqual(unindented['knownTokensPresentCount'], 0)
        self.assertFalse(unindented['categoryListComplete'])
        self.assertNotIn(PRIVATE, json.dumps(outside))

    def test_category_contract_rejects_fragments_unknown_words_duplicates_and_cross_option_lists(self):
        values = helper.CATEGORIES
        lines = ['    ' + value for value in values]
        valid = '\n'.join(lines)
        invalid = (
            '\n'.join(lines[:-1]), valid + '\n' + lines[0],
            valid.replace(values[-1], values[-1] + '_extra'),
            '    ' + ' '.join(values), '    ' + ', '.join(values) + ', ' + PRIVATE,
            valid + '\n    unknown-category', valid + '\n    ' + PRIVATE,
            '\n'.join(lines[:6] + [''] + lines[6:]),
            '\n'.join(lines[:6] + ['    ' + PRIVATE] + lines[6:]),
            '\n'.join(lines[:6] + ['  another_operation'] + lines[6:]),
            '\n'.join(lines[:6] + ['  content_size'] + lines[6:]),
            '\n'.join(lines[:6] + ['    ' + line for line in lines[6:]]),
            valid.replace('    extra-small', '    -extra-small'),
            valid.replace('    extra-small', '    extra-small / small'),
        )
        for listing in invalid:
            with self.subTest(listing=listing):
                text = public_help(listing)
                self.assertFalse(helper.supports_ui(text))
                self.assertNotIn(PRIVATE, json.dumps(helper.help_metadata(text)))
        report, _ = helper.help_contract(public_help('\n'.join(lines[:6])), public_help('\n'.join(lines[6:])))
        self.assertEqual(report['contractFrom'], 'none')
        self.assertFalse(report['publicUIContractVerified'])
        outside = public_help().replace('  content_size', '  another_operation') + '\n  content_size\n    No values'
        metadata = helper.help_metadata(outside)
        self.assertEqual(metadata['knownCategoryCount'], 0)
        self.assertEqual(metadata['categoryFormat'], 'none')
        self.assertFalse(metadata['supported'])

    def test_fixed_inline_declaration_is_one_complete_list_independent_of_prior_prose(self):
        values = ', '.join(helper.CATEGORIES)
        for prefix in ('Valid sizes:', 'Valid values:'):
            for period in ('', '.'):
                with self.subTest(prefix=prefix, period=period):
                    text = public_help('    Earlier descriptive prose.\n    ' + prefix + ' ' + values + period
                                       + '\n    Later descriptive prose.')
                    metadata = helper.help_metadata(text)
                    self.assertTrue(metadata['supported'])
                    self.assertTrue(metadata['categoryListComplete'])
                    self.assertEqual(metadata['categoryFormat'], 'inlineDeclaration')
                    self.assertEqual(metadata['knownCategories'], list(helper.CATEGORIES))
                    self.assertEqual(metadata['knownTokensPresent'], list(helper.CATEGORIES))
        invalid = (
            'Valid sizes: ' + ', '.join(helper.CATEGORIES[:-1]),
            'Valid sizes: ' + values + ', unknown-category',
            'Valid sizes: ' + values + '_extra',
            'Valid sizes: ' + values + '. ' + PRIVATE,
            'Valid sizes: ' + values + ', ' + helper.CATEGORIES[0],
            'Valid sizes: ' + ', '.join(helper.CATEGORIES[:6]) + ',\n    ' + ', '.join(helper.CATEGORIES[6:]),
            'Unknown sizes: ' + values, 'Example Valid sizes: ' + values,
            'Valid sizes:' + ' ' * 512 + values,
        )
        for declaration in invalid:
            with self.subTest(declaration=declaration):
                text = public_help('    ' + declaration)
                self.assertFalse(helper.supports_ui(text))
                self.assertNotIn(PRIVATE, json.dumps(helper.help_metadata(text)))

    def test_scoped_fixed_token_presence_does_not_accept_unknown_list_grammar(self):
        text = public_help('    ' + PRIVATE + ': ' + ', '.join(helper.CATEGORIES) + '.')
        metadata = helper.help_metadata(text)
        self.assertEqual(metadata['knownTokensPresent'], list(helper.CATEGORIES))
        self.assertEqual(metadata['knownTokensPresentCount'], 12)
        self.assertEqual(metadata['knownCategories'], [])
        self.assertFalse(metadata['categoryListComplete'])
        self.assertFalse(metadata['supported'])
        self.assertNotIn(PRIVATE, json.dumps(metadata))
        text = public_help('    Tokens: extra-small, small_extra, extra-smallish, élarge, medium2.'
                           '\n  another_operation\n    large, medium')
        metadata = helper.help_metadata(text)
        self.assertEqual(metadata['knownTokensPresent'], ['extra-small'])
        self.assertEqual(metadata['knownTokensPresentCount'], 1)
        self.assertFalse(metadata['supported'])

    def test_help_metadata_exposes_only_bounded_static_usage_and_operation_syntax(self):
        usage = 'Usage:simctl ui <device> <option> [<arguments>]'
        operation = 'content_size [<size> | increase | decrease]'
        invalid = ('content_size ' + PRIVATE, 'Usage: simctl ui ' + PRIVATE,
                   'content_size <' + PRIVATE + '>', 'Usage: simctl ui <' + PRIVATE + '>',
                   'content_size /private/' + PRIVATE, 'Usage: simctl ui /Users/' + PRIVATE,
                   'content_size <sïze>', 'content_size <size> # ' + PRIVATE,
                   'content_size <' + 'x' * 100 + '>', 'SDK error: ' + PRIVATE)
        text = '\n'.join((usage, operation, operation, *invalid, '    large', '    made-up-category'))
        metadata = helper.help_metadata(text)
        self.assertEqual(metadata['safeLines'], [usage, operation])
        self.assertEqual(metadata['knownCategories'], [])
        self.assertEqual(metadata['knownCategoryCount'], 0)
        self.assertEqual(metadata['categoryFormat'], 'none')
        self.assertEqual(metadata['bytes'], len(text.encode('utf-8')))
        self.assertNotIn(PRIVATE, json.dumps(metadata))
        self.assertFalse(metadata['supported'])

    def test_missing_contract_stops_before_boot_query_or_set(self):
        with mock.patch.object(helper.A, 'read_json', return_value={'supported': False}), \
                mock.patch.object(helper, 'context') as context, mock.patch.object(helper, 'command') as command:
            with self.assertRaises(helper.A.AdaptiveError):
                helper.execute('setup', None, EXPECTED, {})
            context.assert_not_called()
            command.assert_not_called()

    def test_system_categories_are_exact_public_enums(self):
        self.assertEqual(helper.category('large\n'), 'large')
        for wrong in ('large\n' + PRIVATE, 'LARGE', '', 'UICTContentSizeCategoryL', '../' + PRIVATE):
            with self.subTest(value=wrong), self.assertRaises(helper.A.AdaptiveError):
                helper.category(wrong)

    def test_typed_exact_one_case_accepts_observed_failure_without_claiming_pass(self):
        self.assertEqual(helper.verify_typed(*typed()), 'passed')
        self.assertEqual(helper.verify_typed(*typed(True)), 'failed')
        for field, value in (('totalTestCount', 0), ('totalTestCount', 4), ('passedTests', True),
                             ('skippedTests', 1), ('failedTests', 1)):
            summary, tree = typed()
            summary[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(helper.A.AdaptiveError):
                helper.verify_typed(summary, tree)
        for change in ('wrongOwner', 'wrongMethod', 'duplicate', 'wrongResult'):
            summary, tree = typed()
            bundle = tree['testNodes'][0]
            if change == 'wrongOwner': bundle['name'] = PRIVATE
            if change == 'wrongMethod': bundle['children'][0]['name'] = PRIVATE
            if change == 'duplicate': bundle['children'] *= 2
            if change == 'wrongResult': bundle['children'][0]['result'] = 'Failed'
            with self.subTest(change=change), self.assertRaises(helper.A.AdaptiveError):
                helper.verify_typed(summary, tree)

    def test_each_arm_observes_actual_app_system_and_view_maximum(self):
        for mode in helper.MODES:
            for failed in (False, True):
                result = helper.observations(observed_log(mode, failed), mode, 'failed' if failed else 'passed')
                self.assertTrue(result['maximumProbesVerified'])
                self.assertEqual(result['auditIssueTypes'], [['dynamicType']] if failed else [])
                self.assertEqual(result['auditOutcome'], 'threw' if failed else 'returned')

    def test_native_failed_case_can_end_after_owned_issue_without_swift_catch_returning(self):
        lines = observed_log(failed=True).splitlines()
        log = '\n'.join(line for line in lines if not line.startswith(helper.A.AUDIT_BOUNDARY_MARKER))
        observed = helper.observations(log, 'system', 'failed')
        self.assertEqual(observed['auditOutcome'], 'notReturned')
        self.assertEqual(observed['auditIssueTypes'], [['dynamicType']])
        with self.assertRaises(helper.A.AdaptiveError):
            helper.observations(log.replace("' failed ", "' passed "), 'system', 'passed')
        with self.assertRaises(helper.A.AdaptiveError):
            helper.observations('\n'.join(line for line in log.splitlines()
                                           if not line.startswith(helper.AUDIT)), 'system', 'failed')

    def test_cached_mode_or_runner_trait_cannot_replace_target_app_observation(self):
        for changes in ({'actualMode': 'pinned'}, {'requestedMode': 'pinned'}, {'scope': 'review'},
                        {'swiftUI': 'large'}, {'uiKit': 'large'}, {'uiKitSource': 'viewTrait'},
                        {'schemaVersion': True}, {PRIVATE: PRIVATE}):
            lines = observed_log().splitlines()
            lines[1] = helper.PROBE + json.dumps(probe('root', **changes))
            with self.subTest(changes=changes), self.assertRaises(helper.A.AdaptiveError):
                helper.observations('\n'.join(lines), 'system', 'passed')

    def test_case_ownership_marker_order_and_audit_completion_are_required(self):
        log = observed_log()
        lines = log.splitlines()
        bad = (log.replace(helper.OWNER, 'Foreign.Owner'), log.replace(helper.CASE, 'testForeign'),
               '\n'.join(lines[1:]), log + '\n' + lines[1], '\n'.join(lines[:2] + lines[1:]),
               '\n'.join((lines[0], lines[2], lines[1], *lines[3:])), '\n'.join(lines[:3] + lines[4:]),
               log.replace('returned', 'threw'), '\n'.join(lines[:-1]), log + '\n' + event('started'),
               log.replace('Test Case ', 'Test  Case '), log.replace(helper.PROBE, 'SDK said ' + helper.PROBE))
        for wrong in bad:
            with self.subTest(wrong=wrong), self.assertRaises(helper.A.AdaptiveError):
                helper.observations(wrong, 'system', 'passed')

    def test_unknown_and_malformed_native_issue_kinds_never_become_evidence(self):
        lines = observed_log(failed=True).splitlines()
        original = json.loads(lines[3][len(helper.AUDIT):])
        for changes in ({'types': [PRIVATE]}, {'types': []}, {'types': ['contrast', 'contrast']},
                        {'ignored': True}, {'auditSequence': True}, {'issueSequence': 2},
                        {'requestedMode': 'pinned'}, {PRIVATE: PRIVATE}):
            bad = [*lines]
            bad[3] = helper.AUDIT + json.dumps({**original, **changes})
            with self.subTest(changes=changes), self.assertRaises(helper.A.AdaptiveError):
                helper.observations('\n'.join(bad), 'system', 'failed')
        for malformed in ('{', '[]', '{"schemaVersion":1,"schemaVersion":1}', 'NaN'):
            bad = [*lines]
            bad[3] = helper.AUDIT + malformed
            with self.subTest(malformed=malformed), self.assertRaises((helper.A.AdaptiveError, ValueError)):
                helper.observations('\n'.join(bad), 'system', 'failed')

    def test_restore_journal_precedes_mutation_and_uses_same_context_only(self):
        ctx, sequence, saved = {'destination': 'fixed-context'}, [], {}
        def write(path, value, **kwargs):
            sequence.append('journal')
            saved.update(value)
        def command(args, name):
            sequence.append(name)
            if name == 'devices': return json.dumps({'devices': {'runtime': [{'udid': 'fixed-udid', 'state': 'Booted'}]}})
            if name == 'category-before': return 'large'
            if name == 'category-after': return helper.CATEGORIES[-1]
            if name == 'category-restored': return 'large'
            return ''
        with mock.patch.object(helper.A, 'read_json', side_effect=lambda path:
                               {'supported': True} if path.name == 'contract.json' else saved), \
                mock.patch.object(helper, 'context', return_value=(ctx, 'fixed-udid')), \
                mock.patch.object(helper.A, 'verify_receipt', return_value='fixed-receipt'), \
                mock.patch.object(helper, 'native', return_value=0), mock.patch.object(helper.A, 'write_json', side_effect=write), \
                mock.patch.object(helper, 'command', side_effect=command) as native:
            helper.execute('setup', None, EXPECTED, {})
            self.assertLess(sequence.index('journal'), sequence.index('category-set'))
            helper.execute('restore', None, EXPECTED, {})
            self.assertIn(mock.call(['xcrun', 'simctl', 'ui', 'fixed-udid', 'content_size', 'large'],
                                    'category-restore'), native.call_args_list)
            saved['context'] = {'destination': PRIVATE}
            native.reset_mock()
            with self.assertRaises(helper.A.AdaptiveError):
                helper.execute('restore', None, EXPECTED, {})
            native.assert_not_called()

    def test_changed_build_is_rejected_before_any_second_arm_command(self):
        ctx = {'destination': 'fixed'}
        saved = {'context': ctx, 'before': 'large', 'receipt': 'original'}
        with mock.patch.object(helper.A, 'read_json', side_effect=[{'supported': True}, saved]), \
                mock.patch.object(helper, 'context', return_value=(ctx, 'fixed-udid')), \
                mock.patch.object(helper.A, 'verify_receipt', return_value='changed'), \
                mock.patch.object(helper, 'command') as command:
            with self.assertRaises(helper.A.AdaptiveError):
                helper.execute('run', 'system', EXPECTED, {})
            command.assert_not_called()

    def test_native_timeout_terminates_process_group_and_empty_setter_output_is_valid(self):
        with tempfile.TemporaryDirectory() as temp, mock.patch.object(helper, 'DIRECTORY', Path(temp)), \
                mock.patch.object(helper.subprocess, 'Popen') as popen, mock.patch.object(helper.os, 'killpg') as kill:
            popen.return_value.pid = 123
            popen.return_value.wait.side_effect = [subprocess.TimeoutExpired('fixed', 1), 0, 0]
            self.assertIsNone(helper.native(['fixed'], 'timeout', timeout=1))
            self.assertEqual(kill.call_args_list, [mock.call(123, signal.SIGTERM), mock.call(123, signal.SIGKILL)])
            self.assertTrue(popen.call_args.kwargs['start_new_session'])
            popen.return_value.wait.side_effect = None
            popen.return_value.wait.return_value = 0
            self.assertEqual(helper.command(['fixed'], 'setter'), '')

    def test_private_exceptions_and_invalid_cli_never_escape_into_summary(self):
        env = {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': 'hellosunghyun/mirror', 'RUNNER_OS': 'macOS'}
        with tempfile.TemporaryDirectory() as temp, mock.patch.object(helper, 'DIRECTORY', Path(temp).resolve()), \
                mock.patch.dict(os.environ, env), mock.patch.object(helper.A, 'identity', return_value=EXPECTED), \
                mock.patch.object(helper.A, 'checkout_matches'), \
                mock.patch.object(helper, 'execute', side_effect=RuntimeError(PRIVATE)), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(helper.main(['help']), 2)
            summary = (Path(temp) / 'public/help.json').read_text()
            self.assertNotIn(PRIVATE, output.getvalue() + summary)
            self.assertNotIn(temp, output.getvalue() + summary)
            self.assertTrue(output.getvalue().startswith('::notice::Dynamic Type diagnostic: '))
            self.assertEqual(json.loads(summary)['scope'], 'diagnosticOnly')
            self.assertEqual(helper.main(['../../' + PRIVATE]), 2)
            self.assertNotIn(PRIVATE, output.getvalue())

    def test_workflow_narrow_registration_and_two_bounded_fixed_arms_always_restore(self):
        workflow = (ROOT / '.github/workflows/dynamic-type-diagnostics.yml').read_text()
        self.assertIn('  workflow_dispatch:', workflow)
        paths = re.findall(r"^      - '([^']+)'$", workflow, re.MULTILINE)
        self.assertEqual(paths, ['.github/workflows/dynamic-type-diagnostics.yml',
                                'scripts/ci-dynamic-type-diagnostics.py', 'tests/test_dynamic_type_diagnostics.py'])
        self.assertEqual(workflow.count('timeout-minutes: 8'), 2)
        for mode in helper.MODES:
            self.assertEqual(workflow.count('ci-dynamic-type-diagnostics.py run ' + mode), 1)
        self.assertIn("always() && steps.build.outputs.adaptive_build_ready == 'true'", workflow)
        self.assertNotIn('adaptive_evidence_ready', workflow)
        self.assertNotIn('continue-on-error', workflow)


if __name__ == '__main__':
    unittest.main()
