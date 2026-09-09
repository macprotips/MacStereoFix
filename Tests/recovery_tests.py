import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

harness = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="msf-recovery-") as temporary:
    for action in ["disarm", "close", "kill"]:
        log = Path(temporary) / action
        process = subprocess.Popen([str(harness)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            env={**os.environ, "MSF_RECOVERY_TEST_LOG": str(log)})
        assert process.stdout.readline() == b"ready\n"
        if action == "kill":
            process.kill()
            process.stdin.close()
        else:
            if action == "disarm":
                process.stdin.write(b"disarm\n")
                process.stdin.flush()
            process.stdin.close()
        process.wait(timeout=5)
        for _ in range(100):
            if log.exists():
                break
            time.sleep(0.02)
        assert log.exists() == (action != "disarm"), action
        if log.exists():
            assert log.read_text() == "test-headphones"
        print(f"Recovery helper: {action} passed (no audio settings changed)")
