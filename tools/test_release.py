"""Offline regression checks for tag validation and atomic release publication."""

import copy
import json
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import release


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        # Keep every local fixture inside the release copy.
        self.temporary = tempfile.TemporaryDirectory(dir=Path(__file__).parent)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / ".github").mkdir()
        (self.root / ".github/flutter-version").write_text("3.47.2\n", encoding="utf-8")
        (self.root / "pubspec.yaml").write_text("name: fixture\nversion: 0.1.0+1\n", encoding="utf-8")
        self.dist = self.root / "dist"
        self.dist.mkdir()
        self.env = {
            "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/tags/v0.1.0",
            "GITHUB_REPOSITORY": "Example/novel", "GITHUB_SHA": "a" * 40,
        }
        self.pack()

    def pack(self, apk_version="0.1.0+1", ipa_version="0.1.0+1", bundle_version="0.1.0", bundle_build="1"):
        with zipfile.ZipFile(self.dist / release.APK, "w") as archive:
            archive.writestr("AndroidManifest.xml", "fixture")
            archive.writestr("assets/flutter_assets/pubspec.yaml", f"version: {apk_version}\n")
        with zipfile.ZipFile(self.dist / release.IPA, "w") as archive:
            archive.writestr("Payload/Runner.app/Info.plist", plistlib.dumps({
                "CFBundleShortVersionString": bundle_version, "CFBundleVersion": bundle_build,
            }))
            archive.writestr("Payload/Runner.app/Frameworks/App.framework/flutter_assets/pubspec.yaml",
                             f"version: {ipa_version}\n")
        release.write_checksums(self.dist)

    def assets(self):
        return [{
            "name": name, "state": "uploaded", "size": (self.dist / name).stat().st_size,
            "digest": f"sha256:{release.digest(self.dist / name)}",
        } for name in (*release.ARTIFACTS, release.CHECKSUMS)]

    def fake_github(self, *, existing=None, remote_assets=None, tag_sha=None, corrupt_download=False):
        calls = []
        draft = {"id": 42, "tag_name": "v0.1.0", "draft": True, "prerelease": False,
                 "target_commitish": self.env["GITHUB_SHA"], "assets": self.assets()}

        def invoke(*args, payload=None):
            calls.append((args, copy.deepcopy(payload)))
            if args[0:2] == ("release", "upload"):
                return ""
            if args[0:2] == ("release", "download"):
                directory = Path(args[args.index("--dir") + 1])
                for name in (*release.ARTIFACTS, release.CHECKSUMS):
                    shutil.copyfile(self.dist / name, directory / name)
                if corrupt_download:
                    (directory / release.IPA).write_bytes(b"damaged in transit")
                return ""
            route = args[1].removeprefix("repos/Example/novel/")
            if route.startswith("commits/"):
                return json.dumps({"sha": tag_sha or self.env["GITHUB_SHA"]})
            if route.startswith("releases?"):
                return json.dumps([existing or []])
            if route == "releases":
                return json.dumps(draft)
            if route == "releases/42":
                return json.dumps({**draft, "assets": self.assets() if remote_assets is None else remote_assets})
            raise AssertionError(f"unexpected GitHub call: {args}")

        return calls, invoke

    def run_publish(self, invoke):
        real_temporary = tempfile.TemporaryDirectory

        def local_temporary(**kwargs):
            return real_temporary(dir=self.root, **kwargs)

        with patch.object(release, "gh", side_effect=invoke), patch.object(
            release.tempfile, "TemporaryDirectory", side_effect=local_temporary
        ):
            release.publish(self.root, self.dist, self.env)

    def test_exact_tag_and_build_metadata(self):
        info = release.metadata(self.root, "push", "refs/tags/v0.1.0")
        self.assertEqual(info, {"version": "0.1.0", "build": "1", "tag": "v0.1.0", "flutter_version": "3.47.2"})

    def test_mismatched_tags_branches_and_shell_text_are_rejected(self):
        for ref in ("refs/tags/v0.1.1", "refs/heads/main", "refs/tags/v0.1.0+1", "refs/tags/v0.1.0;echo bad"):
            with self.subTest(ref=ref), self.assertRaises(ValueError):
                release.metadata(self.root, "push", ref)

    def test_dispatch_and_pull_request_can_validate_without_a_tag(self):
        for event in ("workflow_dispatch", "pull_request"):
            self.assertEqual(release.metadata(self.root, event, "refs/heads/main")["version"], "0.1.0")

    def test_invalid_pubspec_versions_are_rejected(self):
        for source in ("", "version: 1.0.0\n", "version: 1.0.0-beta+1\n", "version: 01.0.0+1\n",
                       "version: 1.0.0+0\n", "version: 1.0.0+1\nversion: 2.0.0+1\n"):
            with self.subTest(source=source), self.assertRaises(ValueError):
                release.app_version(source)

    def test_flutter_version_cannot_inject_workflow_outputs(self):
        (self.root / ".github/flutter-version").write_text("3.47.2\ntag=bad\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            release.metadata(self.root, "push", "refs/tags/v0.1.0")

    def test_artifacts_have_matching_embedded_and_native_versions(self):
        release.validate_artifacts(self.dist, "0.1.0", "1")

    def test_embedded_apk_version_mismatch_is_rejected(self):
        self.pack(apk_version="0.2.0+1")
        with self.assertRaisesRegex(ValueError, "embedded pubspec"):
            release.validate_artifacts(self.dist, "0.1.0", "1")

    def test_embedded_ipa_version_mismatch_is_rejected(self):
        self.pack(ipa_version="0.1.0+2")
        with self.assertRaisesRegex(ValueError, "embedded pubspec"):
            release.validate_artifacts(self.dist, "0.1.0", "1")

    def test_native_ipa_version_and_build_mismatches_are_rejected(self):
        for value in ({"bundle_version": "0.2.0"}, {"bundle_build": "2"}):
            self.pack(**value)
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "IPA bundle"):
                release.validate_artifacts(self.dist, "0.1.0", "1")

    def test_missing_empty_and_corrupt_artifacts_are_rejected(self):
        for content in (None, b"", b"not a ZIP"):
            path = self.dist / release.IPA
            if content is None:
                path.unlink()
            else:
                path.write_bytes(content)
            with self.subTest(content=content), self.assertRaises((ValueError, zipfile.BadZipFile)):
                release.validate_artifacts(self.dist, "0.1.0", "1")

    def test_checksums_include_both_artifacts_and_no_self_entry(self):
        text = (self.dist / release.CHECKSUMS).read_text(encoding="utf-8")
        self.assertEqual(text, "".join(f"{release.digest(self.dist / name)}  {name}\n" for name in release.ARTIFACTS))

    def test_remote_assets_accept_verified_uploads(self):
        release.verify_remote_assets(self.dist, {"assets": self.assets()})

    def test_missing_duplicate_and_extra_remote_assets_are_rejected(self):
        assets = self.assets()
        for data in (assets[:-1], assets + [assets[0]], assets[:-1] + [{**assets[-1], "name": "other"}]):
            with self.subTest(data=data), self.assertRaises(ValueError):
                release.verify_remote_assets(self.dist, {"assets": data})

    def test_wrong_remote_size_state_and_digest_are_rejected(self):
        for replacement in ({"size": 0}, {"state": "new"}, {"digest": "sha256:bad"}):
            assets = self.assets()
            assets[0].update(replacement)
            with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                release.verify_remote_assets(self.dist, {"assets": assets})

    def test_dispatch_never_publishes(self):
        self.env["GITHUB_EVENT_NAME"] = "workflow_dispatch"
        calls, invoke = self.fake_github()
        with self.assertRaisesRegex(ValueError, "only a pushed"):
            self.run_publish(invoke)
        self.assertEqual(calls, [])

    def test_moved_tag_cannot_publish(self):
        calls, invoke = self.fake_github(tag_sha="b" * 40)
        with self.assertRaisesRegex(ValueError, "tested commit"):
            self.run_publish(invoke)
        self.assertFalse(any(payload for _, payload in calls))

    def test_complete_release_uploads_draft_before_publishing_latest(self):
        calls, invoke = self.fake_github()
        self.run_publish(invoke)
        mutations = [(args, payload) for args, payload in calls if payload]
        self.assertTrue(mutations[0][1]["draft"])
        self.assertEqual(mutations[-1][1], {"draft": False, "prerelease": False, "make_latest": "true"})
        upload = next(i for i, (args, _) in enumerate(calls) if args[:2] == ("release", "upload"))
        download = next(i for i, (args, _) in enumerate(calls) if args[:2] == ("release", "download"))
        self.assertLess(upload, download)
        self.assertLess(download, len(calls) - 1)

    def test_release_with_missing_asset_is_left_draft(self):
        calls, invoke = self.fake_github(remote_assets=self.assets()[:-1])
        with self.assertRaises(ValueError):
            self.run_publish(invoke)
        self.assertFalse(any(payload and payload.get("draft") is False for _, payload in calls))

    def test_corrupt_download_is_left_draft_even_without_server_digest(self):
        assets = self.assets()
        for asset in assets:
            asset.pop("digest")
        calls, invoke = self.fake_github(remote_assets=assets, corrupt_download=True)
        with self.assertRaisesRegex(ValueError, "downloaded release checksum"):
            self.run_publish(invoke)
        self.assertFalse(any(payload and payload.get("draft") is False for _, payload in calls))

    def test_public_release_is_never_overwritten(self):
        existing = [{"id": 42, "tag_name": "v0.1.0", "draft": False, "prerelease": False}]
        calls, invoke = self.fake_github(existing=existing)
        with self.assertRaisesRegex(ValueError, "already public"):
            self.run_publish(invoke)
        self.assertFalse(any(args[:2] == ("release", "upload") for args, _ in calls))

    def test_retry_resumes_an_existing_draft(self):
        existing = [{"id": 42, "tag_name": "v0.1.0", "draft": True, "prerelease": False,
                     "target_commitish": self.env["GITHUB_SHA"]}]
        calls, invoke = self.fake_github(existing=existing)
        self.run_publish(invoke)
        self.assertFalse(any(args[1] == "repos/Example/novel/releases" for args, payload in calls if payload))

    def test_older_release_does_not_replace_latest(self):
        existing = [{"id": 43, "tag_name": "v0.2.0", "draft": False, "prerelease": False}]
        calls, invoke = self.fake_github(existing=existing)
        self.run_publish(invoke)
        self.assertEqual(calls[-1][1]["make_latest"], "false")

    def test_gh_uses_argument_array_and_json_stdin(self):
        with patch.object(release.subprocess, "run") as run:
            run.return_value.stdout = "{}"
            release.gh("api", "repos/Example/novel/releases", payload={"body": "$(echo bad)\n; echo bad"})
        args, kwargs = run.call_args
        self.assertEqual(args[0], ["gh", "api", "repos/Example/novel/releases"])
        self.assertNotIn("shell", kwargs)
        self.assertEqual(json.loads(kwargs["input"]), {"body": "$(echo bad)\n; echo bad"})


if __name__ == "__main__":
    unittest.main()
