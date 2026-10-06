# GUI test tools

`ui` drives the Mac's GUI for AirSCP's GUI tests: clicks, drags, keys, typed text, menu choices and the accessibility
tree of any app; `ui shot` takes a screenshot scaled to points, so a pixel in the image is a point you can click.
The commands are listed at the top of `ui.swift`.

Setup, once per Mac:
1. `testenv/uidriver/build.sh` builds `testenv/.uidriver/ui` and `testenv/.uidriver/Porter Screenshot.app`.
2. System Settings ▸ Privacy & Security ▸ **Accessibility**: turn on the terminal app you run the tests from.
3. Run `testenv/.uidriver/ui shot /tmp/x.png` once; then in **Screen Recording** turn on "Porter Screenshot".
   Screenshots get their own small app so that the terminal doesn't need Screen Recording (which only takes effect
   after the terminal restarts). Rebuilding the app with `--force` changes its signature: grant it again. (It keeps
   its name from before the app under test was renamed AirSCP, so that its Screen Recording grant stays.)

Only one GUI test can run at a time: they share the screen, the mouse and the keyboard. Don't use the Mac meanwhile.

`smoke.sh` is a short real-screen check built on it (a throwaway AirSCP against the Docker lab: the real menu bar,
Quick Look, an Open panel and dark mode, with real screenshots in build/screen-smoke). The maintainer's self-hosted
runner runs it for `.github/workflows/lab.yml` (docs/dev/self-hosted-runner.md).
