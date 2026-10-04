"""Actions에서 합성 파일로 실제 설치 루프와 EXIT cleanup의 실패 복구를 검사한다."""

import plistlib
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/ci-adhoc-archive.sh'


class AdHocCleanupTests(unittest.TestCase):
    def run_scenario(self, mode, failure):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            private, public = root / 'private', root / 'publish'
            private.mkdir(); public.mkdir()
            (public / 'candidate.ipa').write_bytes(b'synthetic unpublished IPA')
            project = root / 'project.pbxproj'
            project.write_bytes(b'synthetic changed project')
            (private / 'original-project.pbxproj').write_bytes(b'synthetic original project')
            directories = [root / 'profiles one', root / 'profiles two']
            for directory in directories:
                directory.mkdir()
            stems = ['profile'] if mode == 'single' else ['app', 'widgets', 'share']
            identifiers = {stem: f'abcdef0{index}-2345-6789-abcd-ef0123456789'
                           for index, stem in enumerate(stems, start=1)}
            originals = {}
            for index, stem in enumerate(stems):
                (private / (stem + '.mobileprovision')).write_bytes(('synthetic new ' + stem).encode())
                (private / (stem + '.plist')).write_bytes(plistlib.dumps({'UUID': identifiers[stem]}))
                # 두 설치 위치에서 기존 파일 복구와 새 설치 제거를 함께 검사한다.
                existing = directories[index % 2] / (identifiers[stem] + '.mobileprovision')
                existing.write_bytes(('synthetic existing ' + stem).encode())
                originals[existing] = existing.read_bytes()
            source = SCRIPT.read_text()
            cleanup = source.split('cleanup() {', 1)[1].split('trap cleanup EXIT', 1)[0]
            install = source.split('profile_directories=(', 1)[1].split('\n', 1)[1]
            install = install.split('\nsigning_stage="Xcode 유효 서명 설정 진단"', 1)[0]
            failure_stem = stems[-1] if mode == 'single' else 'widgets'
            declarations = {
                'private_dir': private, 'publish_dir': public, 'project_path': project,
                'keychain_path': root / 'unused-keychain', 'failure_mode': failure,
                'failure_source': private / (failure_stem + '.mobileprovision'),
            }
            shell = 'set -euo pipefail\numask 077\n'
            shell += '\n'.join(f'{key}={shlex.quote(str(value))}' for key, value in declarations.items()) + '\n'
            shell += 'search_changed=0\nkeychain_created=0\nproject_changed=1\ncompleted=0\nprofile_count=0\ninjected=0\n'
            shell += 'previous_keychains=()\ninstalled_profiles=()\nprofile_backups=()\n'
            shell += 'profile_stems=(' + ' '.join(shlex.quote(stem) for stem in stems) + ')\n'
            shell += 'profile_directories=(' + ' '.join(shlex.quote(str(path)) for path in directories) + ')\n'
            shell += '''cp() {
  if [[ "$failure_mode" == install && "$injected" == 0 && "$1" == "$failure_source" ]]; then
    injected=1
    return 9
  fi
  if [[ "$failure_mode" == cleanup && "$1" == -p && "$2" == "$private_dir"/profile-backup-* ]]; then
    return 9
  fi
  command cp "$@"
}
'''
            shell += 'cleanup() {' + cleanup + 'trap cleanup EXIT\n' + install + '\n'
            shell += 'if [[ "$failure_mode" == archive ]]; then exit 8; fi\ncompleted=1\n'
            result = subprocess.run(['bash', '-c', shell], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0 if failure == 'none' else (9 if failure == 'install' else 8 if failure == 'archive' else 1))
            self.assertEqual(project.read_bytes(), b'synthetic original project')
            self.assertFalse(private.exists())
            self.assertEqual(public.exists(), failure == 'none')
            if failure != 'cleanup':
                current = {path: path.read_bytes() for directory in directories for path in directory.iterdir()}
                self.assertEqual(current, originals)
            else:
                self.assertIn('게시를 중지합니다.', result.stderr)
            self.assertEqual(result.stdout, '')
            self.assertNotIn('synthetic existing', result.stderr)

    def test_single_profile_cleanup_restores_existing_and_removes_new_on_success(self):
        self.run_scenario('single', 'none')

    def test_explicit_profiles_cleanup_restores_both_locations_on_success(self):
        self.run_scenario('explicit', 'none')

    def test_second_explicit_profile_install_failure_restores_partial_installation(self):
        self.run_scenario('explicit', 'install')

    def test_archive_failure_removes_publish_and_restores_all_profiles(self):
        self.run_scenario('explicit', 'archive')

    def test_cleanup_failure_prevents_publish_after_otherwise_successful_archive(self):
        self.run_scenario('explicit', 'cleanup')


if __name__ == '__main__':
    unittest.main()
