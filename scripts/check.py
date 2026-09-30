import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]


def source_path(root: Path, relative: str) -> Path:
    path = PurePosixPath(relative)
    if path.is_absolute() or not path.parts or any(
        part in ('', '.', '..') for part in relative.split('/')
    ) or '\\' in relative:
        raise ValueError(f'허용하지 않는 원본 경로: {relative}')
    candidate = root.joinpath(*path.parts)
    if any(part.is_symlink() for part in (candidate, *candidate.parents)
           if part != root and root in part.parents):
        raise ValueError(f'원본 심볼릭 링크는 허용하지 않음: {relative}')
    if not candidate.resolve().is_relative_to(root.resolve()):
        raise ValueError(f'원본 경로 범위 초과: {relative}')
    return candidate


def verify_hash(path: Path, expected: str) -> None:
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != expected:
        raise ValueError(f'SHA-256 불일치: {path.name}')


def verify_source(root: Path) -> Path:
    root = root.resolve()
    source = json.loads((root / 'development-baseline.json').read_text(encoding='utf-8'))['source']
    bundle = source_path(root, source['bundleDirectory'])
    manifest = source_path(bundle, 'MANIFEST.sha256')
    specification = source_path(root, source['specification'])
    verify_hash(manifest, source['manifestSHA256'])
    verify_hash(specification, source['specificationSHA256'])
    entries = {}
    for line in manifest.read_text(encoding='utf-8').splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  (.+)', line)
        if not match:
            raise ValueError(f'MANIFEST 형식 오류: {line}')
        digest, relative = match.groups()
        path = source_path(bundle, relative)
        if relative in entries:
            raise ValueError(f'MANIFEST 중복 경로: {relative}')
        entries[relative] = digest
        verify_hash(path, digest)
    if len(entries) != 22:
        raise ValueError(f'MANIFEST 항목 수 불일치: {len(entries)} != 22')
    files = set()
    for path in bundle.rglob('*'):
        if path.is_symlink():
            raise ValueError(f'원본 심볼릭 링크는 허용하지 않음: {path.relative_to(bundle)}')
        if path.is_file():
            files.add(path.relative_to(bundle).as_posix())
        elif not path.is_dir():
            raise ValueError(f'일반 파일이 아닌 원본 항목: {path.relative_to(bundle)}')
    expected = set(entries) | {'MANIFEST.sha256'}
    if files != expected:
        raise ValueError(f'원본 파일 목록 불일치: 추가={sorted(files - expected)}, 누락={sorted(expected - files)}')
    if len(files) + 1 != source['extractedFileCount'] or source['extractedFileCount'] != 24:
        raise ValueError('원본 파일 수 불일치: 보존 원본은 24개여야 함')
    return bundle


def run_document_validation(bundle: Path) -> subprocess.CompletedProcess:
    with tempfile.TemporaryDirectory(prefix='mirror-preparation-') as temporary:
        copied = Path(temporary) / bundle.name
        shutil.copytree(bundle, copied)
        return subprocess.run(
            [sys.executable, str(copied / 'validation' / 'validate_bundle.py')],
            cwd=copied, capture_output=True, text=True, encoding='utf-8', check=False,
        )


def main(root: Path = ROOT) -> int:
    try:
        bundle = verify_source(root)
        result = run_document_validation(bundle)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f'준비 검사 실패: {error}', file=sys.stderr)
        return 1
    print(result.stdout, end='')
    print(result.stderr, end='', file=sys.stderr)
    return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
