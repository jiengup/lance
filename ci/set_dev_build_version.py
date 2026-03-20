#!/usr/bin/env python3
"""Create a temporary source tree with dev build versions applied."""

from __future__ import annotations

import argparse
import re
import shutil
from pathlib import Path


PYTHON_VERSION_RE = re.compile(r'^version = "([^"]+)"$', re.MULTILINE)
JAVA_VERSION_RE = re.compile(r"(<version>)([^<]+)(</version>)", re.MULTILINE)


def normalize_base_version(version: str) -> str:
    return version.split("-", 1)[0]


def build_dev_version(base_version: str, run_number: str, sha: str, language: str) -> str:
    if language == "python":
        return f"{base_version}.dev{run_number}+g{sha}"
    if language == "java":
        return f"{base_version}-dev.{run_number}.g{sha}"
    raise ValueError(f"Unsupported language: {language}")


def copy_source_tree(source_root: Path, build_root: Path) -> None:
    ignore = shutil.ignore_patterns(
        ".git",
        "target",
        "test_data",
        "__pycache__",
        ".pytest_cache",
    )
    shutil.copytree(source_root, build_root, ignore=ignore, dirs_exist_ok=True)


def read_root_version(source_root: Path) -> str:
    cargo_toml = (source_root / "Cargo.toml").read_text()
    match = PYTHON_VERSION_RE.search(cargo_toml)
    if match is None:
        raise ValueError("Could not find workspace version in Cargo.toml")
    return match.group(1)


def update_python_version(build_root: Path, version: str) -> None:
    cargo_toml = build_root / "python" / "Cargo.toml"
    content = cargo_toml.read_text()
    match = PYTHON_VERSION_RE.search(content)
    if match is None:
        raise ValueError("Could not find python package version")
    cargo_toml.write_text(PYTHON_VERSION_RE.sub(f'version = "{version}"', content, count=1))


def update_java_version(build_root: Path, version: str) -> None:
    pom_xml = build_root / "java" / "pom.xml"
    content = pom_xml.read_text()
    match = JAVA_VERSION_RE.search(content)
    if match is None:
        raise ValueError("Could not find java package version")
    pom_xml.write_text(
        JAVA_VERSION_RE.sub(lambda match: f"{match.group(1)}{version}{match.group(3)}", content, count=1)
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Prepare a dev build source tree")
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--build-root", required=True, type=Path)
    parser.add_argument("--language", required=True, choices=["python", "java"])
    parser.add_argument("--run-number", required=True)
    parser.add_argument("--sha", required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    source_root = args.source_root.resolve()
    build_root = args.build_root.resolve()

    current_version = read_root_version(source_root)
    base_version = normalize_base_version(current_version)
    dev_version = build_dev_version(base_version, args.run_number, args.sha, args.language)

    copy_source_tree(source_root, build_root)
    if args.language == "python":
        update_python_version(build_root, dev_version)
    else:
        update_java_version(build_root, dev_version)

    print(dev_version)


if __name__ == "__main__":
    main()
