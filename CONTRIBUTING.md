# Contributing to Blitz Neo

Bug reports, documentation fixes and focused pull requests are welcome. This is
the independently maintained AmoSystems fork of
[Blitz](https://github.com/blitzdotdev/blitz-mac). Open pull requests against
**`maintenance/auth-and-tooling`** in this repository, not the upstream project.

## Report a problem

Include the Blitz Neo version and build number, macOS version, Mac architecture,
the affected screen or CLI command, reproduction steps and expected behavior.
Distinguish a local test from an actual Apple upload or submission. A sanitized
error code and a small reproduction are more useful than an entire log archive.

Do not attach private keys, passwords, cookies, web sessions, `.env`, local Blitz
state, release journals or unredacted account/customer data. Redact screenshots
and logs before posting. Do not publish an exploitable security issue with live
credentials; use the contact information on [amosystems.org](https://amosystems.org/)
to arrange a private report.

## Develop and verify

Follow [README.md](README.md#build-and-test) for the build prerequisites and
[CLAUDE.md](CLAUDE.md) for source architecture. Keep the central
[Node/npm manifest](config/node-toolchain.json), submodule pins and dependency
locks intact unless changing those dependencies is the purpose of the pull request.

Use the existing regression tests for the behavior you change. With the locally
verified Xcode 27 compatibility build engine:

```bash
swift test --build-system native --jobs 4
BLITZ_SWIFT_BUILD_SYSTEM=native BLITZ_BUILD_JOBS=4 bash scripts/bundle.sh release
```

For ASC or protocol-adapter changes, also run:

```bash
bash scripts/test-asc-helper.sh
```

That script isolates authentication and uses mocked HTTP responses. Do not use
live Store mutations or real customer data as automated regression tests. The
scripts under `scripts/asc-api-tests/` are not the offline helper test suite.
For packaging/toolchain changes, use the relevant existing tests under `scripts/`
and the procedures in [docs/node-toolchain.md](docs/node-toolchain.md).

For UI changes, inspect the rendered app at normal and narrow widths, including
an open terminal, and report which configurations you checked. A successful build
does not prove a device interaction or an App Store submission succeeded.

## Keep changes reviewable

- Explain the concrete problem, resulting behavior and validation in the pull
  request. List any check you could not perform.
- Add regression coverage for state, identity, authentication and submission
  changes. Preserve exact app/platform/build selection and recovery of existing
  operations; do not bypass blocked validation or reset release journals.
- Keep generated builds, local credentials and test artifacts out of commits.
  Preserve license and attribution notices when modifying third-party code.
- Do not bump public versions, publish packages, enable paid CI or run a release
  as part of an ordinary contribution. Maintainers handle distribution separately.

Local checks are the active validation route; this fork does not depend on paid
GitHub Actions. Contributions are made under the repository's
[Apache 2.0 license](LICENSE), with existing [attribution](NOTICE) retained.
