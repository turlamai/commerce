# Production package installation

Install a versioned source archive from this repository's GitHub Releases, using the standard Racket package manager. Download the archive, its `.CHECKSUM`, `SHA256SUMS` and `release.json` together; verify `sha256sum -c SHA256SUMS` before installation. `release.json` records the source commit and builder runtime. Racket also checks the archive's native SHA-1 package checksum; SHA-256 is the release integrity check.

Use a dedicated, versioned Racket installation for each deployed service. Install packages with `raco pkg install --installation --copy --auto --batch --no-docs --name commerce /verified/commerce-VERSION.zip`. Install the reviewed Permit release first for Commerce. Never use `--link`, a floating branch, a developer home directory, or `--force` to hide a package conflict. Do not reuse another application's package scopes. A service runs as an unprivileged OS account with `PLTUSERHOME` outside root's home, while its runtime/packages are root-owned and read-only.

Configuration and secrets belong under `/etc/<service>`; mutable data under `/var/lib/<service>`; persistent service units under `/etc/systemd/system`. Install a new version in a new release directory, verify its package table and imports, record all installed dependency sources/checksums, and only then switch the active symlink. Retain the previous runtime and a consistent database backup for rollback. Reverting executable code does not reverse a database migration; restore a tested matching database snapshot when required.

The package release workflow tests the actual archive, then refuses publication unless the tag matches package metadata and the exact commit has successful main CI. Publishing a library does not approve a merchant, enable checkout, validate a real payment, or finish a product's deployed acceptance. Existing release gates still apply.

Development source links remain supported for local contributors; they are not the production installation path.

[简体中文](production-install.zh-CN.md)

After installation, run `raco commerce --help` as the service account from a readable working directory. This exercises the installed command registration and executable entrypoint, not just module imports. The reusable CLI also supports the standard Racket module invocation `racket -l commerce/operator/cli -- --help`. Release 0.1.3 fixes collection-level registration missing from earlier multi-collection archives.
