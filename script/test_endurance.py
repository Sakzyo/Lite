#!/usr/bin/env python3
"""No browser launch: exercise timeout cleanup and exact-profile matching."""
import io
import pathlib
import signal
import subprocess
import unittest
from unittest.mock import Mock, patch

import endurance
import test_processes


class EnduranceTests(unittest.TestCase):
    def test_matching_excludes_other_apps_profiles_and_argument_prefixes(self):
        app, profile = pathlib.Path('/tmp/Lite.app'), pathlib.Path('/tmp/endurance-1')
        rows = '\n'.join([
            '11 /tmp/Lite.app/Contents/MacOS/Lite --lite-test-profile=/tmp/endurance-1',
            '12 /tmp/Lite.app/Contents/MacOS/Lite --lite-test-profile=/tmp/endurance-12',
            '13 /tmp/Other.app/Contents/MacOS/Lite --lite-test-profile=/tmp/endurance-1',
            '14 python inspect /tmp/Lite.app/Contents/MacOS/Lite --lite-test-profile=/tmp/endurance-1',
            '15 /tmp/Lite.app/Contents/MacOS/Lite --lite-test-profile=/tmp/regular',
        ])
        with patch.object(test_processes.subprocess, 'check_output', return_value=rows):
            self.assertEqual(test_processes.app_pids(app, profile), [11])

    def test_app_graceful_stop(self):
        with patch.object(test_processes, 'app_pids', side_effect=[[11], []]), \
             patch.object(test_processes.os, 'kill') as kill, \
             patch.object(test_processes.time, 'sleep'):
            result = test_processes.stop_app(None, None)
        self.assertTrue(result['gracefulExit'])
        kill.assert_called_once_with(11, signal.SIGTERM)

    def test_app_forced_stop_is_failure(self):
        with patch.object(test_processes, 'app_pids', return_value=[11]), \
             patch.object(test_processes.os, 'kill') as kill:
            result = test_processes.stop_app(None, None, timeout=0)
        self.assertFalse(result['gracefulExit'])
        self.assertEqual(result['forcedProcessIDs'], [11])
        self.assertEqual(kill.call_args_list[-1].args, (11, signal.SIGKILL))

    def phase(self, waits, running=True, leftover=False):
        process = Mock(pid=42)
        process.wait.side_effect = waits
        process.poll.return_value = None if running else 0
        cleanup = dict(processIDs=[77] if leftover else [], forcedProcessIDs=[], gracefulExit=True)
        with patch.object(endurance.subprocess, 'Popen', return_value=process) as launch, \
             patch.object(endurance.os, 'killpg') as kill, \
             patch.object(endurance, 'stop_app', return_value=cleanup):
            result = endurance.run_phase(['test'], io.StringIO(), pathlib.Path('/tmp/endurance-1'), 330)
        self.assertTrue(launch.call_args.kwargs['start_new_session'])
        self.assertEqual(launch.call_args.kwargs['env']['LITE_TEST_PROFILE'], '/tmp/endurance-1')
        return result, kill.call_args_list

    def test_timeout_keeps_failure_after_graceful_runner_exit(self):
        result, calls = self.phase([subprocess.TimeoutExpired('test', 330), 0])
        self.assertEqual(result[0], 124)
        self.assertEqual([call.args for call in calls], [(42, signal.SIGTERM)])

    def test_timeout_hard_fallback_follows_graceful_attempt(self):
        result, calls = self.phase([subprocess.TimeoutExpired('test', 330), subprocess.TimeoutExpired('test', 20), -9])
        self.assertEqual(result[0], 124)
        self.assertEqual([call.args for call in calls], [(42, signal.SIGTERM), (42, signal.SIGKILL)])

    def test_successful_runner_with_leftover_app_fails(self):
        result, calls = self.phase([0], running=False, leftover=True)
        self.assertEqual(result[0], 1)
        self.assertEqual(calls, [])

    def test_success_requires_no_leftover_app(self):
        result, calls = self.phase([0], running=False)
        self.assertEqual(result[0], 0)
        self.assertEqual(calls, [])


if __name__ == '__main__':
    unittest.main()
