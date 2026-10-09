import sys
from pathlib import Path

HERE = Path(__file__).resolve().parents[1] / "changeset"
ROOT = Path(__file__).resolve().parents[2]
for p in (str(ROOT), str(HERE)):
    if p not in sys.path:
        sys.path.insert(0, p)
