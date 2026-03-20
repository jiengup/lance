import tempfile
import unittest
from pathlib import Path

from ci.set_dev_build_version import (
    build_dev_version,
    copy_source_tree,
    normalize_base_version,
    read_root_version,
    update_java_version,
    update_python_version,
)


class SetDevBuildVersionTest(unittest.TestCase):
    def test_normalize_base_version(self) -> None:
        self.assertEqual(normalize_base_version("4.1.0-beta.0"), "4.1.0")
        self.assertEqual(normalize_base_version("4.1.0-rc.2"), "4.1.0")
        self.assertEqual(normalize_base_version("4.1.0"), "4.1.0")

    def test_build_dev_version(self) -> None:
        self.assertEqual(build_dev_version("4.1.0", "42", "abc1234", "python"), "4.1.0.dev42+gabc1234")
        self.assertEqual(build_dev_version("4.1.0", "42", "abc1234", "java"), "4.1.0-dev.42.gabc1234")

    def test_copy_and_update_versions(self) -> None:
        with tempfile.TemporaryDirectory() as source_dir_name, tempfile.TemporaryDirectory() as build_parent_name:
            source_dir = Path(source_dir_name)
            build_root = Path(build_parent_name) / "build"
            build_root.mkdir()

            (source_dir / "python").mkdir(parents=True)
            (source_dir / "java").mkdir(parents=True)
            (source_dir / ".git").mkdir()
            (source_dir / "target").mkdir()

            (source_dir / "Cargo.toml").write_text(
                """
[workspace.package]
version = "4.1.0-beta.0"
""".strip()
            )
            (source_dir / "python" / "Cargo.toml").write_text(
                """
[package]
name = "pylance"
version = "4.1.0-beta.0"
""".strip()
            )
            (source_dir / "java" / "pom.xml").write_text(
                """
<project>
  <artifactId>lance-core</artifactId>
  <version>4.1.0-beta.0</version>
  <dependencies>
    <dependency>
      <version>1.0.0</version>
    </dependency>
  </dependencies>
</project>
""".strip()
            )
            (source_dir / "target" / "ignored.txt").write_text("ignored")

            self.assertEqual(read_root_version(source_dir), "4.1.0-beta.0")

            copy_source_tree(source_dir, build_root)
            self.assertFalse((build_root / ".git").exists())
            self.assertFalse((build_root / "target").exists())

            update_python_version(build_root, "4.1.0.dev42+gabc1234")
            update_java_version(build_root, "4.1.0-dev.42.gabc1234")

            python_cargo = (build_root / "python" / "Cargo.toml").read_text()
            java_pom = (build_root / "java" / "pom.xml").read_text()

            self.assertIn('version = "4.1.0.dev42+gabc1234"', python_cargo)
            self.assertIn("<version>4.1.0-dev.42.gabc1234</version>", java_pom)
            self.assertIn("<version>1.0.0</version>", java_pom)


if __name__ == "__main__":
    unittest.main()
