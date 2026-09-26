"""Verify the delivered image, including persistent Finder layout and app signing."""
import os
import subprocess
import sys
import tempfile
from ds_store import DSStore

with tempfile.TemporaryDirectory(prefix="eltransfer-verify-") as directory:
    mount = os.path.join(directory, "volume")
    subprocess.run(["hdiutil", "attach", sys.argv[1], "-mountpoint", mount, "-nobrowse", "-quiet"], check=True)
    try:
        with DSStore.open(os.path.join(mount, ".DS_Store"), "r") as store:
            assert store["ELTransfer.app"]["Iloc"] == (220, 252)
            assert store["Applications"]["Iloc"] == (600, 252)
            assert store["."]["icvp"]["iconSize"] == 112
            assert store["."]["icvp"]["backgroundType"] == 2
            assert store["."]["bwsp"]["WindowBounds"] == "{{100, 80}, {820, 660}}"
            for name in (".background.tiff", ".DS_Store", ".fseventsd"):
                x, y = store[name]["Iloc"]
                assert 56 <= x <= 764 and 56 <= y <= 480, (name, x, y)
        assert os.readlink(os.path.join(mount, "Applications")) == "/Applications"
        subprocess.run(["codesign", "--verify", "--deep", "--strict", os.path.join(mount, "ELTransfer.app")], check=True)
        print("Verified installer layout, Applications link, and app signature.")
    finally:
        subprocess.run(["hdiutil", "detach", mount, "-quiet"], check=True)
