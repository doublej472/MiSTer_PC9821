#!/usr/bin/env python3
"""A PASS banner must not hide a crashed simulation or an expected failure."""
import contextlib
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import test_protected_mode as runner


class RunnerContract(unittest.TestCase):
    def simulation(self, text, code=0):
        config = {'eip': 0, 'cr0': 1, 'cr3': 0}
        result = subprocess.CompletedProcess([], code, text, '')
        with patch.object(runner.subprocess, 'run', return_value=result):
            return runner.run_simulation('fixture', config, Path('unused.hex'), 0x10000)

    def test_pass_requires_successful_exit(self):
        self.assertTrue(self.simulation('TEST PASSED')[0])
        self.assertFalse(self.simulation('TEST PASSED', 1)[0])
        self.assertFalse(self.simulation('TEST PASSED', -6)[0])

    def test_failure_and_timeout_override_pass(self):
        self.assertFalse(self.simulation('TEST PASSED\nTEST FAILED')[0])
        self.assertFalse(self.simulation('TEST PASSED\nTIMEOUT')[0])

    def test_strict_rejects_expected_failure(self):
        with patch.object(runner, 'TESTS', {'fixture': {'expect_fail': True}}), \
             patch.object(runner, 'build_testbench', return_value=True), \
             patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), \
             patch('sys.argv', ['runner', '--strict', 'fixture']), \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(runner.main(), 1)

    def test_xpass_is_not_success(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, 'fixture.asm').write_text('')
            with patch.object(runner, 'TESTS_DIR', Path(d)), \
                 patch.object(runner, 'TESTS', {'fixture': {'asm': 'fixture.asm', 'expect_fail': True}}), \
                 patch.object(runner, 'assemble', return_value=True), \
                 patch.object(runner, 'build_memory_image', return_value=0x10000), \
                 patch.object(runner, 'run_simulation', return_value=(True, False, False, 'TEST PASSED')):
                self.assertFalse(runner.run_test('fixture')[0])

    def test_every_program_runs(self):
        # The runner discovers programs by their .json; an .asm that no .json
        # names (directly or through %include) never runs.
        import json
        import re
        programs = Path(__file__).resolve().parent / 'programs'
        named = {json.loads(p.read_text()).get('asm') for p in programs.glob('*.json')}
        for src in list(programs.glob('*.asm')) + list(programs.glob('*.inc')):
            named.update(Path(m).name for m in
                         re.findall(r'%include\s+"([^"]+)"', src.read_text(errors='replace')))
        orphans = sorted(p.name for p in programs.glob('*.asm') if p.name not in named)
        self.assertEqual(orphans, [], 'programs no .json runs')


if __name__ == '__main__':
    unittest.main()
