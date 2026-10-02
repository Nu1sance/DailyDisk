import importlib.util
import pathlib
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import plistlib
import stat

spec = importlib.util.spec_from_file_location('observer', pathlib.Path(__file__).with_name('observe-event-journal.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class ObserverTests(unittest.TestCase):
    def test_identity(self):
        a = {'volume': 'synthetic', 'device': 1, 'bsd': 'disk-test', 'journal': 'a'}
        self.assertEqual(m.transition(a, a), 'unchanged')
        self.assertEqual(m.transition(a, {**a, 'journal': 'b'}), 'journalChanged')
        self.assertEqual(m.transition(a, {**a, 'device': 2}), 'deviceOrVolumeChanged')
        self.assertEqual(m.transition(a, {'error': 'journalUnavailable'}), 'unavailable')
        self.assertEqual(m.transition(None, a), 'initial')

    def test_native_device_uses_block_node_not_root_firmlink(self):
        journal = m.Journal.__new__(m.Journal)
        observed = []
        journal.api = SimpleNamespace(FSEventsCopyUUIDForDevice=lambda device: observed.append(device))
        info = {'MountPoint': '/', 'DeviceNode': '/dev/disk1s1', 'DeviceIdentifier': 'disk1s1',
                'FilesystemType': 'apfs', 'VolumeUUID': 'synthetic'}
        def metadata(path):
            return SimpleNamespace(st_dev=2, st_rdev=3, st_mode=stat.S_IFBLK)
        with patch.object(m, 'command', return_value=plistlib.dumps(info)), patch.object(m.os, 'stat', side_effect=metadata):
            sample = journal.sample('/')
        self.assertEqual(observed, [3])
        self.assertEqual(sample['device'], 3)
        self.assertEqual(sample['pathDevice'], 2)
        self.assertEqual(sample['error'], 'journalUnavailable')

    def test_deadline_sleep_and_clock_change(self):
        self.assertTrue(m.expired(100, 100, 500, 101, 300))
        self.assertTrue(m.expired(100, 100, 50, 500, 300))
        self.assertFalse(m.expired(100, 100, 101, 101, 300))

    def test_output_bound_permissions_and_failure(self):
        with tempfile.TemporaryDirectory() as root:
            path = pathlib.Path(root) / 'samples'
            w = m.Writer(path)
            while w.write({'data': 'x' * 1000}):
                pass
            self.assertTrue(w.write({'kind': 'stopped', 'reason': 'sizeLimit'}, terminal=True))
            self.assertLessEqual(path.stat().st_size, m.LIMIT)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            w.close()
            with self.assertRaises(OSError):
                w.write({'x': 1}, terminal=True)
            with self.assertRaises(FileExistsError):
                m.Writer(path)


if __name__ == '__main__':
    unittest.main()
