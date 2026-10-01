#!/usr/bin/env python3
"""비공개 Xcode 로그를 읽고 고정 오류 분류와 줄 수만 공개한다.

counts는 고유 오류 수가 아니라 진단 줄 수다. 한 줄은 가장 구체적인
분류 하나에만 배정하며, 알 수 없는 error 줄은 errorLineCount에만 더한다.
원문, 정규식 일치값, 파일 경로와 예외 메시지는 출력하지 않는다.
"""

import argparse
import json
import os
import re
import stat
import sys


NOTICE_PREFIX = '::notice::Ad Hoc diagnostic summary: '
MAX_LOG_BYTES = 128 * 1024 * 1024
ANSI_ESCAPE = re.compile(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))')
ERROR_MARKER = re.compile(r'\b(?:fatal\s+)?error:', re.IGNORECASE)
NON_ERROR_MARKER = re.compile(r'\b(?:warning|note):', re.IGNORECASE)
# 일부 codesign/ld 오류는 error: 접두사를 쓰지 않는다. 요약 실패 줄은 제외한다.
BARE_ERROR_MARKER = re.compile(
    r'User interaction is not allowed|errSecInteractionNotAllowed|errSecInternalComponent|'
    r'CSSMERR_TP_(?:NOT_TRUSTED|CERT_EXPIRED|CERT_REVOKED)|'
    r'Undefined symbols for architecture|duplicate symbol|'
    r'^\s*ld:.*(?:not found|failed)|SecKeychainUnlock.*failed', re.IGNORECASE)

# 구체적인 서명 원인과 linker 오류를 일반 provisioning/compile보다 먼저 검사한다.
RULES = tuple((key, re.compile(pattern, re.IGNORECASE)) for key, pattern in (
    ('frameworkUnsupportedProvisioning', r'does not support provisioning profiles'),
    ('manualAutomaticConflict', r'conflicting provisioning settings|'
     r'automatically signed.*manually specified|Xcode managed.*manually managed|'
     r'automatic signing.*(?:manual|provisioning profile).*conflict'),
    ('signingMismatch', r'provisioning profile.*(?:doesn.t|does not) include signing certificate|'
     r'provisioning profile.*(?:doesn.t|does not) match|'
     r'provisioning profile.*has app ID.*(?:does not|doesn.t) match|'
     r'signing certificate.*(?:does not|doesn.t) match.*provisioning profile'),
    ('missingTeam', r'requires a development team|No Team ID found in archive|'
     r'(?:development team|team ID).*(?:not set|not specified|missing)'),
    ('missingProfile', r'No profiles for.*were found|No provisioning profiles?.*(?:found|available)|'
     r'(?:requires|missing|could not find|cannot find).*provisioning profile|'
     r'provisioning profile.*(?:could not|cannot) be found'),
    ('keychainInteraction', r'User interaction is not allowed|errSecInteractionNotAllowed|'
     r'SecKeychainUnlock.*failed|keychain.*(?:locked|interaction.*not allowed)'),
    ('certificate', r'No signing certificate.*found|No .*signing certificate.*private key.*found|'
     r'signing certificate.*(?:expired|revoked|not trusted|not found)|'
     r'certificate.*(?:has expired|has been revoked)|'
     r'CSSMERR_TP_(?:NOT_TRUSTED|CERT_EXPIRED|CERT_REVOKED)'),
    ('provisioning', r'provisioning profile|provisioning.*(?:failed|invalid|expired)|'
     r'entitlement.*(?:not permitted|not allowed|missing|doesn.t|does not)'),
    ('destination', r'Unable to find a destination matching|Found no destinations|'
     r'Unable to find.*destination|destination.*(?:not available|not supported|ineligible)'),
    ('sdk', r'SDK.*(?:cannot be located|not found|not installed|not supported)|'
     r'unable to find.*sdk|iOS [0-9.]+ is not installed|'
     r'platform.*(?:not installed|not supported)|requires Xcode|'
     r'unsupported.*(?:SDK|iOS deployment target)'),
    ('project', r'Unable to open project|does not contain.*(?:Xcode project|scheme)|'
     r'(?:project|workspace).*(?:does not exist|cannot be opened|could not be opened|not found)|'
     r'is not a project file|Could not resolve package dependencies'),
    ('link', r'Undefined symbols for architecture|duplicate symbol|'
     r'ld:.*(?:not found|failed)|linker command failed|'
     r'building for.*but linking in|symbol\(s\) not found'),
    ('compile', r'\.(?:swift|m|mm|c|cc|cpp|h|hpp):[0-9]+(?::[0-9]+)?:\s*(?:fatal\s+)?error:|'
     r'(?:emit-module|compile) command failed|no such module|could not build.*module|'
     r'cannot find.*in scope|cannot find type|failed to emit.*module'),
    # 이 값만으로 인증서 신뢰 문제나 keychain 접근 문제를 확정하지 않는다.
    ('codeSigning', r'errSecInternalComponent|codesign.*(?:failed|failure)|'
     r'code signing.*(?:failed|failure|invalid)'),
))


class InvalidArguments(ValueError):
    """argparse가 비공개 인자나 경로를 오류 출력에 포함하지 않도록 한다."""


class PrivateArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise InvalidArguments() from None


def empty_counts():
    return {'errorLineCount': 0, **{key: 0 for key, _ in RULES}}


def summarize_lines(lines):
    counts = empty_counts()
    for raw in lines:
        line = ANSI_ESCAPE.sub('', raw)
        if line.lstrip().startswith('::'):
            continue
        if not ERROR_MARKER.search(line):
            if NON_ERROR_MARKER.search(line) or not BARE_ERROR_MARKER.search(line):
                continue
        counts['errorLineCount'] += 1
        for key, pattern in RULES:
            if pattern.search(line):
                counts[key] += 1
                break
    return counts


def summarize_file(path):
    # symlink/FIFO를 입력으로 사용하지 않으며 로그 전체를 메모리에 보관하지 않는다.
    flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0)
    descriptor = os.open(path, flags)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_LOG_BYTES:
            raise OSError()
        stream = os.fdopen(descriptor, 'r', encoding='utf-8', errors='replace')
        descriptor = None
        with stream:
            return summarize_lines(stream)
    finally:
        if descriptor is not None:
            os.close(descriptor)


def emit_summary(phase, status, counts):
    print(NOTICE_PREFIX + json.dumps({'phase': phase, 'status': status, 'counts': counts},
                                    sort_keys=True, separators=(',', ':')))


def main(argv=None):
    phase = None
    counts = empty_counts()
    try:
        parser = PrivateArgumentParser(prog='ci-adhoc-diagnostics', add_help=False)
        parser.add_argument('--phase', required=True, choices=('archive', 'export'))
        parser.add_argument('--log-file', required=True)
        arguments = parser.parse_args(argv)
        phase = arguments.phase
        counts = summarize_file(arguments.log_file)
    except InvalidArguments:
        emit_summary(None, 'invalidArguments', counts)
        return 2
    except OSError:
        emit_summary(phase, 'inputUnavailable', counts)
        return 1
    except Exception:
        emit_summary(phase, 'processingFailed', counts)
        return 1
    emit_summary(phase, 'classified', counts)
    return 0


if __name__ == '__main__':
    sys.exit(main())
