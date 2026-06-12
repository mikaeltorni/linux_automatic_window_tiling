# Project Guidance

This repository owns the automatic same-application window tiling GNOME Shell
extension and its parameterized installer.

Keep the extension independent from the broader Linux hotkey setup. The
installer must accept the desired GNOME accelerator as an argument, install
idempotently for the target desktop user, and avoid hard-coded checkout paths.

After changing installed behavior, run tests, deploy the extension to the
current machine, and verify GNOME reports it as active.

Do not run `gnome-shell --replace` automatically. It can disrupt the current
desktop session and leave user extensions globally disabled. Deploy files and
settings safely, then ask for logout/login when a fresh Shell process is
required. Always verify `org.gnome.shell disable-user-extensions` remains
`false` and that previously enabled extensions are still active.

## Clean Installation Compatibility

All repository changes must remain compatible with a clean installation run
through `installation_scripts/install.sh` and this repository's `install.sh`.
Do not rely on packages, files, settings, or manual steps that exist only on
the current machine. Add every required dependency, asset, configuration
step, and migration to the installer so a fresh checkout can reproduce the
complete setup.

Keep installation steps idempotent and verify the clean-install path for every
change.
