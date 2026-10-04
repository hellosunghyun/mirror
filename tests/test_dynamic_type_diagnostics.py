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

    def test_public_standard_and_extended_declarations_require_the_complete_ordered_block(self):
        # 공개 보존본: keith/zsh-xcode-completions@bef240f25847c3429c69593a5e6c36e2023b8e87
        # specs/simctl.txt:637–639. 현재 runner 원문과 동일하다는 주장 없이 고정 문법만 합성한다.
        declarations = (
            'Standard sizes: extra-small, small, medium, large, extra-large, extra-extra-large, extra-extra-extra-large.',
            'Extended range sizes: accessibility-medium, accessibility-large, accessibility-extra-large, '
            'accessibility-extra-extra-large, accessibility-extra-extra-extra-large.',
            'Other values: unknown, unsupported.',
        )
        for indent in ('\t     ', '             '):
            with self.subTest(indent=repr(indent)):
                text = public_help('        Description before the declarations.\n'
                                   + '\n'.join(indent + line for line in declarations))
                metadata = helper.help_metadata(text)
                self.assertTrue(metadata['supported'])
                self.assertEqual(metadata['knownCategories'], list(helper.CATEGORIES))
                self.assertEqual(metadata['categoryFormat'], 'standardExtendedDeclarations')
                self.assertTrue(metadata['categoryListComplete'])
                self.assertEqual([row['indentColumns'] for row in metadata['categoryRows']], [13, 13])
                self.assertEqual([row['unknownWordCount'] for row in metadata['categoryRows']], [2, 3])
                self.assertEqual([row['paragraphIndex'] for row in metadata['categoryRows']], [2, 2])
                report, _ = helper.help_contract('', text)
                self.assertEqual(report['contractFrom'], 'stderr')
                self.assertNotIn('unknown', metadata['knownCategories'])
                self.assertNotIn('unsupported', metadata['knownCategories'])

        standard, extended, other = declarations
        block = '\n'.join('    ' + line for line in declarations)
        invalid_blocks = (
            '\n'.join('    ' + line for line in (extended, standard, other)),
            '\n'.join('    ' + line for line in (standard, standard, extended, other)),
            '\n'.join('    ' + line for line in (standard, other)),
            '\n'.join('    ' + line for line in (standard, extended)),
            block.replace('extra-small, small', 'small, extra-small', 1),
            block.replace('extra-small, small', 'extra-small, extra-small', 1),
            block.replace('medium, large,', 'medium,', 1),
            block.replace('accessibility-medium,', 'extra-small,', 1),
            block.replace('accessibility-medium,', PRIVATE + ',', 1),
            block.replace('Standard sizes:', 'Standard size:'),
            block.replace('extra-extra-extra-large.\n', 'extra-extra-extra-large\n', 1),
            block.replace('extra-extra-extra-large.\n', 'extra-extra-extra-large..\n', 1),
            block.replace('Other values: unknown, unsupported.', 'Other values: ' + PRIVATE + '.'),
            block + '\n    ' + PRIVATE,
            block.replace('\n    Extended', '\n    ' + PRIVATE + '\n    Extended'),
            block.replace('\n    Extended', '\n\n    Extended'),
            block.replace('\n    Extended', '\n     Extended'),
            block.replace('\n    Extended', '\n  appearance\n    Extended'),
            block.replace('\n    Extended', '\n  content_size\n    Extended'),
            block + '\n\n' + block,
            block + '\n\n    ' + ', '.join(helper.CATEGORIES),
            '    ' + standard + '\n\n    ' + ', '.join(helper.CATEGORIES),
        )
        for listing in invalid_blocks:
            with self.subTest(listing=listing):
                text = public_help(listing)
                self.assertFalse(helper.supports_ui(text))
                self.assertNotIn(PRIVATE, json.dumps(helper.help_metadata(text)))
        outside = public_help(block).replace('content_size', 'appearance') + '\n  content_size\n    No values'
        self.assertFalse(helper.supports_ui(outside))
        report, digest = helper.help_contract(public_help('    ' + standard),
                                             public_help('    ' + extended + '\n    ' + other))
        self.assertEqual(report['contractFrom'], 'none')
        self.assertIsNone(digest)

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
                self.assertEqual(metadata['headingIndent'], len(indent.expandtabs(8)))
                self.assertEqual(metadata['firstFollowingIndent'], len((indent + '    ').expandtabs(8)))
                self.assertEqual(metadata['firstBodyIndent'], len((indent + '    ').expandtabs(8)))
                self.assertEqual(metadata['knownCategoryCount'], 12)
                self.assertEqual(metadata['wholeHelpTokensPresentCount'], 12)
                self.assertNotIn(PRIVATE, json.dumps(metadata))

    def test_mixed_tab_and_space_indentation_preserves_one_complete_scoped_list(self):
        prefix = 'Usage: simctl ui <device> <option> [<arguments>]\n    content_size\n'
        for indents in (['\t'] * 12, ['\t'] * 6 + ['        '] * 6):
            text = prefix + '\n'.join(indent + value for indent, value in zip(indents, helper.CATEGORIES))
            metadata = helper.help_metadata(text)
            self.assertTrue(metadata['supported'])
            self.assertEqual(metadata['headingIndent'], 4)
            self.assertEqual(metadata['firstFollowingIndent'], 8)
            self.assertEqual(metadata['firstBodyIndent'], 8)
            self.assertEqual(metadata['knownCategories'], list(helper.CATEGORIES))
            self.assertEqual(metadata['categoryFormat'], 'standalone')
            report, _ = helper.help_contract('', text)
            self.assertEqual(report['contractFrom'], 'stderr')

    def test_tab_stop_indentation_rejects_same_column_shallower_and_split_lists(self):
        usage = 'Usage: simctl ui <device> <option> [<arguments>]\n'
        for heading, body in (('        ', '\t'), ('\t', '    ')):
            text = usage + heading + 'content_size\n' + '\n'.join(body + value for value in helper.CATEGORIES)
            metadata = helper.help_metadata(text)
            self.assertFalse(metadata['supported'])
            self.assertEqual(metadata['headingIndent'], 8)
            self.assertIsNone(metadata['firstBodyIndent'])
            self.assertEqual(metadata['knownTokensPresentCount'], 0)
        prefix = usage + '    content_size\n'
        first = '\n'.join('\t' + value for value in helper.CATEGORIES[:6])
        last = '\n'.join('        ' + value for value in helper.CATEGORIES[6:])
        for separator in ('\n\n', '\n    appearance\n', '\n\tappearance\n'):
            self.assertFalse(helper.supports_ui(prefix + first + separator + last))
        report, _ = helper.help_contract(prefix + first, prefix + last)
        self.assertEqual(report['contractFrom'], 'none')

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

    def test_bare_comma_period_requires_one_complete_bounded_row_and_preserves_its_group(self):
        values = ', '.join(helper.CATEGORIES)
        padding = 512 - len(values + '.')
        bounded = values.replace(', ', ', ' + ' ' * padding, 1) + '.'
        self.assertEqual(len(bounded), 512)
        for listing in (values + '.', bounded):
            metadata = helper.help_metadata(public_help('    ' + listing))
            self.assertTrue(metadata['supported'])
            self.assertTrue(metadata['categoryListComplete'])
            self.assertEqual(metadata['categoryFormat'], 'commaList')
            self.assertEqual(metadata['knownCategories'], list(helper.CATEGORIES))
        for index, listing in enumerate((
                bounded.replace(', ', ',  ', 1), values + '..', values + '.,',
                '- ' + values + '.', '* ' + values + '.', '• ' + values + '.',
                'Allowed sizes: ' + values + '.', PRIVATE + ': ' + values + '.',
                values + '. ' + PRIVATE, values + ', ' + PRIVATE + '.',
                ', '.join((*helper.CATEGORIES[:-1], helper.CATEGORIES[0])) + '.',
                'Earlier descriptive prose.\n    ' + values + '.',
                values + '.\n    Later descriptive prose.')):
            with self.subTest(boundary=index):
                metadata = helper.help_metadata(public_help('    ' + listing))
                self.assertFalse(metadata['supported'])
                self.assertFalse(metadata['categoryListComplete'])
                self.assertNotIn(PRIVATE, json.dumps(metadata))

    def test_period_fragments_duplicate_paragraphs_and_streams_never_form_a_contract(self):
        first = ', '.join(helper.CATEGORIES[:6]) + '.'
        last = ', '.join(helper.CATEGORIES[6:]) + '.'
        complete = ', '.join(helper.CATEGORIES) + '.'
        listings = (first + '\n    ' + last, first + '\n\n    ' + last,
                    first + '\n        ' + last, first + '\n  appearance\n    ' + last,
                    complete + '\n\n    ' + complete, complete + '\n    ' + complete,
                    complete + '\n  content_size\n    ' + complete)
        for index, listing in enumerate(listings):
            with self.subTest(boundary=index):
                self.assertFalse(helper.supports_ui(public_help('    ' + listing)))
        report, digest = helper.help_contract(public_help('    ' + first), public_help('    ' + last))
        self.assertEqual(report['contractFrom'], 'none')
        self.assertFalse(report['publicUIContractVerified'])
        self.assertIsNone(digest)

    def test_category_row_metadata_preserves_fixed_token_order_and_enum_shapes_only(self):
        cases = (
            ('"large", "extra-small".', ['large', 'extra-small'], 'double', 'comma', 'period', 'none'),
            ("'small' | 'medium'", ['small', 'medium'], 'single', 'pipe', 'other', 'none'),
            ('`large`\t`small`', ['large', 'small'], 'backtick', 'tab', 'other', 'none'),
            ('large  small', ['large', 'small'], 'none', 'multiSpace', 'none', 'none'),
            ('large, small:', ['large', 'small'], 'none', 'comma', 'colon', 'none'),
            ('large, small,', ['large', 'small'], 'none', 'comma', 'comma', 'none'),
            ('"large", \'small\'', ['large', 'small'], 'mixed', 'comma', 'other', 'none'),
            ('large, small | medium', ['large', 'small', 'medium'], 'none', 'mixed', 'none', 'none'),
        )
        keys = {'indentColumns', 'paragraphIndex', 'tokens', 'tokensTruncated', 'quoteStyle',
                'separatorShape', 'terminal', 'declaration', 'unknownWordCount'}
        for index, (line, tokens, quotes, separator, terminal, declaration) in enumerate(cases):
            with self.subTest(shape=index):
                metadata = helper.help_metadata(public_help('    ' + line))
                self.assertFalse(metadata['supported'])
                self.assertFalse(metadata['categoryRowsTruncated'])
                self.assertEqual(len(metadata['categoryRows']), 1)
                row = metadata['categoryRows'][0]
                self.assertEqual(set(row), keys)
                self.assertEqual(row['indentColumns'], 4)
                self.assertEqual(row['paragraphIndex'], 1)
                self.assertEqual(row['tokens'], tokens)
                self.assertFalse(row['tokensTruncated'])
                self.assertEqual(row['quoteStyle'], quotes)
                self.assertEqual(row['separatorShape'], separator)
                self.assertEqual(row['terminal'], terminal)
                self.assertEqual(row['declaration'], declaration)
                self.assertEqual(row['unknownWordCount'], 0)

    def test_category_metadata_never_turns_quoted_tokens_or_private_text_into_support(self):
        private_fragments = (PRIVATE, '/Users/' + PRIVATE + '/note.txt',
                             '“' + PRIVATE + '”', '‘' + PRIVATE + '’', '`' + PRIVATE + '`')
        for index, private in enumerate(private_fragments):
            with self.subTest(shape=index):
                listing = '    ' + private + ': ' + ', '.join('"' + token + '"' for token in helper.CATEGORIES) + '.'
                metadata = helper.help_metadata(public_help(listing))
                self.assertEqual(metadata['knownTokensPresent'], list(helper.CATEGORIES))
                self.assertEqual(metadata['knownCategoryCount'], 0)
                self.assertFalse(metadata['categoryListComplete'])
                self.assertFalse(metadata['supported'])
                row = metadata['categoryRows'][0]
                self.assertEqual(row['tokens'], list(helper.CATEGORIES))
                self.assertGreater(row['unknownWordCount'], 0)
                self.assertIn(row['quoteStyle'], ('none', 'single', 'double', 'backtick', 'mixed'))
                self.assertIn(row['separatorShape'], ('none', 'comma', 'pipe', 'tab', 'multiSpace', 'mixed', 'other'))
                self.assertIn(row['terminal'], ('none', 'comma', 'period', 'colon', 'other'))
                self.assertEqual(row['declaration'], 'other')
                rendered = json.dumps(metadata, ensure_ascii=False)
                self.assertNotIn(PRIVATE, rendered)
                self.assertNotIn('/Users/', rendered)
                self.assertNotIn('note.txt', rendered)
                self.assertNotIn('“', rendered)
                self.assertNotIn('‘', rendered)

    def test_category_row_paragraphs_match_prose_blank_indent_and_declaration_boundaries(self):
        complete = ', '.join(helper.CATEGORIES)
        listing = ('    Introductory prose.\n\n    "small"\n    "large"\n        `medium`\n'
                   '    Valid sizes: ' + complete + '.\n    "extra-large"')
        metadata = helper.help_metadata(public_help(listing))
        rows = metadata['categoryRows']
        self.assertEqual([row['paragraphIndex'] for row in rows], [2, 2, 3, 4, 5])
        self.assertEqual([row['indentColumns'] for row in rows], [4, 4, 8, 4, 4])
        self.assertEqual([row['tokens'] for row in rows],
                         [['small'], ['large'], ['medium'], list(helper.CATEGORIES), ['extra-large']])
        self.assertEqual(rows[3]['declaration'], 'validSizes')
        self.assertTrue(metadata['supported'], '기존 complete declaration은 주변 비목록 설명과 독립적으로 검증한다.')
        values = helper.help_metadata(public_help('    Valid values: ' + complete))
        self.assertEqual(values['categoryRows'][0]['declaration'], 'validValues')
        self.assertTrue(values['supported'])

    def test_category_row_metadata_caps_every_repeated_or_numeric_dimension(self):
        repeated = ['large', 'small'] * 13
        metadata = helper.help_metadata(public_help(' ' * 300 + ', '.join(repeated)))
        row = metadata['categoryRows'][0]
        self.assertEqual(row['indentColumns'], 255)
        self.assertEqual(row['tokens'], repeated[:24])
        self.assertTrue(row['tokensTruncated'])
        self.assertFalse(metadata['categoryRowsTruncated'])
        self.assertFalse(metadata['supported'])
        at_limit = helper.help_metadata(public_help('    ' + ', '.join(repeated[:24])))
        self.assertFalse(at_limit['categoryRows'][0]['tokensTruncated'])
        many_rows = helper.help_metadata(public_help('\n'.join(['    large'] * 25)))
        self.assertEqual(len(many_rows['categoryRows']), 24)
        self.assertTrue(many_rows['categoryRowsTruncated'])
        self.assertFalse(many_rows['supported'])
        exact_rows = helper.help_metadata(public_help('\n'.join(['    large'] * 24)))
        self.assertFalse(exact_rows['categoryRowsTruncated'])
        prose = '    Private descriptive prose.\n\n' * 260 + '    large ' + (PRIVATE + ' ') * 300
        final = helper.help_metadata(public_help(prose))
        self.assertEqual(len(final['categoryRows']), 1)
        self.assertEqual(final['categoryRows'][0]['paragraphIndex'], 255)
        self.assertEqual(final['categoryRows'][0]['unknownWordCount'], 255)
        self.assertNotIn(PRIVATE, json.dumps(final))

    def test_row_metadata_scope_excludes_other_options_and_duplicate_sections(self):
        text = public_help('    "large"\n  appearance\n    "small" ' + PRIVATE)
        metadata = helper.help_metadata(text)
        self.assertEqual([row['tokens'] for row in metadata['categoryRows']], [['large']])
        self.assertEqual(metadata['knownTokensPresent'], ['large'])
        self.assertEqual(metadata['wholeHelpTokensPresent'], ['small', 'large'])
        self.assertFalse(metadata['categoryRowsTruncated'])
        for body in ('appearance\n    large', public_help('    large\n  content_size\n    small')):
            result = helper.help_metadata(body)
            self.assertEqual(result['categoryRows'], [])
            self.assertFalse(result['categoryRowsTruncated'])
            self.assertFalse(result['supported'])

    def test_truncated_metadata_does_not_hide_a_later_conflicting_list_from_the_parser(self):
        complete = '    ' + ', '.join(helper.CATEGORIES) + '.'
        descriptions = '\n\n'.join(['    "small"'] * 23)
        valid = complete + '\n\n' + descriptions
        self.assertTrue(helper.supports_ui(public_help(valid)))
        metadata = helper.help_metadata(public_help(valid + '\n\n    small'))
        self.assertEqual(len(metadata['categoryRows']), 24)
        self.assertTrue(metadata['categoryRowsTruncated'])
        self.assertFalse(metadata['categoryListComplete'])
        self.assertFalse(metadata['supported'])

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
        self.assertEqual([row['tokens'] for row in metadata['categoryRows']], [['extra-small']])
        self.assertGreater(metadata['categoryRows'][0]['unknownWordCount'], 0)
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

    def test_failed_stdout_retains_partial_owned_observations_without_inventing_completion(self):
        lines = observed_log(failed=True).splitlines()
        for length in range(len(lines) + 1):
            with self.subTest(length=length):
                value = helper.failed_stdout_observations('\n'.join(lines[:length]), 'system')
                self.assertEqual(value['caseStarted'], length >= 1)
                self.assertEqual(value['caseTerminal'], 'failed' if length == len(lines) else None)
                self.assertEqual(value['probes']['root']['status'], 'observed' if length >= 2 else 'unobserved')
                self.assertEqual(value['probes']['capture']['status'], 'observed' if length >= 3 else 'unobserved')
                self.assertEqual(value['auditIssueTypes'], [['dynamicType']] if length >= 4 else [])
                self.assertEqual(value['auditBoundary'], 'threw' if length >= 5 else None)
                self.assertNotIn('maximumProbesVerified', value)
                self.assertNotIn('caseResult', value)
        # stdout에 passed가 있어도 xcresult typed 완료·native 성공을 대신하지 않는다.
        value = helper.failed_stdout_observations(observed_log(), 'system')
        self.assertEqual(value['caseTerminal'], 'passed')
        self.assertNotIn('caseResult', value)

    def test_failed_stdout_reports_fixed_probe_mismatches_and_never_exposes_sdk_lines(self):
        lines = [event('started'), helper.PROBE + json.dumps(probe(
            'root', actualMode='pinned', swiftUI='large', uiKit='large')), PRIVATE]
        value = helper.failed_stdout_observations('\n'.join(lines), 'system')
        self.assertTrue(value['probes']['root']['modeMismatch'])
        self.assertTrue(value['probes']['root']['maximumMismatch'])
        self.assertEqual(value['probes']['capture'], {'status': 'unobserved'})
        self.assertNotIn(PRIVATE, json.dumps(value))
        for changes in ({'actualMode': 'pinned'}, {'requestedMode': 'pinned'}, {'swiftUI': 'large'}, {'uiKit': 'large'}):
            lines[1] = helper.PROBE + json.dumps(probe('root', **changes))
            value = helper.failed_stdout_observations('\n'.join(lines), 'system')
            self.assertEqual(value['probes']['root']['modeMismatch'], bool(set(changes) & {'actualMode', 'requestedMode'}))
            self.assertEqual(value['probes']['root']['maximumMismatch'], bool(set(changes) & {'swiftUI', 'uiKit'}))

    def test_failed_stdout_rejects_foreign_cases_private_fields_and_invalid_order(self):
        log = observed_log(failed=True)
        lines = log.splitlines()
        invalid = [log.replace(helper.OWNER, 'Foreign.Owner'), log.replace(helper.CASE, 'testForeign'),
                   '\n'.join(lines[1:]), log + '\n' + lines[1], '\n'.join(lines[:2] + lines[1:]),
                   '\n'.join((lines[0], lines[2], lines[1])), log + '\n' + event('started'),
                   log.replace('Test Case ', 'Test  Case '), log.replace(helper.PROBE, 'SDK said ' + helper.PROBE)]
        for changes in ({'scope': 'review'}, {'actualMode': PRIVATE}, {'swiftUI': PRIVATE}, {'uiKit': PRIVATE},
                        {'uiKitSource': 'viewTrait'}, {'schemaVersion': True}, {PRIVATE: PRIVATE}):
            invalid.append('\n'.join([lines[0], helper.PROBE + json.dumps(probe('root', **changes))]))
        for malformed in ('{', '[]', '{"schemaVersion":1,"schemaVersion":1}', 'NaN'):
            invalid.append('\n'.join([lines[0], helper.PROBE + malformed]))
        issue = json.loads(lines[3][len(helper.AUDIT):])
        for changes in ({'types': [PRIVATE]}, {'types': ['contrast', 'contrast']}, {'ignored': True},
                        {'auditSequence': True}, {'issueSequence': 2}, {'requestedMode': 'pinned'}, {PRIVATE: PRIVATE}):
            invalid.append('\n'.join([*lines[:3], helper.AUDIT + json.dumps({**issue, **changes})]))
        invalid.append('\n'.join([*lines[:3], *(helper.AUDIT + json.dumps({**issue, 'issueSequence': index})
                                                   for index in range(1, 66))]))
        for text in invalid:
            with self.subTest(text=text), self.assertRaises((helper.A.AdaptiveError, ValueError)):
                helper.failed_stdout_observations(text, 'system')

    def test_failure_summary_distinguishes_empty_stream_from_missing_markers_and_hides_errors(self):
        with tempfile.TemporaryDirectory() as temp, mock.patch.object(helper, 'DIRECTORY', Path(temp)), \
                mock.patch.object(helper.A, 'verify_receipt', return_value='same') as receipt:
            (Path(temp) / 'system.stderr').write_text(PRIVATE)
            for text in ('', PRIVATE, event('started')):
                (Path(temp) / 'system.stdout').write_text(text)
                value = helper.failed_native_observations('system', EXPECTED, 'same')
                self.assertEqual(value['scope'], 'diagnosticOnly')
                self.assertEqual(value['evidence'], 'stdoutOnly')
                self.assertEqual(value['status'], 'observed')
                self.assertEqual(value['stdoutBytes'], len(text.encode()))
                self.assertEqual(value['stderrBytes'], len(PRIVATE.encode()))
                self.assertEqual(value['caseStarted'], text == event('started'))
                self.assertNotIn(PRIVATE, json.dumps(value))
            (Path(temp) / 'system.stdout').write_text(event('started') + '\n' + helper.PROBE + json.dumps({PRIVATE: PRIVATE}))
            value = helper.failed_native_observations('system', EXPECTED, 'same')
            self.assertEqual((value['status'], value['failureStage']), ('rejected', 'stdoutParse'))
            self.assertNotIn('probes', value)
            self.assertNotIn(PRIVATE, json.dumps(value))
            receipt.return_value = 'changed'
            value = helper.failed_native_observations('system', EXPECTED, 'same')
            self.assertEqual((value['status'], value['failureStage']), ('unavailable', 'receiptVerification'))
            self.assertIsNone(value['stdoutBytes'])
            receipt.side_effect = RuntimeError(PRIVATE)
            self.assertNotIn(PRIVATE, json.dumps(helper.failed_native_observations('system', EXPECTED, 'same')))

    def test_native_failure_summary_keeps_native_exit_timeout_and_collect_rejection(self):
        ctx = {'destination': 'fixed', 'scheme': 'fixed', 'sdk': 'fixed'}
        saved = {'context': ctx, 'before': 'large', 'receipt': 'original'}
        for code in (None, 65, 0):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as temp, \
                    mock.patch.object(helper, 'DIRECTORY', Path(temp)), \
                    mock.patch.object(helper.A, 'read_json', side_effect=[{'supported': True}, saved]), \
                    mock.patch.object(helper, 'context', return_value=(ctx, 'fixed-udid')), \
                    mock.patch.object(helper.A, 'verify_receipt', return_value='original'), \
                    mock.patch.object(helper, 'command', return_value=helper.CATEGORIES[-1]), \
                    mock.patch.object(helper, 'native', return_value=code) as native, \
                    mock.patch.object(helper, 'failed_native_observations', return_value={
                        'scope': 'diagnosticOnly', 'evidence': 'stdoutOnly', 'status': 'unavailable'}) as diagnostic:
                report = {}
                if code == 0:
                    helper.execute('run', 'pinned', EXPECTED, report)
                    diagnostic.assert_not_called()
                else:
                    with self.assertRaises(helper.Failure) as caught:
                        helper.execute('run', 'pinned', EXPECTED, report)
                    self.assertEqual(caught.exception.code, 'nativeTestFailed')
                    diagnostic.assert_called_once_with('pinned', EXPECTED, 'original')
                self.assertEqual(native.call_args.args[-1], 420)
                self.assertEqual(report['nativeExitCode'], code)
                self.assertEqual(report['timedOut'], code is None)
                self.assertEqual(json.loads((Path(temp) / 'pinned-exit.json').read_text()),
                                 {'nativeExitCode': code, 'timedOut': code is None})
        with mock.patch.object(helper.A, 'read_json', side_effect=[{'supported': True}, saved,
                {'nativeExitCode': None, 'timedOut': True}]), \
                mock.patch.object(helper, 'context', return_value=(ctx, 'fixed-udid')), \
                mock.patch.object(helper.A, 'verify_receipt', return_value='original'), \
                mock.patch.object(helper, 'command') as command, mock.patch.object(helper, 'observations') as observations:
            with self.assertRaises(helper.Failure) as caught:
                helper.execute('collect', 'pinned', EXPECTED, {})
            self.assertEqual(caught.exception.code, 'testDidNotFinish')
            command.assert_not_called()
            observations.assert_not_called()

    def test_preboot_requests_only_the_owned_device_without_category_or_build_receipt_changes(self):
        env = {'MIRROR_DYNAMIC_TYPE_PREBOOT': '1', 'GITHUB_WORKFLOW': 'iPad Dynamic Type 설정 원인분리 진단'}
        for state in ('Booted', 'Shutdown'):
            devices = {'devices': {'runtime': [{'udid': 'foreign-udid', 'state': 'Shutdown'},
                                               {'udid': 'owned-udid', 'state': state}]}}
            with self.subTest(state=state), mock.patch.dict(os.environ, env), \
                    mock.patch.object(helper.A, 'read_json', return_value={'supported': True}), \
                    mock.patch.object(helper, 'context', return_value=({'destination': 'owned'}, 'owned-udid')) as context, \
                    mock.patch.object(helper, 'command', side_effect=lambda args, name:
                        json.dumps(devices) if name == 'preboot-devices' else '') as command, \
                    mock.patch.object(helper.A, 'write_json') as write, \
                    mock.patch.object(helper.A, 'verify_receipt') as receipt:
                report = {}
                helper.execute('preboot', None, EXPECTED, report)
                context.assert_called_once_with(EXPECTED)
                calls = [mock.call(['xcrun', 'simctl', 'list', 'devices', 'available', '--json'], 'preboot-devices')]
                if state == 'Shutdown':
                    calls.append(mock.call(['xcrun', 'simctl', 'boot', 'owned-udid'], 'preboot-request'))
                self.assertEqual(command.call_args_list, calls)
                self.assertEqual(report['prebootDisposition'], 'bootRequested' if state == 'Shutdown' else 'alreadyBooted')
                self.assertEqual(report['simulatorInitialState'], state)
                self.assertNotIn('bootStatusExitCode', report)
                self.assertNotIn('systemAfter', report)
                self.assertNotIn('owned-udid', json.dumps(report))
                write.assert_not_called()
                receipt.assert_not_called()

    def test_preboot_rejects_missing_optin_wrong_workflow_context_and_ambiguous_device(self):
        valid_env = {'MIRROR_DYNAMIC_TYPE_PREBOOT': '1', 'GITHUB_WORKFLOW': 'iPad Dynamic Type 설정 원인분리 진단'}
        for env in ({**valid_env, 'MIRROR_DYNAMIC_TYPE_PREBOOT': ''},
                    {**valid_env, 'MIRROR_DYNAMIC_TYPE_PREBOOT': 'true'},
                    {**valid_env, 'GITHUB_WORKFLOW': 'another-workflow'}):
            with mock.patch.dict(os.environ, env), \
                    mock.patch.object(helper.A, 'read_json', return_value={'supported': True}), \
                    mock.patch.object(helper, 'context', return_value=({}, 'owned-udid')), \
                    mock.patch.object(helper, 'command') as command, self.assertRaises(helper.Failure):
                helper.execute('preboot', None, EXPECTED, {})
            command.assert_not_called()
        for rows in ([], [{'udid': 'foreign-udid', 'state': 'Shutdown'}],
                     [{'udid': 'owned-udid', 'state': 'Creating'}],
                     [{'udid': 'owned-udid', 'state': 'Booted'}] * 2):
            with mock.patch.dict(os.environ, valid_env), \
                    mock.patch.object(helper.A, 'read_json', return_value={'supported': True}), \
                    mock.patch.object(helper, 'context', return_value=({}, 'owned-udid')), \
                    mock.patch.object(helper, 'command', return_value=json.dumps({'devices': {'runtime': rows}})) as command, \
                    self.assertRaises(helper.Failure):
                helper.execute('preboot', None, EXPECTED, {})
            self.assertEqual(command.call_count, 1)
            self.assertEqual(command.call_args.args[1], 'preboot-devices')
        with mock.patch.dict(os.environ, valid_env), \
                mock.patch.object(helper.A, 'read_json', return_value={'supported': True}), \
                mock.patch.object(helper, 'context', side_effect=helper.A.AdaptiveError('contextMismatch')), \
                mock.patch.object(helper, 'command') as command, self.assertRaises(helper.A.AdaptiveError):
            helper.execute('preboot', None, EXPECTED, {})
        command.assert_not_called()

    def test_restore_journal_precedes_mutation_and_uses_same_context_only(self):
        ctx, sequence = {'destination': 'fixed-context'}, []
        write_json = helper.A.write_json
        def write(path, value, **kwargs):
            sequence.append('journal')
            write_json(path, value, **kwargs)
        def command(args, name):
            sequence.append(name)
            if name == 'devices': return json.dumps({'devices': {'runtime': [{'udid': 'fixed-udid', 'state': 'Booted'}]}})
            if name == 'category-before': return 'large'
            if name == 'category-after': return helper.CATEGORIES[-1]
            if name == 'category-restored': return 'large'
            return ''
        with tempfile.TemporaryDirectory() as temp, mock.patch.object(helper, 'DIRECTORY', Path(temp)), \
                mock.patch.object(helper, 'context', return_value=(ctx, 'fixed-udid')), \
                mock.patch.object(helper.A, 'verify_receipt', return_value='fixed-receipt'), \
                mock.patch.object(helper, 'native', return_value=0), mock.patch.object(helper.A, 'write_json', side_effect=write), \
                mock.patch.object(helper, 'command', side_effect=command) as native:
            write_json(Path(temp) / 'contract.json', {'supported': True})
            helper.execute('setup', None, EXPECTED, {})
            self.assertLess(sequence.index('journal'), sequence.index('category-set'))
            report = {}
            helper.execute('restore', None, EXPECTED, report)
            self.assertIs(report['systemRestored'], True)
            self.assertIn(mock.call(['xcrun', 'simctl', 'ui', 'fixed-udid', 'content_size', 'large'],
                                    'category-restore'), native.call_args_list)
            saved = helper.A.read_json(Path(temp) / 'restore.json')
            saved['context'] = {'destination': PRIVATE}
            write_json(Path(temp) / 'restore.json', saved)
            native.reset_mock()
            with self.assertRaises(helper.A.AdaptiveError):
                helper.execute('restore', None, EXPECTED, {})
            native.assert_not_called()

    def test_boot_failure_records_exit_or_timeout_without_category_mutation(self):
        env = {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': 'hellosunghyun/mirror', 'RUNNER_OS': 'macOS'}
        for state, code in (('Booted', 7), ('Shutdown', None)):
            with self.subTest(state=state, code=code), tempfile.TemporaryDirectory() as temp, \
                    mock.patch.object(helper, 'DIRECTORY', Path(temp).resolve()), mock.patch.dict(os.environ, env), \
                    mock.patch.object(helper.A, 'identity', return_value=EXPECTED), \
                    mock.patch.object(helper.A, 'checkout_matches'), \
                    mock.patch.object(helper, 'context', return_value=({'destination': 'fixed'}, 'fixed-udid')), \
                    mock.patch.object(helper.A, 'verify_receipt', return_value='fixed-receipt') as receipt, \
                    mock.patch.object(helper, 'native', return_value=code) as native, \
                    mock.patch.object(helper, 'command', side_effect=lambda args, name:
                        json.dumps({'devices': {'runtime': [{'udid': 'fixed-udid', 'state': state}]}})
                        if name == 'devices' else '') as command, contextlib.redirect_stdout(io.StringIO()) as output:
                helper.A.write_json(Path(temp) / 'contract.json', {'supported': True})
                self.assertEqual(helper.main(['setup']), 2)
                report = helper.A.read_json(Path(temp) / 'public/setup.json')
                self.assertEqual(report, {**EXPECTED, 'schemaVersion': 1, 'scope': 'diagnosticOnly',
                                         'action': 'setup', 'mode': None, 'status': 'bootFailed',
                                         'phase': 'bootStatusReturned', 'simulatorInitialState': state,
                                         'bootStatusExitCode': code, 'bootStatusTimedOut': code is None})
                self.assertEqual(helper.main(['restore']), 0)
                restored = helper.A.read_json(Path(temp) / 'public/restore.json')
                self.assertEqual(restored['restoreDisposition'], 'notRequiredBeforeCategoryChange')
                self.assertIs(restored['systemRestored'], False)
                receipt.assert_called_once_with(helper.BUILD, EXPECTED)
                native.assert_called_once_with(['xcrun', 'simctl', 'bootstatus', 'fixed-udid', '-b'], 'boot-status', 45)
                self.assertEqual([call.args[1] for call in command.call_args_list],
                                 ['devices', 'boot'] if state == 'Shutdown' else ['devices'])
                self.assertFalse((Path(temp) / 'restore.json').exists())
                self.assertNotIn(temp, output.getvalue())
                self.assertNotIn('fixed-udid', output.getvalue())

    def test_absent_journal_requires_owned_completed_boot_failure(self):
        original = {**EXPECTED, 'schemaVersion': 1, 'scope': 'diagnosticOnly', 'action': 'setup', 'mode': None,
                    'status': 'bootFailed', 'phase': 'bootStatusReturned', 'simulatorInitialState': 'Booted',
                    'bootStatusExitCode': 7, 'bootStatusTimedOut': False}
        wrong = ({'runID': '11'}, {'runAttempt': '2'}, {'commitSHA': 'b' * 40}, {'buildNumber': '2'},
                 {'platform': 'iphone'}, {'appearance': 'dark'}, {'scope': PRIVATE}, {'action': 'restore'},
                 {'mode': 'pinned'}, {'schemaVersion': True}, {'status': 'diagnosticUnavailable'},
                 {'phase': 'bootStatusStarted'}, {'simulatorInitialState': PRIVATE},
                 {'bootStatusExitCode': 0}, {'bootStatusExitCode': True}, {'bootStatusExitCode': PRIVATE},
                 {'bootStatusExitCode': None}, {'bootStatusTimedOut': True}, {'bootStatusTimedOut': 0},
                 {'unexpected': PRIVATE})
        with tempfile.TemporaryDirectory() as temp, mock.patch.object(helper, 'DIRECTORY', Path(temp)), \
                mock.patch.object(helper, 'context', return_value=({'destination': 'fixed'}, 'fixed-udid')), \
                mock.patch.object(helper, 'command') as command:
            helper.A.write_json(Path(temp) / 'contract.json', {'supported': True})
            public = Path(temp) / 'public'
            public.mkdir()
            path = public / 'setup.json'
            for changes in ({}, {'bootStatusExitCode': None, 'bootStatusTimedOut': True}):
                helper.A.write_json(path, {**original, **changes})
                report = {}
                helper.execute('restore', None, EXPECTED, report)
                self.assertEqual(report['restoreDisposition'], 'notRequiredBeforeCategoryChange')
                self.assertIs(report['systemRestored'], False)
                self.assertEqual(report['phase'], 'restoreNotRequired')
            for changes in wrong:
                helper.A.write_json(path, {**original, **changes})
                with self.subTest(changes=changes), self.assertRaises(helper.A.AdaptiveError):
                    helper.execute('restore', None, EXPECTED, {})
            path.unlink()
            with self.assertRaises(FileNotFoundError):
                helper.execute('restore', None, EXPECTED, {})
            path.symlink_to(public / 'missing')
            with self.assertRaises(OSError):
                helper.execute('restore', None, EXPECTED, {})
            path.unlink()
            path.write_text('{')
            with self.assertRaises(ValueError):
                helper.execute('restore', None, EXPECTED, {})
            path.unlink()
            public.rmdir()
            public.symlink_to(Path(temp) / 'missing-public', target_is_directory=True)
            with self.assertRaises(helper.Failure) as caught:
                helper.execute('restore', None, EXPECTED, {})
            self.assertEqual(caught.exception.code, 'unsafeSetupSummary')
            command.assert_not_called()

    def test_existing_or_unsafe_journal_never_uses_boot_failure_noop(self):
        ctx = {'destination': 'fixed'}
        with tempfile.TemporaryDirectory() as temp, mock.patch.object(helper, 'DIRECTORY', Path(temp)), \
                mock.patch.object(helper, 'context', return_value=(ctx, 'fixed-udid')), \
                mock.patch.object(helper, 'verify_no_category_change') as no_change, \
                mock.patch.object(helper, 'command', side_effect=['', 'large']) as command:
            helper.A.write_json(Path(temp) / 'contract.json', {'supported': True})
            journal = Path(temp) / 'restore.json'
            helper.A.write_json(journal, {'context': ctx, 'before': 'large', 'receipt': 'fixed-receipt'})
            report = {}
            helper.execute('restore', None, EXPECTED, report)
            self.assertIs(report['systemRestored'], True)
            self.assertEqual([call.args[1] for call in command.call_args_list], ['category-restore', 'category-restored'])
            self.assertNotIn('restoreDisposition', report)
            command.reset_mock()
            for raw in ('', '{', json.dumps({'context': {'destination': PRIVATE}, 'before': 'large'})):
                journal.write_text(raw)
                with self.subTest(raw=raw), self.assertRaises((helper.A.AdaptiveError, ValueError)):
                    helper.execute('restore', None, EXPECTED, {})
            journal.unlink()
            journal.symlink_to(Path(temp) / 'missing')
            with self.assertRaises(helper.Failure) as caught:
                helper.execute('restore', None, EXPECTED, {})
            self.assertEqual(caught.exception.code, 'unsafeRestoreJournal')
            no_change.assert_not_called()
            command.assert_not_called()

    def test_setup_failure_after_journal_still_restores_original_category(self):
        for failed_step in ('category-set', 'category-after'):
            with self.subTest(failed_step=failed_step), tempfile.TemporaryDirectory() as temp, \
                    mock.patch.object(helper, 'DIRECTORY', Path(temp)), \
                    mock.patch.object(helper, 'context', return_value=({'destination': 'fixed'}, 'fixed-udid')), \
                    mock.patch.object(helper.A, 'verify_receipt', return_value='fixed-receipt'), \
                    mock.patch.object(helper, 'native', return_value=0):
                helper.A.write_json(Path(temp) / 'contract.json', {'supported': True})
                def command(args, name):
                    if name == 'devices':
                        return json.dumps({'devices': {'runtime': [{'udid': 'fixed-udid', 'state': 'Booted'}]}})
                    if name == failed_step:
                        raise helper.Failure('nativeCommandFailed')
                    return 'large' if name in ('category-before', 'category-restored') else ''
                with mock.patch.object(helper, 'command', side_effect=command) as native, \
                        mock.patch.object(helper, 'verify_no_category_change') as no_change:
                    with self.assertRaises(helper.Failure):
                        helper.execute('setup', None, EXPECTED, {})
                    journal = Path(temp) / 'restore.json'
                    self.assertEqual(helper.A.read_json(journal)['before'], 'large')
                    native.reset_mock()
                    report = {}
                    helper.execute('restore', None, EXPECTED, report)
                    self.assertIs(report['systemRestored'], True)
                    self.assertEqual([call.args[1] for call in native.call_args_list],
                                     ['category-restore', 'category-restored'])
                    no_change.assert_not_called()

    def test_restore_interruption_after_set_keeps_journal_and_failed_readback(self):
        ctx = {'destination': 'fixed'}
        with tempfile.TemporaryDirectory() as temp, mock.patch.object(helper, 'DIRECTORY', Path(temp)), \
                mock.patch.object(helper, 'context', return_value=(ctx, 'fixed-udid')), \
                mock.patch.object(helper, 'command', side_effect=['', helper.Failure('nativeCommandFailed')]) as command:
            helper.A.write_json(Path(temp) / 'contract.json', {'supported': True})
            journal = Path(temp) / 'restore.json'
            helper.A.write_json(journal, {'context': ctx, 'before': 'large', 'receipt': 'fixed-receipt'})
            before = journal.read_bytes()
            report = {}
            with self.assertRaises(helper.Failure):
                helper.execute('restore', None, EXPECTED, report)
            self.assertEqual(report['phase'], 'restoreReadbackStarted')
            self.assertNotIn('systemRestored', report)
            self.assertEqual(journal.read_bytes(), before)
            self.assertEqual([call.args[1] for call in command.call_args_list], ['category-restore', 'category-restored'])

    def test_checkpoints_flush_only_fixed_owned_fields_before_blocking_checkout(self):
        env = {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': 'hellosunghyun/mirror', 'RUNNER_OS': 'macOS'}
        with mock.patch.dict(os.environ, env), mock.patch.object(helper.A, 'identity', return_value=EXPECTED), \
                mock.patch.object(helper.A, 'checkout_matches', side_effect=KeyboardInterrupt), \
                mock.patch('builtins.print') as printed:
            with self.assertRaises(KeyboardInterrupt):
                helper.main(['restore'])
            printed.assert_called_once()
            self.assertIs(printed.call_args.kwargs['flush'], True)
            value = json.loads(printed.call_args.args[0].removeprefix(helper.CHECKPOINT))
            self.assertEqual(value, {**EXPECTED, 'schemaVersion': 1, 'scope': 'diagnosticOnly',
                                     'action': 'restore', 'mode': None, 'phase': 'checkoutStarted'})
        report = {**EXPECTED, 'action': 'restore', 'mode': None, 'stderr': PRIVATE, 'path': PRIVATE}
        with mock.patch('builtins.print') as printed:
            helper.checkpoint(report, 'contextStarted')
            self.assertNotIn(PRIVATE, printed.call_args.args[0])
            with self.assertRaises(helper.Failure):
                helper.checkpoint(report, PRIVATE)
            printed.assert_called_once()
        with mock.patch.object(helper.A, 'read_json', return_value={'supported': True}), \
                mock.patch.object(helper, 'context', side_effect=KeyboardInterrupt), \
                mock.patch('builtins.print') as printed:
            with self.assertRaises(KeyboardInterrupt):
                helper.execute('restore', None, EXPECTED, report)
            value = json.loads(printed.call_args.args[0].removeprefix(helper.CHECKPOINT))
            self.assertEqual(value['phase'], 'contextStarted')
            self.assertIs(printed.call_args.kwargs['flush'], True)
            self.assertNotIn(PRIVATE, printed.call_args.args[0])

    def test_checkout_timeout_is_fixed_failure_before_any_simulator_or_restore_mutation(self):
        env = {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': 'hellosunghyun/mirror', 'RUNNER_OS': 'macOS'}
        with mock.patch.dict(os.environ, env), mock.patch.object(helper.A, 'identity', return_value=EXPECTED), \
                mock.patch.object(helper.A, 'checkout_matches',
                    side_effect=subprocess.TimeoutExpired(PRIVATE, 5, output=PRIVATE, stderr=PRIVATE)), \
                mock.patch.object(helper, 'execute') as execute, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(helper.main(['restore']), 2)
            execute.assert_not_called()
            self.assertNotIn(PRIVATE, output.getvalue())
            report = json.loads(output.getvalue().splitlines()[-1].removeprefix('::notice::Dynamic Type diagnostic: '))
            self.assertEqual(report['phase'], 'checkoutStarted')
            self.assertEqual(report['status'], 'diagnosticUnavailable')

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
            self.assertTrue(output.getvalue().splitlines()[-1].startswith('::notice::Dynamic Type diagnostic: '))
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
        self.assertEqual(workflow.count("MIRROR_DYNAMIC_TYPE_PREBOOT: '1'"), 1)


if __name__ == '__main__':
    unittest.main()
