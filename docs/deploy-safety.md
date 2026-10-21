# Deploy safety

Every SatuMeja repository deploys the same way:

```text
push to main → Jenkins: test, build, package → scp to the server → ssh deploy@server sudo -n <installer>
```

The CI user can run exactly one command as root, the installer for that
repository, and only without arguments ([deploy/example.sudoers](../deploy/example.sudoers)).
Each installer is installed by hand and never updates itself from a package,
so a push can change what is deployed but cannot change the rules it is
deployed under.

## API installer

[deploy/install-api.sh](../deploy/install-api.sh) refuses to go on unless:

* the package is a regular file owned by the deploy user, under a size limit;
* it contains exactly two regular files: an x86-64 ELF binary with the
  expected name, and `migrations.txt`, a non-empty list of three-digit numbers;
* the unit runs as the expected unprivileged user, so the service can never be
  quietly switched to root;
* **every migration in `migrations.txt` is recorded in `schema_migrations`.**

The last check exists because of how this kind of mistake fails. A binary that
reads a column that does not exist yet starts normally, answers `/readyz` with
200, and fails the first guest who orders. The build script writes the
migration list from `sql/` into every package, so a release that needs an
unapplied migration is refused with its number, and the running binary is
left alone.

Then it installs the binary owned by root (the service cannot overwrite its
own executable), keeps the previous one, restarts, and waits for `/readyz`.
If that fails, the previous binary comes back and the build turns red.

## The rollback bug testing found

The installer started as a copy of an older, already-deployed one, and the
copy was tested before use: 25 scenarios against real systemd and MariaDB
([tests/installer](../tests/installer/)). One scenario made `systemctl
restart` fail at the systemd level, through a unit dependency that does not
exist. The original code had two problems there:

1. It ran under `set -e`, so the failed `systemctl restart` ended the script
   before the rollback branch. The new binary stayed on disk.
2. Ignoring the error was not enough either. A restart that fails this way
   never stops the old process, so `/readyz` kept answering 200 from the
   **old** binary, and the installer reported success while the new,
   never-started binary waited for the next reboot.

The fix checks the restart result on its own (`restarted && ready`), and
restores the previous binary with `cp` to a temporary name plus `mv`, which
replaces the directory entry instead of writing into a running executable
("Text file busy"). Both scenarios are in the suite.

## Web installer

[deploy/install-web.sh](../deploy/install-web.sh) treats the package as
untrusted data:

* only regular files and directories, only a `browser/` folder, no owners or
  modes from the archive, and nothing from it is ever executed;
* every file must match its SHA-1 in `ngsw.json`. For the merchant console
  that is the real Angular service-worker manifest; the other apps generate
  one only as a checksum list;
* `index.html` must reference exactly one `main-*.js` and one `styles-*.css`
  that exist.

Each release goes into its own folder, and the nginx root is a symlink
switched with one `rename(2)`. The installer then fetches `index.html` and
`main-*.js` through the local nginx with the site's `Host` header, and points
the symlink back if either fails. The previous release's lazy chunks are
copied forward, so a browser that opened the app before the deploy can still
load the page it navigates to next. Uploaded menu photos live outside the
docroot, so a release switch never touches them.

The first Jenkins build of every site was checked against what was already
live: every JavaScript and CSS bundle had the same content hash, so the switch
to CI changed how the sites are deployed, not what they run.

## What CI never does

* **Run migrations.** A human applies them after a backup; CI only refuses to
  deploy around them.
* **Sign the Android app.** The release key never leaves the release
  machine; CI runs `flutter analyze` and the test suite only.
* **Flash firmware.** CI compiles all three firmwares, using an example
  device identity, so the binaries it produces could not be installed even
  by mistake.
