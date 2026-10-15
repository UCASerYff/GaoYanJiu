#!/usr/bin/env python3
"""Exercise the real installer in a private fake system; never register an app.

Only absolute system-tool/target paths are redirected in a temporary copy. The
installer's control flow, verification functions, traps, and awk matcher remain
the production source. Every mutating mock rejects paths outside its fixture.
"""

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
ZSH = "/bin/zsh"
APP_ID = "com.academic-achievement.manager"
VERSION = "4.03"
NUMBER = "4"


MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, plistlib, shutil, signal, sys
root = pathlib.Path(os.environ["INSTALL_FIXTURE_ROOT"])
case = os.environ["INSTALL_FIXTURE_CASE"]
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
state_path = root / "mock-state.json"
state = json.loads(state_path.read_text()) if state_path.exists() else {}
with (root / "commands.jsonl").open("a") as stream:
    stream.write(json.dumps([name, *args]) + "\n")
def save(): state_path.write_text(json.dumps(state))
def die(message="injected failure", code=75):
    print(message, file=sys.stderr)
    sys.exit(code)
def inside(value):
    p = pathlib.Path(value).absolute()
    if p != root and root not in p.parents: die("UNSAFE mock path: " + str(p), 99)
    return p
def marker(value):
    p = pathlib.Path(value)
    for q in [p, *p.parents]:
        if (q / "marker").exists(): return (q / "marker").read_text()
    return ""
def once(key):
    old = state.get(key, 0)
    state[key] = old + 1
    save()
    return old == 0
if name == "PlistBuddy":
    value = plistlib.loads(inside(args[-1]).read_bytes())
    for key in args[1].removeprefix("Print :").split(":"): value = value[key]
    print(value)
elif name == "codesign":
    value = marker(args[-1])
    if "--verify" in args:
        if case == "source_verify" and value == "new": die()
        if case == "target_verify" and value == "new" and "/Applications/" in args[-1]: die()
    elif "--entitlements" in args:
        if case == "entitlements": die()
        sys.stdout.buffer.write(plistlib.dumps({
            "com.apple.security.application-groups": ["5G96498KGJ.com.academic-achievement.manager"],
            "com.apple.security.app-sandbox": True,
        }))
    else:
        print("TeamIdentifier=" + ("WRONGTEAM" if case == "team" else "5G96498KGJ"), file=sys.stderr)
elif name == "xcrun":
    if case == "entrypoint": die()
    print("                 U _NSExtensionMain")
elif name == "pgrep":
    sys.exit(0 if case == "running" else 1)
elif name in ("killall", "pkill", "kill"):
    die("UNSAFE process restart", 99)
elif name == "sleep":
    pass
elif name == "shasum":
    if case == "archive_checksum": die()
elif name == "ditto":
    if args[:2] == ["-x", "-k"]:
        if case == "archive_extract": die()
        source = root / "archive-source.app"
        destination = inside(args[-1]) / "搞研究.app"
    else:
        source, destination = map(inside, args)
    shutil.copytree(source, destination, dirs_exist_ok=True)
    if case == "copy": die()
    if case in ("signal_int", "signal_term"):
        os.kill(os.getppid(), signal.SIGINT if case == "signal_int" else signal.SIGTERM)
elif name == "mv":
    source, destination = map(inside, args)
    if case == "move": die()
    shutil.move(source, destination)
elif name == "rm":
    for value in args:
        if value.startswith("-"): continue
        p = inside(value)
        if case == "stage_cleanup" and p.name.startswith(".install.noindex."): die()
        if p.is_symlink() or p.is_file(): p.unlink()
        elif p.exists(): shutil.rmtree(p)
elif name == "rmdir":
    for value in args: inside(value).rmdir()
elif name == "lsregister":
    if args == ["-dump"]:
        if case == "ls_dump": die()
    else:
        p = inside(args[-1])
        if args[0] == "-u" and case == "old_ls_remove" and once("old_ls_remove"): die()
        if args[0] == "-f":
            if marker(p) == "new":
                state["new_registrations"] = state.get("new_registrations", 0) + 1
                save()
                if case == "late_removal_register_failure" and state["new_registrations"] > 1: die()
            if marker(p) == "new" and case in ("new_ls_register", "rollback_ls_register"): die()
            if marker(p) == "old" and case == "rollback_ls_register": die()
elif name == "pluginkit":
    if args[0] == "-r":
        inside(args[1])
        if once("remove"):
            if case == "old_plugin_absent": die("remove: no plugin at " + args[1], 1)
            if case == "old_plugin_remove": die("daemon connection failed")
    elif args[0] == "-a":
        inside(args[1])
        if marker(args[1]) == "new" and case == "new_plugin_add": die()
        if marker(args[1]) == "old" and case == "rollback_plugin_add": die()
    elif args[0] == "-e":
        if case in ("new_election", "rollback_plugin_add") and once("election"): die()
    elif "-vv" not in args:
        if case == "election_query": die("daemon connection failed")
        if case == "no_election": sys.exit(1)
        # Real macOS `-v` is still compact. Path detail requires `-vv`.
        version = "4.03" if "-v" in args else "4.02"
        print(("-" if case == "old_ignore" else "+") + " com.academic-achievement.manager.widgets(" + version + ") fixture-UUID 2026-10-15")
    else:
        count = state.get("queries", 0) + 1
        state["queries"] = count
        save()
        widget = str(root / "Applications/搞研究.app/Contents/PlugIns/ResearchWidgets.appex")
        prefix, version, path = "+", "4.03", widget
        if case == "async" and count < 4: sys.exit(1)
        if case in ("late_removal", "late_removal_register_failure"):
            # A delayed removal erases a record after two initially valid samples.
            # It reappears only if the installer really reconciles this host.
            if count == 3 or (count > 3 and state.get("new_registrations", 0) < 2): sys.exit(1)
        if case in ("timeout", "old_ignore"): version = "4.02"
        if case == "wrong_path": path += ".other"
        if case == "negative": prefix = "-"
        if case == "default": prefix = "="
        if case == "cross_record":
            print("+ com.academic-achievement.manager.widgets(4.03)\n    Path = /wrong/path")
            prefix, version = "-", "4.02"
        if case == "cross_default":
            print("+ com.academic-achievement.manager.widgets(4.03)\n    UUID = fixture")
            prefix = "="
        print(prefix + " com.academic-achievement.manager.widgets(" + version + ")\n    Path = " + path)
else:
    die("unknown mock tool: " + name, 99)
'''


def bundle(path, version, marker, app_id=APP_ID):
    widget = path / "Contents/PlugIns/ResearchWidgets.appex"
    (widget / "Contents").mkdir(parents=True)
    (path / "marker").write_text(marker)
    info = {
        "CFBundleIdentifier": app_id,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": NUMBER,
    }
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    info.update({
        "CFBundleIdentifier": APP_ID + ".widgets",
        "CFBundlePackageType": "XPC!",
        "CFBundleExecutable": "ResearchWidgets",
        "CFBundleSupportedPlatforms": ["MacOSX"],
        "NSExtension": {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"},
    })
    (widget / "Contents/Info.plist").write_bytes(plistlib.dumps(info))


def redirect(source, old, new):
    if source.count(old) != 1:
        raise AssertionError("installer boundary changed; review test redirect: " + old)
    return source.replace(old, new)


class InstallSafetyRegression(unittest.TestCase):
    maxDiff = None

    def run_case(self, case, *, succeeds=False, no_old=False, expected_status=None):
        with tempfile.TemporaryDirectory(prefix="research-install-regression-", dir="/private/tmp") as directory:
            root = Path(directory)
            scripts = root / "scripts"
            tools = root / "mock-bin"
            scripts.mkdir()
            tools.mkdir()
            source = root / "build.noindex/搞研究.app"
            target = root / "Applications/搞研究.app"
            target.parent.mkdir()
            bundle(source, VERSION, "new")
            if not no_old:
                bundle(target, "4.02", "old")
            (root / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleShortVersionString": VERSION,
                "CFBundleVersion": NUMBER,
            }))
            shutil.copy(PROJECT / "scripts/registered_apps.py", scripts)
            for name in ("PlistBuddy", "codesign", "xcrun", "pgrep", "killall", "pkill", "kill", "sleep", "shasum",
                         "ditto", "mv", "rm", "rmdir", "lsregister", "pluginkit"):
                tool = tools / name
                tool.write_text("#!/bin/sh\nexit 0\n" if name == "sleep" else MOCK)
                tool.chmod(0o700)
            installer = (PROJECT / "scripts/install.sh").read_text()
            installer = redirect(installer, 'TARGET="/Applications/搞研究.app"', 'TARGET="' + str(target) + '"')
            installer = redirect(installer,
                "LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                'LSREGISTER="' + str(tools / "lsregister") + '"')
            installer = redirect(installer, "PLISTBUDDY=/usr/libexec/PlistBuddy", 'PLISTBUDDY="' + str(tools / "PlistBuddy") + '"')
            installer = redirect(installer, '"/usr/bin/codesign"', repr(str(tools / "codesign")))
            for tool in ("mv", "rm", "rmdir", "sleep"):
                installer = installer.replace("/bin/" + tool + " ", '"' + str(tools / tool) + '" ')
            (scripts / "install.sh").write_text(installer)
            env = dict(os.environ, INSTALL_FIXTURE_ROOT=str(root), INSTALL_FIXTURE_CASE=case,
                       PATH=str(tools) + os.pathsep + os.environ["PATH"])
            env.pop("GAO_INSTALL_APP", None)
            if case == "lock_exists":
                (root / ".install-lock.noindex").mkdir()
            if case == "source_missing":
                env["GAO_INSTALL_APP"] = str(root / "missing.app")
            if case in ("archive_checksum", "archive_extract", "archive_success"):
                shutil.move(source, root / "archive-source.app")
                (root / "dist").mkdir()
            if case == "target_identity":
                info = target / "Contents/Info.plist"
                value = plistlib.loads(info.read_bytes())
                value["CFBundleIdentifier"] = "fixture.unrelated"
                info.write_bytes(plistlib.dumps(value))
            if case == "target_symlink":
                saved = root / "unrelated.app"
                shutil.move(target, saved)
                target.symlink_to(saved)
            if case == "source_identifier":
                info = source / "Contents/Info.plist"
                value = plistlib.loads(info.read_bytes())
                value["CFBundleIdentifier"] = "fixture.wrong"
                info.write_bytes(plistlib.dumps(value))
            result = subprocess.run([ZSH, str(scripts / "install.sh")], env=env, capture_output=True, text=True, timeout=90)
            details = f"case={case}\nstatus={result.returncode}\n{result.stdout}\n{result.stderr}"
            if expected_status is not None or succeeds:
                self.assertEqual(result.returncode, expected_status if expected_status is not None else 0, details)
            else:
                self.assertNotEqual(result.returncode, 0, details)
            lock = root / ".install-lock.noindex"
            self.assertEqual(lock.exists(), case == "lock_exists", details)
            self.assertEqual(bool(list(root.glob(".install.noindex.*"))), case == "stage_cleanup", details)
            if succeeds:
                self.assertEqual((target / "marker").read_text(), "new", details)
                backups = list((root / "rollback").glob("*.app"))
                self.assertEqual(len(backups), 0 if no_old else 1, details)
                if backups: self.assertEqual((backups[0] / "marker").read_text(), "old", details)
            elif no_old:
                self.assertFalse(target.exists(), details)
            else:
                self.assertEqual((target / "marker").read_text(), "old", details)
                self.assertFalse(list((root / "rollback").glob("*.app")), details)
            commands_file = root / "commands.jsonl"
            commands = [json.loads(line) for line in commands_file.read_text().splitlines()] if commands_file.exists() else []
            self.assertFalse(any("UNSAFE" in line for line in (result.stdout, result.stderr)), details)
            self.assertFalse(any(command[0] in ("killall", "pkill", "kill") for command in commands), details)
            state_file = root / "mock-state.json"
            state = json.loads(state_file.read_text()) if state_file.exists() else {}
            return result, commands, state

    def test_preflight_failure_unlocks_and_preserves_old_app(self):
        for case in ("source_missing", "source_identifier", "source_verify", "entitlements", "team", "entrypoint",
                     "archive_checksum", "archive_extract", "running", "target_identity", "target_symlink", "ls_dump", "election_query"):
            with self.subTest(case=case): self.run_case(case)

    def test_existing_lock_is_not_removed(self):
        self.run_case("lock_exists")

    def test_transaction_failures_restore_bundle_and_unlock(self):
        for case in ("old_plugin_remove", "old_ls_remove", "move", "copy", "target_verify", "new_ls_register",
                     "new_plugin_add", "new_election", "timeout", "rollback_ls_register", "rollback_plugin_add"):
            with self.subTest(case=case):
                result, commands, state = self.run_case(case)
                self.assertIn("安装未完成，正在恢复旧程序", result.stderr)
                if case.startswith("rollback_"): self.assertIn("自动回滚未完全成功", result.stderr)
                if case == "timeout": self.assertEqual(state["queries"], 30)

    def test_registration_must_match_enabled_version_and_path_in_one_record(self):
        for case in ("wrong_path", "negative", "default", "cross_record", "cross_default"):
            with self.subTest(case=case):
                _, _, state = self.run_case(case)
                self.assertEqual(state["queries"], 30)

    def test_delayed_registration_success_and_old_absent_plugin(self):
        for case in ("success", "async", "old_plugin_absent", "no_election", "archive_success"):
            with self.subTest(case=case):
                result, commands, state = self.run_case(case, succeeds=True)
                self.assertNotIn("正在恢复旧程序", result.stderr)
                self.assertIn(["pluginkit", "-m", "-A", "-D", "-vv", "-i", APP_ID + ".widgets"], commands)
                self.assertEqual(state["queries"], 13 if case == "async" else 10)
                self.assertEqual(state["new_registrations"], 2 if case == "async" else 1)

    def test_late_removal_requires_fresh_stability_and_reregister_failure_rolls_back(self):
        result, _, state = self.run_case("late_removal", succeeds=True)
        self.assertNotIn("正在恢复旧程序", result.stderr)
        self.assertEqual(state["queries"], 13)
        self.assertEqual(state["new_registrations"], 2)
        result, commands, state = self.run_case("late_removal_register_failure")
        self.assertIn("安装未完成，正在恢复旧程序", result.stderr)
        self.assertEqual(state["queries"], 3)
        self.assertEqual(state["new_registrations"], 2)
        self.assertIn(["pluginkit", "-e", "use", "-i", APP_ID + ".widgets"], commands)

    def test_first_install_success_and_failure(self):
        self.run_case("success", succeeds=True, no_old=True)
        self.run_case("timeout", no_old=True)

    def test_old_ignore_election_restored(self):
        _, commands, _ = self.run_case("old_ignore")
        self.assertIn(["pluginkit", "-e", "ignore", "-i", APP_ID + ".widgets"], commands)

    def test_signals_restore_old_app(self):
        for case, status in (("signal_int", 130), ("signal_term", 143)):
            with self.subTest(case=case): self.run_case(case, expected_status=status)

    def test_stage_cleanup_failure_does_not_leave_lock(self):
        self.run_case("stage_cleanup", succeeds=True)

    def test_zsh_function_failure_global_exit_trap(self):
        # The exact zsh behavior that left the real replacement and lock behind.
        source = "set -euo pipefail\n%s\ntrap 'print CLEANUP:$?' EXIT\nfail() { return 1; }\nfail\n"
        for option, cleanup in (("", False), ("setopt POSIX_TRAPS", True)):
            with self.subTest(option=option):
                result = subprocess.run([ZSH, "-c", source % option], capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                self.assertEqual("CLEANUP:1" in result.stdout, cleanup)


if __name__ == "__main__":
    unittest.main(verbosity=2)
