"""Focused release-input, compiler-argument and ELF regressions; no Flutter build."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest


class ReleaseInputsTest(unittest.TestCase):
    def setUp(self):
        source = Path(__file__).resolve().parents[1]
        scratch = source / "build/packaging-tests"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "source with spaces"
        (self.root / "packaging/arch").mkdir(parents=True)
        for name in ("build_release.sh", "check_source.py", "toolchain.cmake"):
            shutil.copy(source / "packaging/arch" / name,
                        self.root / "packaging/arch" / name)
        (self.root / "assets").mkdir()
        (self.root / "scripts").mkdir()
        shutil.copy(source / "scripts/build_linux_package.sh", self.root / "scripts")
        (self.root / ".gitignore").write_text("/build/\n/rust/target/\n*.private\n")
        (self.root / "rust/src").mkdir(parents=True)
        lock = tomllib.loads((source / "rust/Cargo.lock").read_text())
        cc_version = next(p["version"] for p in lock["package"] if p["name"] == "cc")
        (self.root / "rust/Cargo.toml").write_text(
            '[package]\nname="flag_probe"\nversion="0.1.0"\nedition="2021"\n'
            f'[build-dependencies]\ncc="={cc_version}"\n')
        (self.root / "rust/src/main.rs").write_text("fn main() {}\n")
        (self.root / "rust/probe.c").write_text("int c_value;\n")
        (self.root / "rust/probe.cc").write_text("int cpp_value;\n")
        (self.root / "rust/build.rs").write_text(
            'fn main() { cc::Build::new().file("probe.c").compile("c_probe");'
            'cc::Build::new().cpp(true).file("probe.cc").compile("cpp_probe"); }\n')
        self.run_command("cargo", "generate-lockfile", "--offline",
                         "--manifest-path", "rust/Cargo.toml")
        self.run_command("git", "init", "-q")
        self.run_command("git", "add", ".")
        self.run_command("git", "-c", "user.name=Test", "-c",
                         "user.email=test@example.invalid", "commit", "-qm", "fixture")

    def run_command(self, *args, **kwargs):
        result = subprocess.run(args, cwd=self.root,
                                capture_output=True, text=True, **kwargs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_untracked_and_ignored_assets_are_rejected(self):
        for name in ("assets/untracked.json", "assets/ignored.private", "rust/untracked.private"):
            asset = self.root / name
            asset.write_text("synthetic")
            result = subprocess.run(
                ["python", "packaging/arch/check_source.py", str(self.root)],
                cwd=self.root, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Untracked build inputs", result.stderr)
            self.assertEqual(asset.read_text(), "synthetic")
            asset.unlink()

    def test_output_and_revision_guards_preserve_existing_files(self):
        existing = Path(self.temp.name) / "existing output"
        existing.mkdir()
        sentinel = existing / "keep"
        sentinel.write_text("original")
        for output, revision in [(existing, "HEAD"), (self.root / "build/out", "HEAD"),
                                 (existing, "not-a-revision")]:
            result = subprocess.run(["bash", "scripts/build_linux_package.sh",
                                     str(output), revision], cwd=self.root,
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(sentinel.read_text(), "original")
        self.assertFalse((self.root / "build/out").exists())

        target = Path(self.temp.name) / "unexpected target"
        link = Path(self.temp.name) / "existing link"
        link.symlink_to(target)
        tools = Path(self.temp.name) / "preflight tools"
        tools.mkdir()
        (tools / "patchelf").write_text("#!/bin/sh\nexit 99\n")
        (tools / "patchelf").chmod(0o755)
        env = dict(os.environ, FLUTTER_ROOT=self.temp.name, PUB_CACHE=self.temp.name,
                   PATH=str(tools) + os.pathsep + os.environ["PATH"])
        for suffix in ("", "/", "///"):
            result = subprocess.run(["bash", "scripts/build_linux_package.sh",
                                     str(link) + suffix, "HEAD"], cwd=self.root,
                                    env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(link.is_symlink())
            self.assertFalse(target.exists(), result.stdout + result.stderr)
            self.assertIn("Output already exists", result.stderr)

    def test_spaced_paths_reach_real_compilers_as_single_arguments(self):
        tools = Path(self.temp.name) / "tool bin"
        tools.mkdir()
        flutter = tools / "flutter"
        flutter.write_text('''#!/usr/bin/env python3
import json, os, pathlib, subprocess
subprocess.run(["cargo", "check", "--offline", "--quiet", "--manifest-path", "rust/Cargo.toml"], check=True)
out = pathlib.Path("build/linux/x64/release/bundle")
out.mkdir(parents=True)
(out / "flags.json").write_text(json.dumps({k: os.environ[k] for k in ("CARGO_ENCODED_RUSTFLAGS", "CFLAGS", "CXXFLAGS")}))
''')
        flutter.chmod(0o755)
        env = os.environ.copy()
        env.setdefault("CARGO_HOME", str(Path.home() / ".cargo"))
        env.update(PATH=str(tools) + os.pathsep + env["PATH"],
                   HOME=str(Path(self.temp.name) / "home with spaces"),
                   FLUTTER_ROOT=str(tools), PUB_CACHE=str(tools),
                   CARGO_ENCODED_RUSTFLAGS="--cfg\x1fexisting_encoded_flag",
                   RUSTFLAGS="--invalid-ignored-flag")
        self.run_command("bash", "packaging/arch/build_release.sh", env=env)
        bundle = self.root / "build/linux/x64/release/bundle"
        flags = json.loads((bundle / "flags.json").read_text())
        self.assertEqual(flags["CARGO_ENCODED_RUSTFLAGS"].split("\x1f")[:2],
                         ["--cfg", "existing_encoded_flag"])
        self.assertIn(f"--remap-path-prefix={self.root}=/usr/src/fqapp",
                      flags["CARGO_ENCODED_RUSTFLAGS"].split("\x1f"))
        self.assertEqual((bundle / "source-commit.txt").read_text().strip(),
                         self.run_command("git", "rev-parse", "HEAD").stdout.strip())
        # An archive has no .git; its revision is supplied by the export caller.
        shutil.rmtree(self.root / ".git")
        shutil.rmtree(bundle)
        env["FQAPP_SOURCE_REVISION"] = "a" * 40
        self.run_command("bash", "packaging/arch/build_release.sh", env=env)
        self.assertEqual((bundle / "source-commit.txt").read_text().strip(), "a" * 40)
        self.run_command("git", "init", "-q")
        self.run_command("git", "add", ".")
        self.run_command("git", "-c", "user.name=Test", "-c",
                         "user.email=test@example.invalid", "commit", "-qm", "fixture")
        (bundle / "generated.cmake").write_text("# generated build output\n")
        self.run_command("python", "packaging/arch/check_source.py", str(self.root))


class BundleClosureTest(unittest.TestCase):
    def setUp(self):
        source = Path(__file__).resolve().parents[1]
        self.checker = source / "packaging/arch/prepare_bundle.py"
        scratch = source / "build/packaging-tests"
        scratch.mkdir(parents=True, exist_ok=True)
        temp = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(temp.cleanup)
        self.bundle = Path(temp.name) / "bundle with spaces"
        self.lib = self.bundle / "lib"
        self.lib.mkdir(parents=True)
        assets = self.bundle / "data/flutter_assets"
        assets.mkdir(parents=True)
        (assets / "AssetManifest.bin").touch()
        (assets.parent / "icudtl.dat").touch()
        self.compile("lib/libclosure_leaf.so", "int leaf(void) { return 42; }",
                     "-shared", "-fPIC", "-nostdlib")
        self.compile("lib/libfqapi_core.so", "int core(void) { return 42; }",
                     "-shared", "-fPIC", "-nostdlib")
        shutil.copy(self.lib / "libfqapi_core.so", self.lib / "libapp.so")
        self.compile("lib/libflutter_linux_gtk.so",
                     "int leaf(void); int flutter(void) { return leaf(); }",
                     "-shared", "-fPIC", "-nostdlib", "-Llib", "-lclosure_leaf",
                     "-Wl,-rpath,$ORIGIN")
        self.compile("fqapp", "int flutter(void); int main(void) { return flutter(); }",
                     "-Llib", "-Wl,--no-as-needed", "-lgcc_s", "-lflutter_linux_gtk",
                     "-Wl,-rpath-link,lib")
        for library in self.lib.iterdir():
            library.chmod(0o644)

    def compile(self, output, code, *flags):
        subprocess.run(["cc", "-o", output, "-x", "c", "-", *flags],
                       input=code, text=True, cwd=self.bundle, check=True)

    def check_bundle(self, *python_flags, env=None):
        return subprocess.run([sys.executable, *python_flags, self.checker, self.bundle],
                              env=env, capture_output=True, text=True)

    def test_resolves_0644_libraries_using_normalized_runpaths_in_place(self):
        flutter = self.lib / "libflutter_linux_gtk.so"
        subprocess.run(["patchelf", "--set-rpath", "/nonexistent", flutter], check=True)
        result = self.check_bundle()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"libflutter_linux_gtk.so => {flutter} (", result.stdout)
        self.assertIn(f"libclosure_leaf.so => {self.lib / 'libclosure_leaf.so'} (", result.stdout)
        self.assertEqual(flutter.stat().st_mode & 0o777, 0o644)

    def test_missing_transitive_dependency_reports_runner_and_library(self):
        elsewhere = self.bundle.parent
        leaf = self.lib / "libclosure_leaf.so"
        leaf.rename(elsewhere / leaf.name)
        result = self.check_bundle(env=dict(os.environ, LD_LIBRARY_PATH=str(elsewhere)))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(str(self.bundle / "fqapp"), result.stderr)
        self.assertIn(leaf.name, result.stderr)

    def test_rejects_successful_probe_without_dependency_resolutions(self):
        # Replace only the external loader probe. Keep readelf and patchelf real.
        simulate_probe = """\
import pathlib, runpy, subprocess, sys
from unittest.mock import patch

output, script = sys.argv[1:3]
sys.argv = sys.argv[2:]
run = subprocess.run

def probe(args, **kwargs):
    if pathlib.Path(args[0]).name == "ldd" or args[1] == "--list":
        return subprocess.CompletedProcess(args, 0, output, "")
    return run(args, **kwargs)

with patch("subprocess.run", probe):
    runpy.run_path(script, run_name="__main__")
"""
        for output in ("", "linux-vdso.so.1 (0x1234)\n",
                       "/lib64/ld-linux-x86-64.so.2 (0x1234)\n"):
            with self.subTest(output=output):
                result = self.check_bundle("-c", simulate_probe, output)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(str(self.bundle / "fqapp"), result.stderr)
                self.assertIn("ELF closure", result.stderr)

    def test_reports_library_without_dt_needed_as_statically_linked(self):
        self.compile("static-probe", "void _start(void) {}", "-static", "-nostdlib")
        result = self.check_bundle()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(result.stdout, r"lib/libapp\.so\n[^\n]*RUNPATH[^\n]*\n"
                                        r"statically linked \(no DT_NEEDED\)")
        self.assertIn("static-probe\nstatically linked (no DT_NEEDED)", result.stdout)

    def test_accepts_absolute_path_loader_resolution(self):
        self.compile("lib/libclosure_loader.so", "int probe(void) { return 0; }",
                     "-shared", "-fPIC", "-nostdlib", "-Wl,--no-as-needed",
                     "-l:ld-linux-x86-64.so.2")
        (self.lib / "libclosure_loader.so").chmod(0o644)
        result = self.check_bundle()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        section = result.stdout.split("lib/libclosure_loader.so\n", 1)[1].split("\n\n", 1)[0]
        self.assertRegex(section, r"(?m)^\s*/[^\n]+/ld-linux-x86-64\.so\.2 \(0x")


if __name__ == "__main__":
    unittest.main()
