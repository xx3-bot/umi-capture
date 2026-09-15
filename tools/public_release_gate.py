#!/usr/bin/env python3
"""Audit an exported public source snapshot, before or after Git initialization."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import re
import stat
import subprocess
from dataclasses import dataclass
from pathlib import Path, PurePosixPath


MANIFEST = "PUBLIC_SOURCE_MANIFEST.json"
MAX_PUBLIC_FILE_BYTES = 5 * 1024 * 1024
FORBIDDEN_SUFFIXES = {
    ".ipa", ".zip", ".mov", ".mp4", ".raw", ".pem", ".p12",
    ".mobileprovision", ".xcarchive", ".xcresult",
}
BINARY_SUFFIXES = {
    ".jpg", ".jpeg", ".heic", ".gif", ".webp", ".pdf", ".bin", ".exe",
    ".a", ".o", ".so", ".dylib", ".pyc", ".dmg", ".app", ".framework",
    ".xcframework", ".bundle", ".tar", ".gz", ".7z",
}
CONTENT_EXEMPTIONS = {
    "tools/public_release_gate.py", "tools/test_public_release_gate.py",
}
# These six images were visually reviewed for this source snapshot. Changes
# require another visual review and an explicit update here, not just a manifest.
APPROVED_PNG_HASHES = {
    "apps/ios/UMICapture/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png":
        "7439c00e5f5e6b15a8a642ae3f8010c74749b16e0f28d4c57869dd22b5d2c4dc",
    "docs/public/assets/ios-capture-home-en.png":
        "4ee92c27c0a091fe88402416637e076bca7febe3ecf2cbb4c1991b2c91412393",
    "docs/public/assets/ios-quick-start-en.png":
        "2cf08ee7475cf2886aefaa54ebd382a9358c29645e6866c5b2a475ceb90d334d",
    "docs/public/assets/ios-role-setup-en.png":
        "108d467b11c53ca938d5f7673b4d1984caba09a8c23bd1068848d32460e85afd",
    "docs/public/assets/ios-tutorial-steps-4-6-en.png":
        "85de15b2689f16418efc5aba156608e9d6d6ce0da234b7a937c9110aff74407c",
    "docs/public/assets/ios-tutorial-steps-6-7-en.png":
        "f7cbe19b7ef34aa18be8c43858f41437c2b41a45e194255c2eef0ccaa68b24db",
}
SAFE_TEST_UUIDS = {
    f"{digit * 8}-{digit * 4}-4{digit * 3}-8{digit * 3}-{digit * 12}"
    for digit in "123"
}
EXAMPLE_NETWORKS = tuple(ipaddress.IPv4Network(network) for network in (
    "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24",
))
PRIVATE_PREFIXES = (
    "private-artifacts/", "screenshots/private/", "docs/audits/",
    "docs/verification/", "apps/macos/BuildAssets/",
)
TEXT_PATTERNS = {
    "personal path": re.compile(r"/Users/[^/\s<>\"'{}$]+/"),
    "signing team": re.compile(r'\bDEVELOPMENT_TEAM\s*=\s*["\']?[A-Za-z0-9]{10}\b'),
    "private key": re.compile(r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----"),
}
EMAIL_PATTERN = re.compile(r"(?<![\w.+%-])[\w.+%-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})(?![\w.-])")
IPV4_PATTERN = re.compile(r"(?<![\w.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![\w.])")
UUID_PATTERN = re.compile(r"(?i)(?<![0-9a-f])[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}(?![0-9a-f])")


@dataclass(frozen=True)
class Finding:
    rule: str
    path: str
    detail: str


def _safe_name(name: str) -> bool:
    path = PurePosixPath(name)
    return bool(name) and path.as_posix() == name and not path.is_absolute() and not (
        {"..", ".git"} & set(path.parts)
    )


def _raise_walk_error(error: OSError) -> None:
    raise error


def _tree_names(root: Path) -> list[str]:
    if (root / ".git").exists() or (root / ".git").is_symlink():
        output = subprocess.check_output(
            ["git", "-C", str(root), "ls-files", "-z"], stderr=subprocess.PIPE,
        )
        return sorted(set(os.fsdecode(name) for name in output.split(b"\0") if name))
    names = []
    for directory, subdirectories, files in os.walk(
        root, followlinks=False, onerror=_raise_walk_error,
    ):
        for name in files + subdirectories:
            path = Path(directory) / name
            if name in files or path.is_symlink():
                names.append(path.relative_to(root).as_posix())
    return sorted(names)


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def _manifest_findings(names: set[str], contents: dict[str, bytes], hashes: dict[str, str]) -> list[Finding]:
    if MANIFEST not in contents:
        return [Finding("manifest missing", MANIFEST, "A readable regular source manifest is required.")]
    try:
        payload = json.loads(contents[MANIFEST], object_pairs_hook=_unique_object)
        if not isinstance(payload, dict) or payload.get("schema_version") != 1:
            raise ValueError("unsupported manifest schema")
        files = payload.get("files")
        if not isinstance(files, dict) or any(
            not _safe_name(name) or not isinstance(digest, str)
            or re.fullmatch(r"[0-9a-f]{64}", digest) is None
            for name, digest in files.items()
        ):
            raise ValueError("invalid file/hash mapping")
    except (ValueError, UnicodeError):
        return [Finding("manifest invalid", MANIFEST, "Invalid schema, path, SHA-256, or duplicate key.")]
    findings = []
    expected = names - {MANIFEST}
    for name in sorted(expected - files.keys()):
        findings.append(Finding("manifest missing entry", name, "Inspected file has no manifest entry."))
    for name in sorted(files.keys() - expected):
        findings.append(Finding("manifest unexpected entry", name, "Manifest entry is not an inspected file."))
    for name in sorted(expected & files.keys() & hashes.keys()):
        if files[name] != hashes[name]:
            findings.append(Finding("manifest hash mismatch", name, "SHA-256 does not match the inspected bytes."))
    return findings


def _text_findings(name: str, text: str, *, test_content: bool = False) -> list[Finding]:
    rules = {rule for rule, pattern in TEXT_PATTERNS.items() if pattern.search(text)}
    if "@" in text and any(
        match.group(1).lower() not in {"example.com", "example.org", "example.net"}
        for match in EMAIL_PATTERN.finditer(text)
    ):
        rules.add("personal email")
    for match in IPV4_PATTERN.finditer(text):
        try:
            address = ipaddress.IPv4Address(match.group())
        except ipaddress.AddressValueError:
            continue
        if str(address) not in {"127.0.0.1", "0.0.0.0"} and not any(
            address in network for network in EXAMPLE_NETWORKS
        ):
            rules.add("IP address")
    for match in UUID_PATTERN.finditer(text):
        if not test_content or match.group() not in SAFE_TEST_UUIDS:
            rules.add("UUID")
    return [Finding(rule, name, "Forbidden identifier or credential pattern.") for rule in sorted(rules)]


def audit_public_tree(root: Path) -> list[Finding]:
    """Return findings without following symlinks or printing matched secrets.

    A Git checkout is audited by tracked paths; a pre-Git export is audited in
    full. The manifest must cover exactly that set, excluding only itself.
    Content exemptions still receive path, file-type, size, and hash checks.
    """
    root = Path(root).resolve()
    if not root.is_dir():
        return [Finding("tree unreadable", ".", "Snapshot root must be a directory.")]
    try:
        names = _tree_names(root)
    except (OSError, subprocess.CalledProcessError):
        return [Finding("tree unreadable", ".", "Could not enumerate the snapshot files.")]
    findings = []
    contents = {}
    hashes = {}
    for name in names:
        if not _safe_name(name):
            findings.append(Finding("unsafe path", name, "Path is not a safe relative file path."))
            continue
        path = root / name
        if any(part.is_symlink() for part in (path, *path.parents) if part != root and root in part.parents):
            findings.append(Finding("symlink", name, "Symbolic links are not public source files."))
            continue
        try:
            info = path.stat()
            if not stat.S_ISREG(info.st_mode):
                findings.append(Finding("binary artifact", name, "Only regular source files are allowed."))
                continue
            if info.st_size > MAX_PUBLIC_FILE_BYTES:
                findings.append(Finding("oversize file", name, "File exceeds the 5 MiB public limit."))
                continue
            content = path.read_bytes()
        except FileNotFoundError:
            findings.append(Finding("missing file", name, "Tracked file is absent from the checkout."))
            continue
        except OSError:
            findings.append(Finding("unreadable file", name, "Could not read inspected file."))
            continue
        contents[name] = content
        hashes[name] = hashlib.sha256(content).hexdigest()
    # Verify exact set and bytes before scanning identifiers in paths or text.
    findings.extend(_manifest_findings(set(names), contents, hashes))
    for name in names:
        findings.extend(_text_findings(name, name))
        if name.startswith(PRIVATE_PREFIXES) or PurePosixPath(name).name == ".env":
            findings.append(Finding("private asset", name, "Private assets are outside the public boundary."))
        for part in PurePosixPath(name).parts:
            suffix = PurePosixPath(part).suffix.lower()
            if suffix in BINARY_SUFFIXES:
                findings.append(Finding("binary artifact", name, "Binary, media, or application artifact path."))
            if suffix in FORBIDDEN_SUFFIXES:
                rule = {
                    ".zip": "capture archive", ".mov": "real video", ".mp4": "real video",
                    ".mobileprovision": "provisioning profile",
                }.get(suffix, "forbidden artifact")
                findings.append(Finding(rule, name, "Forbidden public artifact suffix."))
        if name not in contents:
            continue
        content = contents[name]
        if name in APPROVED_PNG_HASHES and hashes[name] == APPROVED_PNG_HASHES[name]:
            continue
        try:
            text = content.decode("utf-8")
            if PurePosixPath(name).suffix.lower() == ".png" or any(
                ord(character) < 32 and character not in "\t\r\n" for character in text
            ):
                raise ValueError("binary data")
        except (UnicodeError, ValueError):
            findings.append(Finding("binary artifact", name, "Unapproved binary or image content."))
            continue
        if name not in CONTENT_EXEMPTIONS:
            basename = PurePosixPath(name).name
            test_content = (basename.startswith("test_") and basename.endswith(".py")) or basename.endswith("Tests.swift")
            findings.extend(_text_findings(name, text, test_content=test_content))
    return sorted(set(findings), key=lambda finding: (finding.path, finding.rule, finding.detail))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True, help="Exported public snapshot or tracked clone")
    args = parser.parse_args()
    findings = audit_public_tree(args.root)
    for finding in findings:
        print(f"{finding.path}: {finding.rule}: {finding.detail}")
    print(f"Public release gate: {len(findings)} finding(s).")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
