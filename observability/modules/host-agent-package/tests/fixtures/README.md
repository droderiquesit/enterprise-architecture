Test fixtures: fake dsv-fetch release files (NOT binaries: tiny shell scripts implementing `install`) with a matching SHA256SUMS (`dsv-fetch/`) and a tampered
copy (`dsv-fetch-bad/`, linux-amd64 does not match its checksum). Used by tests/package.tftest.hcl only.
