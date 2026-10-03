#!/usr/bin/env python3
"""검증된 공개 산출물 네 개를 run ID별 GitHub prerelease에 게시한다."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urlsplit
from urllib.request import Request, urlopen
import zipfile

ASSET_NAMES = {"Mirror.ipa", "build-manifest.json", "SHA256SUMS", "release-notes.md"}
MAC_ASSET_NAMES = {"Mirror-macOS.dmg", "macos-build-manifest.json", "macos-SHA256SUMS", "macos-release-notes.md"}
MAC_NOTES_MARKER = "<!-- mirror-macos-release -->"
CHECKSUM_NAMES = ASSET_NAMES - {"SHA256SUMS"}
PUBLIC_MANIFEST_KEYS = {
    "result", "distribution", "exportMethod", "platform", "expiresAtUTC", "deviceCount",
    "certificateCount", "certificateMatchesProfile", "requestedEntitlementsValidated", "targets",
    "capabilities", "commitSHA", "buildNumber", "runID", "version", "xcodeVersion", "sdkVersion",
    "ipaSHA256", "ipaBytes", "verification",
}
TARGET_KEYS = {"name", "bundleIdentifier"}
CAPABILITY_KEYS = {"appGroupsAllowed", "cloudContainersAllowed", "appGroupsRequested", "cloudContainersRequested"}
VERIFICATION_KEYS = {"codesign", "embeddedProfile", "getTaskAllow", "versionAndBuild"}


class PublishError(Exception):
    pass


def validate_manifest_keys(manifest: dict) -> None:
    # 알려진 공개 필드만 허용한다. 실패 시 프로파일·계정의 실제 값을 출력하지 않는다.
    if not isinstance(manifest, dict) or not set(manifest) <= PUBLIC_MANIFEST_KEYS:
        raise PublishError("manifest에 허용되지 않은 공개 필드가 있습니다.")
    for name, allowed in (("capabilities", CAPABILITY_KEYS), ("verification", VERIFICATION_KEYS)):
        value = manifest.get(name)
        if not isinstance(value, dict) or set(value) != allowed or any(type(item) is not bool for item in value.values()):
            raise PublishError("manifest의 공개 검증 필드가 유효하지 않습니다.")
    targets = manifest.get("targets")
    if not isinstance(targets, list) or not targets:
        raise PublishError("manifest의 공개 target 필드가 유효하지 않습니다.")
    for target in targets:
        if (not isinstance(target, dict) or set(target) != TARGET_KEYS
                or any(not isinstance(item, str) for item in target.values())):
            raise PublishError("manifest의 공개 target 필드가 유효하지 않습니다.")
    # 목록이나 객체를 문자열 메타데이터 안에 넣어 비공개 자료를 게시할 수 없게 한다.
    for key, value in manifest.items():
        if key not in {"targets", "capabilities", "verification"} and not isinstance(value, (str, int, bool)):
            raise PublishError("manifest의 공개 메타데이터가 유효하지 않습니다.")


def validate_assets(directory: Path, commit: str, run_number: str, run_id: str) -> tuple[dict, dict[str, str]]:
    if not directory.is_dir() or {path.name for path in directory.iterdir()} != ASSET_NAMES:
        raise PublishError("게시 폴더에는 허용한 공개 산출물 네 개만 있어야 합니다.")
    for name in ASSET_NAMES:
        path = directory / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size <= 0:
            raise PublishError("게시 산출물이 없거나 일반 파일이 아닙니다.")
    try:
        manifest = json.loads((directory / "build-manifest.json").read_text(encoding="utf-8"))
        checksums: dict[str, str] = {}
        for line in (directory / "SHA256SUMS").read_text(encoding="ascii").splitlines():
            match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_.-]+)", line)
            if not match or match[2] not in CHECKSUM_NAMES or match[2] in checksums:
                raise PublishError("SHA256SUMS 형식이 유효하지 않습니다.")
            checksums[match[2]] = match[1]
        if set(checksums) != CHECKSUM_NAMES:
            raise PublishError("SHA256SUMS가 모든 공개 파일을 포함해야 합니다.")
    except (OSError, UnicodeError, ValueError) as error:
        raise PublishError("manifest와 SHA256SUMS를 읽을 수 없습니다.") from error
    validate_manifest_keys(manifest)
    hashes = {name: hashlib.sha256((directory / name).read_bytes()).hexdigest() for name in ASSET_NAMES}
    if any(hashes[name] != value for name, value in checksums.items()):
        raise PublishError("게시 산출물의 SHA-256이 일치하지 않습니다.")
    if (manifest.get("commitSHA") != commit or str(manifest.get("buildNumber")) != run_number
            or str(manifest.get("runID")) != run_id):
        raise PublishError("manifest의 commit/run/build가 현재 실행과 다릅니다.")
    if manifest.get("ipaSHA256") != hashes["Mirror.ipa"] or manifest.get("ipaBytes") != (directory / "Mirror.ipa").stat().st_size:
        raise PublishError("manifest의 IPA SHA-256 또는 크기가 다릅니다.")
    verification = manifest.get("verification", {})
    if (verification.get("codesign") is not True or verification.get("embeddedProfile") is not True
            or verification.get("getTaskAllow") is not False or verification.get("versionAndBuild") is not True):
        raise PublishError("실제 서명과 profile 검증을 완료한 IPA만 게시할 수 있습니다.")
    if manifest.get("distribution") != "ad-hoc" or manifest.get("exportMethod") != "release-testing":
        raise PublishError("Ad Hoc release-testing export만 게시할 수 있습니다.")
    if not zipfile.is_zipfile(directory / "Mirror.ipa"):
        raise PublishError("유효한 IPA ZIP이 아닙니다.")
    return manifest, hashes


class GitHub:
    def __init__(self, repository: str, token: str) -> None:
        self.base = f"https://api.github.com/repos/{repository}"
        self.token = token

    def request(self, method: str, endpoint: str, *, value: dict | None = None,
                content: bytes | None = None, content_type: str = "application/json",
                missing_ok: bool = False) -> dict | list | None:
        url = endpoint if endpoint.startswith("https://") else self.base + endpoint
        if urlsplit(url).hostname not in {"api.github.com", "uploads.github.com"}:
            raise PublishError("허용되지 않은 GitHub API 주소입니다.")
        data = json.dumps(value).encode("utf-8") if value is not None else content
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
                   "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "mirror-adhoc-release",
                   "Content-Type": content_type}
        try:
            with urlopen(Request(url, data=data, headers=headers, method=method), timeout=60) as response:
                body = response.read()
                return json.loads(body) if body else None
        except HTTPError as error:
            if missing_ok and error.code == 404:
                return None
            raise PublishError(f"GitHub {method} 요청이 실패했습니다(HTTP {error.code}).") from None
        except (URLError, OSError, ValueError):
            raise PublishError("GitHub 요청 또는 응답 처리에 실패했습니다.") from None

    def verify_tag(self, tag: str, expected_commit: str) -> bool:
        reference = self.request("GET", f"/git/ref/tags/{quote(tag, safe='')}", missing_ok=True)
        if reference is None:
            return False
        target = reference["object"]
        for _ in range(5):
            if target.get("type") == "commit":
                if target.get("sha") != expected_commit:
                    raise PublishError("같은 release 태그가 다른 commit을 가리킵니다.")
                return True
            if target.get("type") != "tag":
                break
            nested = self.request("GET", f"/git/tags/{target['sha']}")
            target = nested["object"]
        raise PublishError("release 태그의 commit을 확인할 수 없습니다.")


def publish(client: GitHub, directory: Path, manifest: dict, hashes: dict[str, str],
            commit: str, run_id: str) -> str:
    tag = f"adhoc-{run_id}"
    release = client.request("GET", f"/releases/tags/{quote(tag, safe='')}", missing_ok=True)
    tag_exists = client.verify_tag(tag, commit)
    notes = (directory / "release-notes.md").read_text(encoding="utf-8")
    attributes = {"tag_name": tag, "target_commitish": commit, "prerelease": True,
                  "name": f"미러 Ad Hoc {manifest['version']} ({manifest['buildNumber']})", "body": notes}
    companions = {}
    if release is not None:
        if not tag_exists and release.get("target_commitish") != commit:
            raise PublishError("기존 draft release의 commit이 현재 실행과 다릅니다.")
        assets = release.get("assets", [])
        if any(asset.get("name") not in ASSET_NAMES | MAC_ASSET_NAMES for asset in assets):
            raise PublishError("같은 release에 예상하지 않은 자산이 있습니다.")
        for asset in assets:
            if asset.get("name") not in MAC_ASSET_NAMES:
                continue
            if (not tag_exists or asset["name"] in companions
                    or type(asset.get("id")) is not int or asset["id"] <= 0
                    or type(asset.get("size")) is not int or asset["size"] <= 0
                    or not isinstance(asset.get("digest"), str)
                    or not re.fullmatch(r"sha256:[0-9a-f]{64}", asset["digest"])):
                raise PublishError("기존 macOS 공개 자산의 계약을 확인할 수 없습니다.")
            companions[asset["name"]] = {key: asset[key] for key in ("id", "name", "size", "digest")}
        if companions:
            body = release.get("body", "")
            if isinstance(body, str) and MAC_NOTES_MARKER in body:
                attributes["body"] = notes.rstrip() + "\n\n" + MAC_NOTES_MARKER + body.split(MAC_NOTES_MARKER, 1)[1]
        ios_assets = [asset for asset in assets if asset.get("name") in ASSET_NAMES]
        if (tag_exists and not release.get("draft") and release.get("prerelease") and len(ios_assets) == 4
                and {asset.get("name") for asset in ios_assets} == ASSET_NAMES
                and all(asset.get("digest") == "sha256:" + hashes[asset["name"]]
                        and asset.get("size") == (directory / asset["name"]).stat().st_size for asset in ios_assets)):
            return release["html_url"]
        # 재실행도 같은 태그를 사용한다. 불완전한 자산을 공개하지 않도록 draft에서 교체한다.
        release = client.request("PATCH", f"/releases/{release['id']}", value={**attributes, "draft": True})
    else:
        release = client.request("POST", "/releases", value={**attributes, "draft": True})
    release_id = release["id"]
    for asset in release.get("assets", []):
        if asset.get("name") in ASSET_NAMES:
            client.request("DELETE", f"/releases/assets/{asset['id']}")
    upload_url = release["upload_url"].split("{", 1)[0]
    for name in sorted(ASSET_NAMES):
        uploaded = client.request("POST", upload_url + "?" + urlencode({"name": name}),
                                  content=(directory / name).read_bytes(),
                                  content_type="application/octet-stream")
        if uploaded.get("name") != name or uploaded.get("size") != (directory / name).stat().st_size:
            raise PublishError("업로드한 공개 자산의 이름이나 크기가 다릅니다.")
        if uploaded.get("digest") != "sha256:" + hashes[name]:
            raise PublishError("업로드한 공개 자산의 SHA-256이 다릅니다.")
    refreshed = client.request("GET", f"/releases/{release_id}")
    assets = refreshed.get("assets", [])
    if len(assets) != 4 + len(companions) or {asset.get("name") for asset in assets} != ASSET_NAMES | companions.keys():
        raise PublishError("공개 자산 네 개를 모두 업로드해야 release를 공개할 수 있습니다.")
    for asset in assets:
        if asset["name"] in companions:
            if {key: asset.get(key) for key in ("id", "name", "size", "digest")} != companions[asset["name"]]:
                raise PublishError("iOS 재게시 중 기존 macOS 자산이 변경되었습니다.")
            continue
        if (asset.get("digest") != "sha256:" + hashes[asset["name"]]
                or asset.get("size") != (directory / asset["name"]).stat().st_size):
            raise PublishError("게시 직전 공개 자산의 SHA-256 검증에 실패했습니다.")
    published = client.request("PATCH", f"/releases/{release_id}", value={**attributes, "draft": False})
    if published.get("draft") or published.get("prerelease") is not True:
        raise PublishError("release 게시 상태를 확인할 수 없습니다.")
    if not client.verify_tag(tag, commit):
        raise PublishError("게시한 release 태그의 commit을 확인할 수 없습니다.")
    return published["html_url"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--publish-dir", type=Path, required=True)
    parser.add_argument("--commit-sha", required=True)
    parser.add_argument("--run-number", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
    args = parser.parse_args()
    try:
        if (not re.fullmatch(r"[0-9a-f]{40}", args.commit_sha)
                or not re.fullmatch(r"[1-9][0-9]*", args.run_number)
                or not re.fullmatch(r"[1-9][0-9]*", args.run_id)
                or not args.repository or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository)):
            raise PublishError("repository, commit, run 번호 형식이 유효하지 않습니다.")
        token = os.environ.get("GITHUB_TOKEN")
        if not token:
            raise PublishError("Actions GITHUB_TOKEN이 필요합니다.")
        manifest, hashes = validate_assets(args.publish_dir, args.commit_sha, args.run_number, args.run_id)
        url = publish(GitHub(args.repository, token), args.publish_dir, manifest, hashes, args.commit_sha, args.run_id)
        output = os.environ.get("GITHUB_OUTPUT")
        if output:
            with open(output, "a", encoding="utf-8") as destination:
                destination.write(f"release_url={url}\n")
        print(f"검증한 Ad Hoc prerelease를 게시했습니다: {url}")
        return 0
    except (PublishError, OSError, KeyError, TypeError, ValueError) as error:
        message = str(error) if isinstance(error, PublishError) else "Ad Hoc 게시를 완료할 수 없습니다."
        print("::error::" + message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A"), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
