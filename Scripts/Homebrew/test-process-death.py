#!/usr/bin/env python3
"""Kill the actual Swift transaction process at each replacement boundary.

Run after swift test has built the test bundle. Uses only synthetic temp files.
"""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile

for boundary in ("copied", "oldMoved", "installed"):
    with tempfile.TemporaryDirectory(prefix="dailydisk-crash-") as directory:
        root = Path(directory)
        for app, build in (("Candidate.app", "17"), ("Applications/DailyDisk.app", "16")):
            path = root / app
            path.mkdir(parents=True)
            (path / "build").write_text(build)
        env = dict(os.environ, DAILYDISK_CRASH_FIXTURE_ROOT=str(root), DAILYDISK_CRASH_FIXTURE_BOUNDARY=boundary)
        command = ["swift", "test", "--skip-build", "--filter", "externalInstallationCrashFixture"]
        killed = subprocess.run(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
        assert killed.returncode != 0, killed.stdout
        state = root / "Control/update-preparation.json"
        assert json.loads(state.read_text())["phase"] == "externalInstalling"
        for name in (".installation.lock", ".update-work.lock"):
            with (root / "Control" / name).open("r+") as lease:
                fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        del env["DAILYDISK_CRASH_FIXTURE_BOUNDARY"]
        recovered = subprocess.run(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
        assert recovered.returncode == 0, recovered.stdout
        assert json.loads(state.read_text())["phase"] == "ready"
        assert (root / "Applications/DailyDisk.app/build").read_text() == "17"
        assert sorted(x.name for x in (root / "Applications").iterdir()) == ["DailyDisk.app"]
        print("PASS: SIGKILL at", boundary, "retains the gate; explicit retry recovers under fresh leases", flush=True)
