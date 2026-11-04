---
title: Transfers on iPhone and iPad
parent: iPhone and iPad
nav_order: 4
---

# Transfers on iPhone and iPad

Every copy goes to the **Transfers** tab. There you see how far each one is, pause it, or try it again. On an iPhone,
the copy that runs also shows just above the tabs: tap it to open **Transfers**.

<!-- picture: iphone-transfers; iPhone, portrait; Transfers: the speed chart and an upload at 42 % under Now, and two downloads under Done with Checksums match -->

## What the list shows

- **Now**: the copies that run, wait or are paused, with a chart of the speed.
- **Needs you**: the copies that failed, left some items out, or don't match the original.
- **Done**: the copies that finished.

Each row shows the name, the way it goes (for example **web-01 → iPhone**), how far it is, the speed and the time left.
**Checksums match** means AirSCP compared the copied file with the original (SHA-256): they are the same.

## Steps

Swipe left on a transfer, or touch and hold it:

- **Pause**, later **Resume**: a file goes on where it stopped; a folder starts again.
- **Cancel**: stops it and removes what was partly copied.
- **Retry**: runs it again. A file that was cut off goes on where it stopped.
- **Remove**: takes it off the list. **Clear Done** takes off every finished one.
- **Show Details**: says what went wrong, in the tools' own words.

## When you leave AirSCP

iOS stops apps that aren't on screen. So when a copy starts, AirSCP asks iOS to keep the copies going after you leave
it, and iOS shows their progress.

iOS can still stop them: when you stop them in its progress, or when it needs to. Then they pause, and keep what they
have copied. Back in AirSCP, **Transfers** says that iOS paused them. Tap **Resume All**: files go on where they
stopped.

For big copies, keep AirSCP open.

## Tips

- Each server copies one transfer at a time; different servers copy at the same time.
- When you come back to AirSCP, it checks each connection and connects again by itself if it was lost.
- The tray is at the top of **Transfers** too. See [Carry files with the tray](files.md#carry-files-with-the-tray).
