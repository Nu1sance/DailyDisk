#!/usr/bin/env python3
"""Opt-in macOS investigation, Python 3 only; never writes inventory or checkpoints."""
import argparse
import ctypes
import datetime
import json
import os
import pathlib
import plistlib
import signal
import re
import stat
import subprocess
import tempfile
import time
import uuid

LIMIT = 2 * 1024 * 1024


def command(*args):
    return subprocess.check_output(args, timeout=10, stderr=subprocess.DEVNULL)


def transition(previous, current):
    if current.get('error'):
        return 'unavailable'
    if previous is None or previous.get('error'):
        return 'initial'
    if any(previous.get(k) != current.get(k) for k in ('volume', 'device', 'bsd')):
        return 'deviceOrVolumeChanged'
    if previous.get('journal') != current.get('journal'):
        return 'journalChanged'
    return 'unchanged'


class Journal:
    def __init__(self):
        self.api = ctypes.CDLL('/System/Library/Frameworks/CoreServices.framework/CoreServices')
        self.cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        self.api.FSEventsCopyUUIDForDevice.argtypes = [ctypes.c_int32]
        self.api.FSEventsCopyUUIDForDevice.restype = ctypes.c_void_p
        self.cf.CFUUIDCreateString.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        self.cf.CFUUIDCreateString.restype = ctypes.c_void_p
        self.cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long, ctypes.c_uint32]
        self.cf.CFStringGetCString.restype = ctypes.c_bool
        self.cf.CFRelease.argtypes = [ctypes.c_void_p]

    def sample(self, path):
        try:
            before = os.stat(path).st_dev
            info = plistlib.loads(command('/usr/sbin/diskutil', 'info', '-plist', path))
            after = os.stat(path).st_dev
            if before != after or info.get('MountPoint') != path:
                return {'error': 'unstableMount'}
            node = info.get('DeviceNode', '')
            if not re.fullmatch(r'/dev/disk[0-9]+(?:s[0-9]+)*', node):
                return {'error': 'unverifiedDevice'}
            node_stat = os.stat(node)
            if not stat.S_ISBLK(node_stat.st_mode):
                return {'error': 'unverifiedDevice'}
            device = node_stat.st_rdev & 0xffffffff
            native = ctypes.c_int32(device).value
            result = {'device': device, 'nativeDevice': native,
                      'bsd': info.get('DeviceIdentifier'), 'volume': info.get('VolumeUUID'),
                      'filesystem': info.get('FilesystemType'), 'pathDevice': before & 0xffffffff, 'journal': None}
            if result['filesystem'] != 'apfs' or not result['volume']:
                return {'error': 'unverifiedVolume'}
            ref = self.api.FSEventsCopyUUIDForDevice(native)
            if ref:
                string = None
                try:
                    string = self.cf.CFUUIDCreateString(None, ref)
                    buffer = ctypes.create_string_buffer(64)
                    if not string or not self.cf.CFStringGetCString(string, buffer, 64, 0x08000100):
                        return {'error': 'uuidConversion'}
                    result['journal'] = str(uuid.UUID(buffer.value.decode('ascii')))
                finally:
                    if string:
                        self.cf.CFRelease(string)
                    self.cf.CFRelease(ref)
            if os.stat(path).st_dev != before or os.stat(node).st_rdev != node_stat.st_rdev:
                return {'error': 'unstableMount'}
            if result['journal'] is None:
                result['error'] = 'journalUnavailable'
            return result
        except (OSError, ValueError, subprocess.SubprocessError, plistlib.InvalidFileException):
            return {'error': 'queryFailed'}


class Writer:
    def __init__(self, path):
        self.fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        self.size = 0

    def write(self, record, terminal=False):
        data = (json.dumps(record, sort_keys=True) + '\n').encode()
        if self.size + len(data) > LIMIT - (0 if terminal else 2048):
            return False
        view = memoryview(data)
        while view:
            n = os.write(self.fd, view)
            if n <= 0:
                raise OSError('short write')
            view = view[n:]
        self.size += len(data)
        return True

    def close(self):
        os.close(self.fd)


def expired(start_wall, start_mono, now_wall, now_mono, seconds):
    return max(now_wall - start_wall, now_mono - start_mono) >= seconds


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hours', type=float, default=24)
    parser.add_argument('--include-external-data', action='store_true', help='Also observe /Volumes/Data when mounted')
    args = parser.parse_args()
    if not 0 < args.hours <= 24:
        parser.error('hours must be greater than zero and at most 24')
    os.umask(0o077)
    root = pathlib.Path(tempfile.mkdtemp(prefix='DailyDisk-journal-', dir=pathlib.Path.home() / 'Library/Logs'))
    writer = Writer(root / 'samples.jsonl')
    (root / 'observer.pid').write_text(str(os.getpid()) + '\n')
    print(root, flush=True)
    stopping = []
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stopping.append(True))
    start_wall, start_mono = time.time(), time.monotonic()
    reason = 'deadline'
    previous = {}
    last_wall = None
    try:
        journal = Journal()
        boot = command('/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid').decode().strip()
        writer.write({'kind': 'started', 'hours': args.hours, 'intervalSeconds': 60,
                      'pid': os.getpid(), 'bootSession': boot, 'byteLimit': LIMIT})
        while not expired(start_wall, start_mono, time.time(), time.monotonic(), args.hours * 3600):
            if stopping:
                reason = 'signal'
                break
            now = time.time()
            record = {'kind': 'sample', 'wallUTC': datetime.datetime.fromtimestamp(now, datetime.timezone.utc).isoformat(),
                      'monotonicSeconds': time.monotonic(), 'gapSeconds': None if last_wall is None else now - last_wall}
            try:
                record['fseventsdPIDs'] = command('/usr/bin/pgrep', '-x', 'fseventsd').decode().split()
            except (OSError, subprocess.SubprocessError):
                record['fseventsdPIDs'] = []
            targets = [('data', '/System/Volumes/Data'), ('system', '/')]
            if args.include_external_data:
                targets.append(('externalData', '/Volumes/Data'))
            for name, path in targets:
                sample = journal.sample(path)
                record[name] = {**sample, 'transition': transition(previous.get(name), sample)}
                previous[name] = sample
            if not writer.write(record):
                reason = 'sizeLimit'
                break
            last_wall = now
            # No sleep assertion: gaps across system sleep remain visible.
            for _ in range(60):
                if stopping or expired(start_wall, start_mono, time.time(), time.monotonic(), args.hours * 3600):
                    break
                time.sleep(1)
        writer.write({'kind': 'stopped', 'reason': reason, 'wallUnix': time.time()}, terminal=True)
    except (OSError, subprocess.SubprocessError):
        # No retry loop on output failure. Stderr is fixed and contains no paths.
        print('Observer stopped: diagnostic I/O unavailable', flush=True)
        return 1
    finally:
        writer.close()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
