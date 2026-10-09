import sys
from pathlib import Path

PKG = Path(__file__).resolve().parents[2]  # observability/extras/content/
for sub in ("tools/onboarding",):
    sys.path.insert(0, str(PKG / sub))
