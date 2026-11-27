import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "src"))

from gaoyanjiu.cli import main

if __name__ == "__main__":
    desktop_entry = os.name == "nt" and (
        not getattr(sys, "frozen", False) or Path(sys.executable).stem.casefold() == "gaoyanjiu"
    )
    raise SystemExit(main(desktop_entry=desktop_entry))
