#!/usr/bin/env python3
"""현재 unsigned Mac UI query 중 단일 private sample. UI 성공 판정에는 관여하지 않는다."""
import ctypes
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

CASE = 'testCaptureRemainsUnassignedUntilReviewExplicitlyChoosesToday'
PENDING = 'UI native query pending: settingsClose'
COMPLETE = 'UI native query complete: settingsClose'
EVENT = re.compile(r"Test Case '[-+]\[([A-Za-z0-9_.]+) (test[A-Za-z0-9_]+)\]' (started|passed|failed|skipped)(?=[\s.]|$)")
STAGES = frozenset(('arguments', 'watchSetup', 'logRead', 'receiptBefore', 'processPathReader',
                    'processListBefore', 'processOwnerBefore', 'queryBefore', 'temporaryDirectory',
                    'sample', 'queryAfter', 'processListAfter', 'processOwnerAfter', 'receiptAfter', 'sampleRead'))
CHECK_FAILURES = frozenset(('duplicateField', 'identityUnavailable', 'receiptUnavailable',
                           'receiptMismatch', 'executableMismatch', 'processListUnavailable',
                           'processOwnerUnavailable', 'startUnavailable', 'logUnavailable'))
PROCESS_COUNTS = ('rowCount', 'positivePIDCount', 'sameUIDCount', 'bornAfterStartCount', 'matchingPathCount')


class CheckFailure(ValueError):
    """이 helper가 직접 판정한 고정 검증 실패. 외부 예외 문자열과 구분한다."""


def process_filter_details(counts):
    if (type(counts) is not dict or set(counts) != set(PROCESS_COUNTS) | {'countsCapped', 'scanComplete'}
            or any(type(counts[key]) is not int or not 0 <= counts[key] <= 65535 for key in PROCESS_COUNTS)
            or any(type(counts[key]) is not bool for key in ('countsCapped', 'scanComplete'))
            or any(counts[prior] < counts[later] for prior, later in zip(PROCESS_COUNTS, PROCESS_COUNTS[1:]))):
        return {}
    return {'processFilterCounts': dict(counts)}


def failure_details(error, stage, process_filters=None):
    # stage는 마지막 진입 경계이며 OS 원인 확정값이 아니다. 예외 원문은 읽거나 출력하지 않는다.
    kind = 'unknown'
    if (isinstance(error, CheckFailure) and len(error.args) == 1
            and type(error.args[0]) is str and error.args[0] in CHECK_FAILURES):
        kind = error.args[0]
    else:
        for error_type, value in ((json.JSONDecodeError, 'jsonInvalid'), (UnicodeError, 'textInvalid'),
                (PermissionError, 'permissionDenied'), (FileNotFoundError, 'fileUnavailable'),
                (subprocess.TimeoutExpired, 'processTimeout'), (subprocess.SubprocessError, 'processError'),
                (OSError, 'osError'), (KeyError, 'fieldMissing'), (TypeError, 'typeInvalid'),
                (AttributeError, 'attributeUnavailable'), (ValueError, 'valueInvalid')):
            if isinstance(error, error_type):
                kind = value
                break
    result = {'stage': stage if type(stage) is str and stage in STAGES else 'unknown', 'failureKind': kind}
    if result['stage'] in ('processOwnerBefore', 'processOwnerAfter'):
        result.update(process_filter_details(process_filters))
    return result


class MarkerState:
    def __init__(self):
        self.started = False
        self.pending_at = None
        self.done = False

    def feed(self, line, now):
        if self.done:
            return
        event = EVENT.search(line)
        if event:
            owner, method, phase = event.groups()
            if owner != 'MirrorMacUITests.MirrorUITests' or method != CASE or phase != 'started' or self.started:
                self.done = True
            else:
                self.started = True
        value = line.strip()
        if value.startswith('UI native query '):
            if value == PENDING and self.started and self.pending_at is None:
                self.pending_at = now
            else:
                self.done = True

    def ready(self, now):
        return not self.done and self.pending_at is not None and now - self.pending_at >= 15


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise CheckFailure('duplicateField')
        result[key] = value
    return result


def verify_receipt(directory, environment):
    expected = {'platform': 'macos', 'scheme': 'MirrorMac', 'sdk': 'macosx',
                'destination': 'platform=macOS,arch=arm64',
                **{key: environment.get(env, '') for key, env in (
                    ('run_id', 'GITHUB_RUN_ID'), ('run_attempt', 'GITHUB_RUN_ATTEMPT'),
                    ('commit', 'GITHUB_SHA'), ('build_number', 'GITHUB_RUN_NUMBER'))}}
    if not re.fullmatch(r'[0-9a-f]{40}', expected['commit']) or any(
            not re.fullmatch(r'[1-9][0-9]{0,19}', expected[key]) for key in ('run_id', 'run_attempt', 'build_number')):
        raise CheckFailure('identityUnavailable')
    directory = Path(directory).resolve(strict=True)
    receipt_path, context_path = directory / 'ui-build-receipt.json', directory / 'unit-context.json'
    if any(path.is_symlink() or not path.is_file() for path in (receipt_path, context_path)):
        raise CheckFailure('receiptUnavailable')
    context_bytes = context_path.read_bytes()
    receipt = json.loads(receipt_path.read_bytes(), object_pairs_hook=unique_object)
    if (json.loads(context_bytes, object_pairs_hook=unique_object) != expected or receipt['context'] != expected
            or type(receipt['format_version']) is not int or receipt['format_version'] != 1
            or receipt['configuration'] != 'Debug' or receipt['ui_scheme'] != 'MirrorMacUI'
            or receipt['code_signing_allowed'] is not False or receipt['code_coverage'] is not False
            or receipt['unit_context_sha256'] != hashlib.sha256(context_bytes).hexdigest()):
        raise CheckFailure('receiptMismatch')
    products = (directory / 'DerivedData/Build/Products').resolve(strict=True)
    record = receipt['app']['executable']
    relative = Path(record['path'])
    if (relative.is_absolute() or '..' in relative.parts or record['path'] != record['resolved_path']
            or receipt['app']['build_number'] != expected['build_number']):
        raise CheckFailure('executableMismatch')
    executable = (products / relative).resolve(strict=True)
    if (not products.is_relative_to(directory) or not executable.is_relative_to(products)
            or not executable.is_file() or executable != products / relative
            or hashlib.sha256(executable.read_bytes()).hexdigest() != record['sha256']):
        raise CheckFailure('executableMismatch')
    return executable, record['sha256'], {key: expected[key] for key in ('commit', 'run_id', 'run_attempt', 'build_number')}


def process_rows():
    result = subprocess.run(['/bin/ps', '-axo', 'pid=,uid=,lstart='], capture_output=True,
                            timeout=3, env={**os.environ, 'LC_ALL': 'C', 'TZ': 'UTC'})
    if result.returncode:
        raise CheckFailure('processListUnavailable')
    rows = []
    for line in result.stdout.decode('ascii', 'strict').splitlines():
        values = line.split(None, 2)
        if len(values) == 3:
            birth = datetime.datetime.strptime(values[2], '%a %b %d %H:%M:%S %Y').replace(
                tzinfo=datetime.timezone.utc).timestamp()
            rows.append((int(values[0]), int(values[1]), birth))
    return rows


def process_path_reader():
    library = ctypes.CDLL('/usr/lib/libproc.dylib')
    function = library.proc_pidpath
    function.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    function.restype = ctypes.c_int

    def path_for(pid):
        buffer = ctypes.create_string_buffer(4096)
        return Path(os.fsdecode(buffer.value)).resolve() if function(pid, buffer, len(buffer)) > 0 else None
    return path_for


def select_process(rows, executable, started, uid, pid_path, *, diagnostic=None):
    # 공개 집계만 제한한다. 모든 원본 후보의 필터 순서와 유일성 판정은 그대로 유지한다.
    counts = {**dict.fromkeys(PROCESS_COUNTS, 0), 'countsCapped': False, 'scanComplete': False}
    if diagnostic is not None:
        diagnostic['processFilterCounts'] = counts

    def passed(key):
        if diagnostic is not None:
            if counts[key] == 65535:
                counts['countsCapped'] = True
            else:
                counts[key] += 1

    candidates = []
    for pid, owner, birth in rows:
        passed('rowCount')
        if not pid > 0:
            continue
        passed('positivePIDCount')
        if not owner == uid:
            continue
        passed('sameUIDCount')
        if not birth > started:
            continue
        passed('bornAfterStartCount')
        if not pid_path(pid) == executable:
            continue
        passed('matchingPathCount')
        candidates.append((pid, birth))
    counts['scanComplete'] = True
    if len(candidates) != 1:
        raise CheckFailure('processOwnerUnavailable')
    return candidates[0]


def classify_sample(text):
    counts = {key: 0 for key in ('runLoop', 'synchronousWait', 'swiftUI', 'coreData', 'attributeGraph', 'appKit', 'app', 'other')}
    binary_categories = {'Mirror': 'app', 'Mirror.debug.dylib': 'app', 'SwiftUI': 'swiftUI',
                         'SwiftUICore': 'swiftUI', 'CoreData': 'coreData',
                         'AttributeGraph': 'attributeGraph', 'AppKit': 'appKit'}
    in_graph = False
    main = False
    observed = False
    for line in text.splitlines():
        if line.strip() == 'Call graph:':
            in_graph = True
            continue
        if not in_graph:
            continue
        if line.startswith('Total number in stack') or line.startswith('Binary Images:'):
            break
        if re.match(r'^\s+\d+\s+Thread_', line):
            main = bool(re.fullmatch(r'\s+\d+\s+Thread_[0-9a-fA-Fx]+\s+DispatchQueue_\d+: com\.apple\.main-thread\s+\(serial\)\s*', line))
            observed = observed or main
            continue
        frame = re.match(r'^[\s+!:|]+\d+\s+(.+?)\s+\(in ([^)]+)\)(?:\s|$)', line) if main else None
        if frame:
            symbol, binary = frame.groups()
            category = ('runLoop' if symbol in ('mach_msg2_trap', 'mach_msg_trap', 'CFRunLoopRunSpecific', '__CFRunLoopRun', '-[NSApplication run]') else
                        'synchronousWait' if symbol in ('semaphore_wait_trap', '__ulock_wait', '__psynch_mutexwait', 'dispatch_sync_f_slow', '__DISPATCH_WAIT_FOR_QUEUE__') else
                        binary_categories.get(binary, 'other'))
            counts[category] += 1
    return {'mainThreadObserved': observed, 'frameCounts': counts}


def sample_once(pid, directory, stopped):
    output = directory / 'sample.txt'
    output.touch(mode=0o600, exist_ok=False)
    with (directory / 'sample-command.txt').open('xb') as private_output:
        os.chmod(private_output.name, 0o600)
        process = subprocess.Popen(['/usr/bin/sample', str(pid), '3', '10', '-file', str(output)],
                                   stdout=private_output, stderr=private_output)
        deadline = time.monotonic() + 8
        try:
            while process.poll() is None:
                if stopped() or time.monotonic() >= deadline:
                    process.terminate()
                    try:
                        process.wait(timeout=1)
                    except subprocess.TimeoutExpired:
                        process.kill()
                    return None
                time.sleep(0.1)
            return process.returncode
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()


def watch(directory, parent_pid, diagnostic=None):
    diagnostic = {} if diagnostic is None else diagnostic
    diagnostic['stage'] = 'watchSetup'
    stopped = False

    def stop(signum, frame):
        nonlocal stopped
        stopped = True
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    state = MarkerState()
    position = 0
    log = directory / 'ui.log'
    marker = directory / 'ui-start.marker'
    if marker.is_symlink() or not marker.is_file():
        raise CheckFailure('startUnavailable')
    started = marker.stat().st_mtime

    def refresh():
        nonlocal position
        if log.is_symlink():
            raise CheckFailure('logUnavailable')
        if log.is_file():
            if log.stat().st_mtime < started or log.stat().st_size < position:
                raise CheckFailure('logUnavailable')
            with log.open('r', encoding='utf-8', errors='replace') as stream:
                stream.seek(position)
                while True:
                    offset = stream.tell()
                    line = stream.readline()
                    if not line or not line.endswith('\n'):
                        position = offset
                        break
                    state.feed(line, time.monotonic())
    while not stopped and os.getppid() == parent_pid:
        diagnostic['stage'] = 'logRead'
        refresh()
        if state.done:
            return {'status': 'queryEndedBeforeSample'}
        if state.ready(time.monotonic()):
            diagnostic['stage'] = 'receiptBefore'
            executable, digest, identity = verify_receipt(directory, os.environ)
            diagnostic['stage'] = 'processPathReader'
            pid_path = process_path_reader()
            diagnostic['stage'] = 'processListBefore'
            rows = process_rows()
            diagnostic['stage'] = 'processOwnerBefore'
            diagnostic.pop('processFilterCounts', None)
            owner = select_process(rows, executable, started, os.getuid(), pid_path, diagnostic=diagnostic)
            diagnostic['stage'] = 'queryBefore'
            refresh()
            if stopped or not state.ready(time.monotonic()):
                return {'status': 'queryEndedBeforeSample', **identity}
            diagnostic['stage'] = 'temporaryDirectory'
            temporary = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
            with tempfile.TemporaryDirectory(prefix='mirror-private-sample-', dir=temporary) as name:
                private = Path(name)
                os.chmod(private, 0o700)
                diagnostic['stage'] = 'sample'
                code = sample_once(owner[0], private, lambda: stopped)
                diagnostic['stage'] = 'queryAfter'
                refresh()
                if stopped or not state.ready(time.monotonic()):
                    return {'status': 'queryEndedDuringSample', 'sampleExit': code, **identity}
                try:
                    diagnostic['stage'] = 'processListAfter'
                    rows = process_rows()
                    diagnostic['stage'] = 'processOwnerAfter'
                    diagnostic.pop('processFilterCounts', None)
                    same_owner = select_process(rows, executable, started, os.getuid(), pid_path, diagnostic=diagnostic) == owner
                    diagnostic['stage'] = 'receiptAfter'
                    same_build = verify_receipt(directory, os.environ)[:2] == (executable, digest)
                except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError) as error:
                    return {'status': 'ownerChanged', 'sampleExit': code, **identity,
                            **failure_details(error, diagnostic['stage'], diagnostic.get('processFilterCounts'))}
                if not same_owner or not same_build:
                    return {'status': 'ownerChanged', 'sampleExit': code, **identity,
                            **(process_filter_details(diagnostic.get('processFilterCounts')) if not same_owner else {})}
                if code != 0:
                    return {'status': 'sampleUnavailable', 'sampleExit': code, **identity}
                diagnostic['stage'] = 'sampleRead'
                output = private / 'sample.txt'
                if output.is_symlink() or not output.is_file() or output.stat().st_size > 4 * 1024 * 1024:
                    return {'status': 'sampleFormatUnavailable', 'sampleExit': code, **identity}
                classification = classify_sample(output.read_text(errors='replace'))
                recognized = classification['mainThreadObserved'] and sum(classification['frameCounts'].values()) > 0
                return {'status': 'sampleObserved' if recognized else 'sampleUnclassified',
                        'sampleExit': code, **identity, **classification}
        time.sleep(0.25)
    return {'status': 'watchStopped'}


def main():
    diagnostic = {'stage': 'arguments'}
    try:
        if sys.platform != 'darwin':
            result = {'status': 'platformUnavailable'}
        else:
            result = watch(Path(sys.argv[1]).resolve(strict=True), int(sys.argv[2]), diagnostic)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError) as error:
        result = {'status': 'diagnosticUnavailable',
                  **failure_details(error, diagnostic['stage'], diagnostic.get('processFilterCounts'))}
    print('::notice::Mac live sample: ' + json.dumps(result, sort_keys=True), flush=True)


if __name__ == '__main__':
    main()
