#!/usr/bin/env python3
"""Exercise setup in disposable homes; never install packages or remote skills."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SetupTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dotfiles test ")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.home = self.base / "home"
        self.home.mkdir()
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.calls = self.base / "calls"
        self.env = dict(os.environ, HOME=str(self.home),
                        XDG_CONFIG_HOME=str(self.home / ".config"),
                        PATH=f"{self.bin}:/usr/bin:/bin", CALLS=str(self.calls),
                        TEST_PLATFORM="Linux", GIT_CONFIG_NOSYSTEM="1")
        for name in ("uname", "brew", "omarchy", "npx"):
            executable = self.bin / name
            executable.write_text(
                "#!/bin/bash\n"
                'name="${0##*/}"\n'
                'if [ "$name" = uname ]; then echo "$TEST_PLATFORM"; exit; fi\n'
                'printf "%s" "$name" >> "$CALLS"\n'
                'printf " <%s>" "$@" >> "$CALLS"\n'
                'printf "\\n" >> "$CALLS"\n'
                'if [ "$name" = "${FAIL_TOOL:-}" ]; then exit 1; fi\n'
            )
            executable.chmod(0o755)

    def setup(self, *args, ok=True, entry=None):
        result = subprocess.run(["/bin/bash", str(entry or ROOT / "script/setup"), *args],
                                cwd=self.base, env=self.env, capture_output=True, text=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def test_links_backups_and_rerun(self):
        (self.home / ".gitconfig").write_text("# original\n")
        (self.home / ".vimrc").symlink_to("missing-target")
        nvim = self.home / ".config/nvim"
        nvim.mkdir(parents=True)
        (nvim / "init.lua").write_text("-- original editor\n")
        extensions = self.home / ".pi/agent/extensions"
        extensions.mkdir(parents=True)
        (extensions / "local.ts").write_text("// original extension\n")
        (self.home / ".claude").mkdir()
        credentials = self.home / ".claude/credentials.json"
        credentials.write_text("preserve me\n")
        self.setup("--skip-skills")

        for relative in (".gitconfig", ".zsh/config", ".config/ghostty/config",
                         ".config/herdr/config.toml", ".config/ripgrep/config",
                         ".pi/agent/AGENTS.md", ".config/nvim", ".pi/agent/extensions"):
            self.assertEqual((self.home / relative).readlink(), ROOT / "home" / relative)
        self.assertFalse((self.home / ".Brewfile").exists())
        self.assertFalse((self.home / ".tool-versions").exists())
        self.assertEqual((self.home / ".local/bin/wta").readlink(), ROOT / "home/.bin/wta")
        self.assertEqual(credentials.read_text(), "preserve me\n")
        backups = list(self.home.glob(".dotfiles-backup.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / ".gitconfig").read_text(), "# original\n")
        self.assertEqual((backups[0] / ".vimrc").readlink(), Path("missing-target"))
        self.assertEqual((backups[0] / ".config/nvim/init.lua").read_text(), "-- original editor\n")
        self.assertTrue((backups[0] / ".pi/agent/extensions/local.ts").is_file())
        self.assertNotIn("Linked", self.setup("--skip-skills").stdout)
        self.assertEqual(list(self.home.glob(".dotfiles-backup.*")), backups)
        self.assertFalse(self.calls.exists())

    def test_platform_packages_and_skills(self):
        for platform, signing_program in (
            ("Linux", "/opt/1Password/op-ssh-sign"),
            ("Darwin", "/Applications/1Password.app/Contents/MacOS/op-ssh-sign"),
        ):
            with self.subTest(platform=platform):
                self.env["TEST_PLATFORM"] = platform
                self.calls.unlink(missing_ok=True)
                self.setup("--packages")
                calls = self.calls.read_text().splitlines()
                if platform == "Linux":
                    self.assertTrue(calls[0].startswith("omarchy <pkg> <add>"))
                    self.assertIn("<github-cli>", calls[0])
                    self.assertIn("<zsh>", calls[0])
                    self.assertIn("<ghostty>", calls[0])
                    self.assertTrue(calls[1].startswith("omarchy <pkg> <aur> <add>"))
                else:
                    self.assertTrue(calls[0].startswith("brew <bundle> <check>"))
                    self.assertTrue((self.home / ".Brewfile").is_symlink())
                    self.assertTrue((self.home / ".tool-versions").is_symlink())
                skills = [line for line in calls if line.startswith("npx ")]
                sources = [line for line in (ROOT / "skills/manifest.txt").read_text().splitlines()
                           if line.strip() and not line.lstrip().startswith("#")]
                self.assertEqual(len(skills), len(sources) + 1)
                self.assertTrue(all("<--yes> <skills@latest> <add>" in line for line in skills))
                self.assertIn(f"<{ROOT / 'skills/custom'}>", skills[-1])
                actual = subprocess.check_output(
                    ["git", "config", "--includes", "--global", "gpg.ssh.program"],
                    env=self.env, text=True)
                self.assertEqual(actual.strip(), signing_program)

    def test_failed_package_install_stops_before_linking(self):
        self.env["FAIL_TOOL"] = "omarchy"
        self.setup("--packages", ok=False)
        self.assertEqual(list(self.home.iterdir()), [])

    def test_missing_npx_can_be_skipped(self):
        (self.bin / "npx").unlink()
        self.assertIn("Node.js/npm", self.setup(ok=False).stderr)
        self.assertEqual(list(self.home.iterdir()), [])
        self.setup("--skip-skills")

    def test_symlink_entrypoint_and_cli_errors(self):
        entry = self.base / "setup link"
        entry.symlink_to(os.path.relpath(ROOT / "script/setup", self.base))
        self.setup("--skip-skills", entry=entry)
        self.assertTrue((self.home / ".gitconfig").is_symlink())
        self.assertIn("usage:", self.setup("--help").stdout)
        self.setup("--unknown", ok=False)
        self.env["TEST_PLATFORM"] = "Other"
        self.setup("--skip-skills", ok=False)

    def test_shared_agent_json_is_valid(self):
        for relative in (".codex/hooks.json", ".claude/settings.json"):
            json.loads((ROOT / "home" / relative).read_text())


if __name__ == "__main__":
    unittest.main()
