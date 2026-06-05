# Project Guidance

This repository owns the automatic same-application window tiling GNOME Shell
extension and its parameterized installer.

Keep the extension independent from the broader Linux hotkey setup. The
installer must accept the desired GNOME accelerator as an argument, install
idempotently for the target desktop user, and avoid hard-coded checkout paths.

After changing installed behavior, run tests, deploy the extension to the
current machine, and verify GNOME reports it as active.
