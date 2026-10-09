import sys
from pathlib import Path

PKG = Path(__file__).resolve().parents[2]  # observability/
for sub in ("tools/onboarding", "tools/verify", "tools/markers"):
    sys.path.insert(0, str(PKG / sub))
