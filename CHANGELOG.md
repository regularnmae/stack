# Changelog

All notable changes to this stack are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use
annotated `vMAJOR.MINOR.PATCH` tags.

## [Unreleased]

## [1.0.0] - 2026-11-20

### Added

- Release tags, this changelog and the MIT license.
- A minimum host sizing table in the README.
- A table of contents for the README.
- Verdict files for the two database-dump producers, read by `monitor.sh` when
  a dump is missing or stale.
- A duplicate-tolerant wrapper for the distro's `audit-rules.service`.

### Changed

- CI now cancels superseded runs, bounds each job at 15 minutes, and proves the
  `stackctl` interpreter path with `python3 -S`.
- The quickstart pins `bootstrap.sh` to a tag and verifies its SHA256; a bare
  host clones the same tag. Other install and recovery snippets pin the tag too.
- The rollback runbook names release tags instead of an unspecified older commit.

### Fixed

- `services.toml` no longer carries doubled comment markers.
- The README's CI description names the real gates instead of “shellcheck +
  bash -n”.
- `audit-rules.service` no longer stays failed after a duplicate-only reload.

### Release

- `bootstrap.sh` SHA256 (the README quickstart pins it):
  `36a8087f084627085106b05dfefecf85a04698a946fc5074e0780db039fe2f31`.
