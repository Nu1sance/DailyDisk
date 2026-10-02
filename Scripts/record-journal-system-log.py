#!/usr/bin/env python3
"""Finite, private rolling system-log recorder; no system configuration changes."""
import argparse
import json
import os
import pathlib
import selectors
import signal
import subprocess
import tempfile
import time

PREDICATE = '''process == "fseventsd" OR
(process == "com.apple.MobileSoftwareUpdate.CleanupPreparePathService" AND
(eventMessage CONTAINS[c] "mount" OR eventMessage CONTAINS[c] "snapshot" OR eventMessage CONTAINS[c] "Cleaning")) OR
(process == "softwareupdated" AND
(eventMessage CONTAINS[c] "PERSISTED_STATE" OR eventMessage CONTAINS[c] "ValidatePersisted" OR eventMessage CONTAINS[c] "PurgeAllAssetsAtStartup")) OR
(process == "diskarbitrationd" AND eventMessage CONTAINS[c] "DAVolumePath") OR
(process == "launchd" AND (eventMessage CONTAINS[c] "fseventsd" OR eventMessage CONTAINS[c] "softwareupdated"))'''
FILE_LIMIT = 2 * 1024 * 1024
FILE_COUNT = 10


class RollingOutput:
    def __init__(self, root):
        self.root = root
        self.file = None
        self.size = 0
        self.rotations = 0
        self.closed = False

    def append(self, data):
        if self.closed:
            raise ValueError("output is closed")
        if len(data) > FILE_LIMIT:
            return False
        if self.file is not None and self.size + len(data) > FILE_LIMIT:
            self.file.close()
            self.file = None
            for i in range(FILE_COUNT - 1, 0, -1):
                src = self.root / ('system.%d.jsonl' % (i - 1))
                if src.exists():
                    src.replace(self.root / ('system.%d.jsonl' % i))
            self.rotations += 1
            self.size = 0
        if self.file is None:
            fd = os.open(self.root / 'system.0.jsonl', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            self.file = os.fdopen(fd, 'wb', buffering=0)
        remaining = memoryview(data)
        while remaining:
            written = self.file.write(remaining)
            if not written:
                raise OSError("short write")
            remaining = remaining[written:]
        self.size += len(data)
        return True

    def close(self):
        self.closed = True
        if self.file:
            self.file.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=int, default=86400)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 86400:
        parser.error('seconds must be in 1...86400')
    os.umask(0o077)
    root = pathlib.Path(tempfile.mkdtemp(prefix='DailyDisk-system-log-', dir=pathlib.Path.home() / 'Library/Logs'))
    (root / 'recorder.pid').write_text(str(os.getpid()))
    print(root, flush=True)
    stopped = []
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stopped.append(True))
    output = RollingOutput(root)
    start, mono = time.time(), time.monotonic()
    dropped = lines = 0
    reason = 'deadline'
    child = subprocess.Popen(['/usr/bin/log', 'stream', '--style', 'ndjson', '--level', 'debug',
                              '--predicate', PREDICATE], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    buffer = b''
    discard_line = False
    try:
        while max(time.time() - start, time.monotonic() - mono) < args.seconds:
            if stopped:
                reason = 'signal'
                break
            if not selector.select(timeout=1):
                continue
            chunk = os.read(child.stdout.fileno(), 65536)
            if not chunk:
                reason = 'streamExited'
                break
            buffer += chunk
            while b'\n' in buffer:
                line, buffer = buffer.split(b'\n', 1)
                if discard_line:
                    discard_line = False
                    continue
                if output.append(line + b'\n'):
                    lines += 1
                else:
                    dropped += 1
            if len(buffer) > FILE_LIMIT:
                buffer = b''
                discard_line = True
                dropped += 1
    except OSError:
        reason = 'ioFailure'
    finally:
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
        selector.close()
        child.stdout.close()
        output.close()
        (root / 'result.json').write_text(json.dumps({'reason': reason, 'lines': lines,
            'oversizedLinesDropped': dropped, 'rotations': output.rotations,
            'startedUnix': start, 'finishedUnix': time.time(), 'streamExitCode': child.returncode}))
    return 0 if reason in ('deadline', 'signal') else 1


if __name__ == '__main__':
    raise SystemExit(main())
