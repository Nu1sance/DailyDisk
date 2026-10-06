#!/usr/bin/env python3
"""Exercise real brew commands with a disposable local tap and synthetic payload.

Never installs DailyDisk, opens its database, or changes its receipt. Requires brew.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid
import zipfile


def main():
    brew = shutil.which("brew")
    if not brew:
        raise SystemExit("Homebrew is required for this optional integration test")
    token = "dailydisk-contract-" + uuid.uuid4().hex[:12]
    tap_name = "dailydisk-fixture/" + token
    repository = Path(subprocess.check_output([brew, "--repository"], text=True).strip())
    tap = repository / "Library/Taps/dailydisk-fixture" / ("homebrew-" + token)
    env = dict(os.environ, HOMEBREW_NO_AUTO_UPDATE="1", HOMEBREW_NO_ANALYTICS="1",
               HOMEBREW_DEVELOPER="1")
    with tempfile.TemporaryDirectory(prefix="dailydisk-native-contract-") as directory:
        root = Path(directory)
        trace = root / "trace.jsonl"
        target = root / "installed-version"
        # Run the production parser as a locally compiled test tool. Do not put
        # this unnotarized binary into the quarantined Cask download: Gatekeeper
        # acceptance belongs to the separate signed/notarized release test.
        (root / "main.swift").write_text('''import Foundation
enum UpdatePreparationError: Error { case invalidState }
print(try HomebrewInvocation.current().rawValue)
''')
        source = Path(__file__).resolve().parents[2] / "Sources/DailyDiskPlatform/HomebrewInvocation.swift"
        probe = root / "DailyDiskHomebrewContextProbe"
        subprocess.run(["swiftc", str(source), str(root / "main.swift"), "-o", str(probe)], check=True)
        fixture = root / "fixture.py"
        fixture.write_text('''#!/usr/bin/python3
import json, pathlib, subprocess, sys, os
operation, version, trace, target, probe = sys.argv[1:]
command = subprocess.check_output([probe], text=True).strip()
with open(trace, "a") as stream:
    stream.write(json.dumps(dict(operation=operation, version=version, command=command)) + "\\n")
path = pathlib.Path(target)
if operation == "install":
    if (path.parent / "reject-install").exists(): sys.exit(7)
    if not path.exists() or int(path.read_text()) < int(version): path.write_text(version)
elif command in ("uninstall", "remove", "rm"):
    if path.exists(): path.unlink()
elif command not in ("install", "upgrade", "reinstall"):
    sys.exit(8)
''')
        fixture.chmod(0o755)
        archive = root / "fixture.zip"
        with zipfile.ZipFile(archive, "w") as output:
            output.write(fixture, "fixture.py")
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        (tap / "Casks").mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(tap)], check=True)

        def publish(version):
            (tap / "Casks" / (token + ".rb")).write_text('''cask "%s" do
  version "%s"
  sha256 "%s"
  url "%s"
  name "DailyDisk synthetic contract fixture"
  desc "Disposable native installer lifecycle regression"
  homepage "https://github.com/Nu1sance/DailyDisk"
  depends_on :macos
  installer script: { executable: "fixture.py", args: ["install", version.to_s, %s, %s, %s], sudo: false }
  uninstall script: { executable: "#{staged_path}/fixture.py", args: ["uninstall", version.to_s, %s, %s, %s], sudo: false, must_succeed: true }
end
''' % (token, version, digest, archive.as_uri(), json.dumps(str(trace)), json.dumps(str(target)), json.dumps(str(probe)),
       json.dumps(str(trace)), json.dumps(str(target)), json.dumps(str(probe))))
            subprocess.run(["git", "-C", str(tap), "add", "."], check=True)
            subprocess.run(["git", "-C", str(tap), "-c", "user.name=Fixture", "-c",
                            "user.email=fixture@example.invalid", "commit", "-qm", "Fixture " + str(version)], check=True)

        def run(command, success=True):
            result = subprocess.run([brew, command, "--cask", tap_name + "/" + token], env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            print(result.stdout, flush=True)
            assert (result.returncode == 0) == success, (command, result.returncode)

        try:
            publish(1)
            run("install")
            assert target.read_text() == "1"
            run("reinstall")
            assert target.read_text() == "1"
            publish(2)
            run("upgrade")
            assert target.read_text() == "2"
            target.write_text("4")  # Simulate a newer Sparkle installation.
            publish(3)
            run("upgrade")
            assert target.read_text() == "4", "Tap lag must never downgrade the app"
            publish(5)
            (root / "reject-install").touch()
            run("upgrade", success=False)
            assert target.read_text() == "4", "Failed upgrade/rollback must preserve the newer app"
            (root / "reject-install").unlink()
            run("uninstall")
            assert not target.exists()
            events = [json.loads(line) for line in trace.read_text().splitlines()]
            assert any(x["operation"] == "uninstall" and x["command"] == "upgrade" for x in events)
            assert any(x["operation"] == "uninstall" and x["command"] == "reinstall" for x in events)
            print(json.dumps(events, indent=2))
            print("PASS: native install/reinstall/upgrade, newer-app preservation, failed upgrade, uninstall")
        finally:
            # Only this random synthetic token; never touch any production cask.
            subprocess.run([brew, "uninstall", "--cask", "--force", tap_name + "/" + token], env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            shutil.rmtree(tap)


if __name__ == "__main__":
    main()
