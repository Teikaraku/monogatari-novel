"""Validate and publish the two official Monogatari Novel release artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import zipfile


APK = "Monogatari-Novel-Android-universal.apk"
IPA = "Monogatari-Novel-iOS-unsigned.ipa"
CHECKSUMS = "SHA256SUMS.txt"
ARTIFACTS = (APK, IPA)
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\+([1-9][0-9]*)")


def app_version(source: str) -> tuple[str, str]:
    lines = re.findall(r"^version:\s*([^\r\n#]+)", source, re.MULTILINE)
    if len(lines) != 1:
        raise ValueError("pubspec must contain exactly one top-level version")
    value = lines[0].strip().strip("\"'")
    if not VERSION.fullmatch(value):
        raise ValueError("official releases require major.minor.patch+build in pubspec")
    return tuple(value.split("+"))


def metadata(root: Path, event: str, ref: str) -> dict[str, str]:
    version, build = app_version((root / "pubspec.yaml").read_text(encoding="utf-8"))
    tag = f"v{version}"
    if event == "push" and ref != f"refs/tags/{tag}":
        raise ValueError("pushed tag must exactly match the pubspec version name")
    if event not in {"push", "workflow_dispatch", "pull_request"}:
        raise ValueError("unsupported workflow event")
    flutter = (root / ".github/flutter-version").read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", flutter):
        raise ValueError("invalid Flutter version")
    return {"version": version, "build": build, "tag": tag, "flutter_version": flutter}


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def validate_artifacts(dist: Path, version: str, build: str) -> None:
    for name in ARTIFACTS:
        path = dist / name
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"missing or empty release artifact: {name}")
        with zipfile.ZipFile(path) as archive:
            if archive.testzip() is not None:
                raise ValueError(f"corrupt archive: {name}")
            if name == APK:
                if "AndroidManifest.xml" not in archive.namelist():
                    raise ValueError("APK has no AndroidManifest.xml")
                pubspec = "assets/flutter_assets/pubspec.yaml"
            else:
                prefix = "Payload/Runner.app/"
                info = plistlib.loads(archive.read(prefix + "Info.plist"))
                if info.get("CFBundleShortVersionString") != version or info.get("CFBundleVersion") != build:
                    raise ValueError("IPA bundle version does not match pubspec/tag")
                pubspec = prefix + "Frameworks/App.framework/flutter_assets/pubspec.yaml"
            embedded = app_version(archive.read(pubspec).decode("utf-8"))
            if embedded != (version, build):
                raise ValueError(f"embedded pubspec version does not match tag: {name}")


def write_checksums(dist: Path) -> None:
    text = "".join(f"{digest(dist / name)}  {name}\n" for name in ARTIFACTS)
    (dist / CHECKSUMS).write_text(text, encoding="utf-8", newline="\n")


def verify_remote_assets(dist: Path, release: dict) -> None:
    assets = release.get("assets", [])
    expected = {*ARTIFACTS, CHECKSUMS}
    names = [asset["name"] for asset in assets]
    if len(names) != len(expected) or set(names) != expected:
        raise ValueError("release must contain exactly the APK, IPA and SHA256SUMS.txt")
    for asset in assets:
        path = dist / asset["name"]
        if asset.get("state") != "uploaded" or asset.get("size") != path.stat().st_size:
            raise ValueError(f"release asset upload is incomplete: {asset['name']}")
        remote_digest = asset.get("digest")
        if remote_digest is not None and remote_digest != f"sha256:{digest(path)}":
            raise ValueError(f"release asset checksum differs: {asset['name']}")


def gh(*args: str, payload: dict | None = None) -> str:
    """Use argv and JSON stdin, never interpolate tag/body/secrets into a shell."""
    result = subprocess.run(
        ["gh", *args],
        input=None if payload is None else json.dumps(payload),
        text=True,
        encoding="utf-8",
        capture_output=True,
        check=True,
    )
    return result.stdout


def api(repo: str, route: str, payload: dict | None = None):
    args = ["api", f"repos/{repo}/{route}"]
    if payload is not None:
        args += ["--method", "POST", "--input", "-"]
    return json.loads(gh(*args, payload=payload))


def publish(root: Path, dist: Path, environ: dict[str, str]) -> None:
    info = metadata(root, environ.get("GITHUB_EVENT_NAME", ""), environ.get("GITHUB_REF", ""))
    if environ.get("GITHUB_EVENT_NAME") != "push":
        raise ValueError("only a pushed version tag may publish a release")
    repo = environ.get("GITHUB_REPOSITORY", "")
    sha = environ.get("GITHUB_SHA", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("invalid GitHub repository")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("invalid workflow commit SHA")
    validate_artifacts(dist, info["version"], info["build"])
    write_checksums(dist)
    if api(repo, f"commits/{info['tag']}")["sha"] != sha:
        raise ValueError("release tag does not point to the tested commit")

    pages = json.loads(gh("api", f"repos/{repo}/releases?per_page=100", "--paginate", "--slurp"))
    matches = [release for page in pages for release in page if release["tag_name"] == info["tag"]]
    if len(matches) > 1:
        raise ValueError("multiple releases use this tag")
    if matches:
        release = matches[0]
        if not release["draft"]:
            raise ValueError("this version is already public; release assets are not overwritten")
        if api(repo, f"commits/{release['target_commitish']}")["sha"] != sha:
            raise ValueError("existing draft belongs to a different commit")
    else:
        release = api(repo, "releases", {
            "tag_name": info["tag"],
            "target_commitish": sha,
            "name": f"Monogatari Novel {info['version']}",
            "body": "Android: signed universal APK.\n\niOS: unsigned IPA; sign before installation.\n\nVerify downloads with SHA256SUMS.txt.",
            "draft": True,
            "prerelease": False,
        })
    gh("release", "upload", info["tag"], *(str(dist / name) for name in (*ARTIFACTS, CHECKSUMS)),
       "--repo", repo, "--clobber")
    uploaded = api(repo, f"releases/{release['id']}")
    verify_remote_assets(dist, uploaded)
    # Download and hash as well: GitHub may omit the asset digest field.
    with tempfile.TemporaryDirectory(prefix="novel-release-") as directory:
        gh("release", "download", info["tag"], "--repo", repo, "--dir", directory)
        for name in (*ARTIFACTS, CHECKSUMS):
            if digest(Path(directory) / name) != digest(dist / name):
                raise ValueError(f"downloaded release checksum differs: {name}")

    current = tuple(int(part) for part in info["version"].split("."))
    stable = [r for page in pages for r in page if not r["draft"] and not r["prerelease"]]
    newer_exists = any(
        re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", r["tag_name"])
        and tuple(map(int, r["tag_name"][1:].split("."))) > current
        for r in stable
    )
    gh("api", f"repos/{repo}/releases/{release['id']}", "--method", "PATCH", "--input", "-",
       payload={"draft": False, "prerelease": False, "make_latest": "false" if newer_exists else "true"})
    print(f"Published {repo} {info['tag']} with verified APK, IPA and checksums.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("metadata", "checksums", "publish"))
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--dist", type=Path, default=Path("dist"))
    args = parser.parse_args()
    info = metadata(args.root, os.environ.get("GITHUB_EVENT_NAME", "workflow_dispatch"),
                    os.environ.get("GITHUB_REF", ""))
    if args.command == "metadata":
        output = "".join(f"{key}={value}\n" for key, value in info.items())
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8", newline="\n") as stream:
                stream.write(output)
        print(output, end="")
    elif args.command == "checksums":
        validate_artifacts(args.dist, info["version"], info["build"])
        write_checksums(args.dist)
    else:
        publish(args.root, args.dist, dict(os.environ))


if __name__ == "__main__":
    main()
