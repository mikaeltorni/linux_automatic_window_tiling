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
