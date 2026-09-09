"""Exercise the real installer control flow in temporary directories, without sudo.

Only root identity/ownership checks, system paths and process-control commands are
substituted. Copying, signature verification, link checks, modes and rollback use
macOS's actual tools. Nothing accesses the system HAL directory or coreaudiod.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "Scripts/install-driver.sh").read_text()
UNINSTALL = (ROOT / "Scripts/uninstall-driver.sh").read_text()
FIXTURE = ROOT / "build/MacStereoFix.driver"
assert FIXTURE.is_dir(), "Run ./build.sh first"


def run_case(name, setup=None, environment=None, succeed=False, strict=False):
    with tempfile.TemporaryDirectory(prefix="msf-installer-") as temporary:
        base = Path(temporary)
        library = base / "Library"
        hal = library / "Audio/Plug-Ins/HAL"
        hal.mkdir(parents=True)
        destination = hal / "MacStereoFix.driver"
        destination.mkdir()
        (destination / "old-marker").write_text("previous driver")
        source = base / "App with 'quotes' $() `literal` and spaces.driver"
        shutil.copytree(FIXTURE, source)
        # Keep the rejection test meaningful even when release.sh built with a
        # real Developer ID. Only this disposable fixture is re-signed.
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(source)],
                       check=True, capture_output=True)
        tools = base / "tools"
        tools.mkdir()
        wrappers = {
            "/usr/sbin/chown": "exit 0",
            "/usr/bin/pgrep": 'exit "${MSF_TEST_PGREP_EXIT:-1}"',
            "/usr/bin/killall": 'exit "${MSF_TEST_KILL_EXIT:-0}"',
            "/bin/mv": '''if [[ ${MSF_TEST_MOVE_FAIL:-0} == 1 && "$1" == */driver ]]; then exit 73; fi
exec /bin/mv "$@"''',
            "/usr/bin/ditto": '''if [[ ${MSF_TEST_COPY_FAIL:-0} == 1 ]]; then exit 73; fi
/usr/bin/ditto "$@"
result=$?
if [[ $result == 0 && ${MSF_TEST_MUTATE_SOURCE:-0} == 1 ]]; then
    /bin/chmod u+w "${@: -2:1}/Contents/MacOS/MacStereoFix"
    /usr/bin/printf 'tampered after copy' > "${@: -2:1}/Contents/MacOS/MacStereoFix"
fi
exit "$result"''',
        }
        for index, (command, body) in enumerate(wrappers.items()):
            wrapper = tools / str(index)
            wrapper.write_text("#!/bin/bash\n" + body + "\n")
            wrapper.chmod(0o755)
            wrappers[command] = str(wrapper)
        def sandboxed(text):
            text = text.replace("/Library", str(library))
            text = text.replace("$EUID -eq 0", f"$EUID -eq {os.geteuid()}")
            text = text.replace('$(/usr/bin/stat -f %u "$directory") == 0',
                                f'$(/usr/bin/stat -f %u "$directory") == {os.geteuid()}')
            for command, replacement in wrappers.items():
                text = text.replace(command, replacement)
            return text
        script = base / "install.sh"
        script.write_text(sandboxed(SCRIPT))
        if setup:
            setup(base, source, destination, hal)
        requirement = ('identifier "com.macstereofix.driver" and anchor apple generic and '
                       'certificate leaf[subject.OU] = "MD83L42DNL"') if strict else '--allow-adhoc'
        result = subprocess.run(["/bin/bash", str(script), str(source), requirement],
            capture_output=True, text=True, env={**os.environ, **(environment or {})}, timeout=20)
        assert (result.returncode == 0) == succeed, (name, result.returncode, result.stderr)
        if succeed:
            assert not (destination / "old-marker").exists()
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(destination)], check=True)
            for item in destination.rglob("*"):
                assert not item.is_symlink() and item.stat().st_mode & 0o022 == 0
            removal = base / "uninstall.sh"
            removal.write_text(sandboxed(UNINSTALL))
            subprocess.run(["/bin/bash", str(removal)], check=True, timeout=10)
            assert not destination.exists()
        elif name == "restart failure is reported":
            assert (destination / "Contents/MacOS/MacStereoFix").exists()
        elif name != "destination link is refused":
            assert (destination / "old-marker").read_text() == "previous driver"
        assert not list((library / "Audio").glob(".MacStereoFix.*")), "Staging directory leaked"
        print(f"Installer: {name} passed")


run_case("successful staged install and uninstall", succeed=True)
run_case("copy failure preserves existing driver", environment={"MSF_TEST_COPY_FAIL": "1"})
run_case("replacement failure rolls back", environment={"MSF_TEST_MOVE_FAIL": "1"})
run_case("source changes after copy cannot change installed payload",
         environment={"MSF_TEST_MUTATE_SOURCE": "1"}, succeed=True)
run_case("invalid signature preserves existing driver",
         setup=lambda b, s, d, h: (s / "Contents/MacOS/MacStereoFix").write_bytes(b"tampered"))
run_case("unsigned developer build rejected by distribution requirement", strict=True)
run_case("nested symlinks are refused",
         setup=lambda b, s, d, h: (s / "Contents/Resources/link").symlink_to("/etc/passwd"))
run_case("writable HAL directory is refused", setup=lambda b, s, d, h: h.chmod(0o777))
run_case("directory ACLs are refused", setup=lambda b, s, d, h: subprocess.run(
    ["/bin/chmod", "+a", "everyone allow add_file", str(h)], check=True))
run_case("restart failure is reported", environment={"MSF_TEST_PGREP_EXIT": "0", "MSF_TEST_KILL_EXIT": "1"})


def destination_link(base, source, destination, hal):
    shutil.rmtree(destination)
    victim = base / "untouched"
    victim.mkdir()
    (victim / "keep").write_text("keep")
    destination.symlink_to(victim)
run_case("destination link is refused", setup=destination_link)
