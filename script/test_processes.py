"""Cleanup restricted to one explicitly created synthetic app/profile pair."""
import os
import signal
import subprocess
import time


def app_pids(app, profile):
    executable = str(app / 'Contents/MacOS/Lite')
    argument = '--lite-test-profile=' + str(profile)
    rows = subprocess.check_output(['ps', '-ww', '-axo', 'pid=,command='], text=True)
    matches = []
    for row in rows.splitlines():
        parts = row.strip().split(None, 1)
        if len(parts) != 2:
            continue
        command = parts[1]
        if command.startswith(executable + ' ') and ' ' + argument + ' ' in ' ' + command + ' ':
            matches.append(int(parts[0]))
    return matches


def stop_app(app, profile, timeout=10):
    original = app_pids(app, profile)
    for pid in original:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + timeout
    remaining = original
    while remaining and time.monotonic() < deadline:
        time.sleep(.1)
        remaining = app_pids(app, profile)
    # Recheck the full command before a forced stop, including after a PID exits.
    remaining = app_pids(app, profile) if remaining else []
    for pid in remaining:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return dict(processIDs=original, forcedProcessIDs=remaining, gracefulExit=not remaining)
