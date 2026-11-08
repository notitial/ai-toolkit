"""A throwaway project, fake build tools on PATH and a private HOME for the build-kit tests."""
import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

KIT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(KIT))
from buildkit import android, core, ios  # noqa: E402

PLATFORMS = {"ios": ios, "android": android}
CONFIG = {
    "timeoutSeconds": 20,
    "ios": {"projectDir": "ios", "workspace": "App.xcworkspace", "schemes": ["App", "Other"],
            "configurations": ["Debug", "Release"],
            "destinations": {"sim": "platform=iOS Simulator,name=iPhone 16", "catalyst": "platform=macOS,variant=Mac Catalyst"},
            "swiftlint": {"version": "0.57.0", "args": ["--strict"]}},
    "android": {"projectDir": "android", "variants": ["Debug", "Release"]},
}


def alive(pid):
    """True while the process exists and is not a zombie."""
    out = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return bool(out) and not out.startswith("Z")


class KitCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home, self.bin, self.root = self.tmp / "home", self.tmp / "bin", self.tmp / "proj"
        for d in (self.home, self.bin, self.root / "ios", self.root / "android"):
            d.mkdir(parents=True)
        self.build = self.install_kit(self.root)
        source = (Path(__file__).parent / "fake_tool.py").read_text().split("\n", 1)[1]
        for tool in ("xcodebuild", "xcrun", "swiftlint"):
            self.install(self.bin / tool, source)
        self.install(self.root / "android" / "gradlew", source)
        self.env = {"HOME": str(self.home), "PATH": "%s:%s" % (self.bin, os.environ["PATH"]), "SECRET_TOKEN": "hunter2"}
        patcher = mock.patch.dict(os.environ, self.env)
        patcher.start()
        self.addCleanup(patcher.stop)
        for name, value in (("LOCK_WAIT", 0.3), ("KILL_GRACE", 1)):
            p = mock.patch.object(core, name, value)
            p.start()
            self.addCleanup(p.stop)
        self.config(CONFIG)
        self.fake()

    @staticmethod
    def install_kit(project):
        """The kit as /add-build-kit copies it: <project>/tools/build-kit/{build.py,buildkit/}."""
        dest = project / "tools" / "build-kit"
        shutil.copytree(KIT / "buildkit", dest / "buildkit", ignore=shutil.ignore_patterns("__pycache__"))
        shutil.copy(KIT / "build.py", dest / "build.py")
        return dest / "build.py"

    def install(self, path, source):
        path.write_text("#!%s\n%s" % (sys.executable, source))
        path.chmod(0o755)

    def config(self, cfg):
        (self.root / ".build-kit.json").write_text(json.dumps(cfg))

    def edit_config(self, platform, **changes):
        cfg = copy.deepcopy(CONFIG)
        cfg[platform].update(changes)
        self.config(cfg)

    def fake(self, **plans):
        (self.home / "fake.json").write_text(json.dumps({k.replace("__", " "): v for k, v in plans.items()}))

    def calls(self):
        try:
            return [json.loads(line) for line in (self.home / "calls.log").read_text().splitlines()]
        except OSError:
            return []

    def run_kit(self, platform, action, cancel=None, **args):
        return core.run_action(PLATFORMS[platform], self.root, action, args, cancel or threading.Event())
