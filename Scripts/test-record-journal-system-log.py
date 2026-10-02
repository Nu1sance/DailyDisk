import importlib.util
import pathlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('recorder', pathlib.Path(__file__).with_name('record-journal-system-log.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class RollingTests(unittest.TestCase):
    def test_rotation_preserves_lines_and_cap(self):
        with tempfile.TemporaryDirectory() as root:
            p = pathlib.Path(root)
            w = m.RollingOutput(p)
            for i in range(25):
                self.assertTrue(w.append(str(i).encode() + b'x' * (m.FILE_LIMIT - 3) + b'\n'))
            self.assertFalse(w.append(b'x' * (m.FILE_LIMIT + 1)))
            w.close()
            files = list(p.glob('system.*.jsonl'))
            self.assertEqual(len(files), 10)
            self.assertLessEqual(sum(f.stat().st_size for f in files), 20 * 1024 * 1024)
            self.assertTrue((p / 'system.0.jsonl').read_bytes().startswith(b'24'))
            for f in files:
                self.assertEqual(f.stat().st_mode & 0o777, 0o600)
                self.assertTrue(f.read_bytes().endswith(b'\n'))
            with self.assertRaises(ValueError):
                w.append(b'x')


if __name__ == '__main__':
    unittest.main()
