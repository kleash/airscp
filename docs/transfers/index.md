---
title: Transfers & queue
nav_order: 5
has_children: true
---

# Transfers and the queue

Every upload and download goes into the **Transfers** list at the bottom of the window. Transfers run in the
background, so you keep browsing. Each host runs one transfer at a time; different hosts run at the same time.

{% include shot.html name="transfers" alt="The Transfers list: one upload running, one paused, one done and verified" %}

## What the list shows

Each row shows the host, the name, the way (up for uploads, down for downloads), the size, the progress, the status
and the speed. A copy between two servers shows both hosts, “A → B”.

## Steps

- **Cancel** one transfer: select it and click **Cancel**. **Cancel All** stops them all (AirSCP asks first).
- **Pause** a transfer: right-click it and choose **Pause**, later **Resume**. **Pause All** and **Resume All** do it for
  every transfer.
- **Retry** a failed transfer: select it and click **Retry**.
- **Remove** a row: select it and click **Remove**. **Clear Finished** removes all finished rows.
- **Check a copy**: right-click a finished transfer and choose **Verify with Checksum**.
- **See what went wrong**: right-click a row and choose **Show Details…**.
- **Find a download**: right-click it and choose **Show in Finder**.

## Pages

- [When the connection drops during a transfer](resume.md)
- [Limit the speed](speed-limit.md)
- [Download as one archive](download-as-archive.md)
- [Pause and resume transfers](pause-and-resume.md)
- [Check a copy with its checksum](verify-checksums.md)

## Tips

- The Dock icon shows how many transfers are waiting or running.
- While transfers run, your Mac doesn't go to sleep and doesn't slow AirSCP down.
- Quitting AirSCP while transfers run asks first.
- Hide or show the list: **View ▸ Hide Transfers**.
