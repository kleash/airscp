---
title: Pause and resume transfers
parent: Transfers & queue
nav_order: 4
---

# Pause and resume transfers

Pause a transfer to free the connection for something else, and resume it later. A single file continues where it
stopped.

## Steps

1. In the Transfers list, right-click a transfer and choose **Pause**. Select several transfers to pause them together.
2. To go on, right-click it and choose **Resume**.

To pause or resume every transfer at once, click **Pause All** or **Resume All** above the list.

{% include shot.html name="transfers" alt="The Transfers list: one upload running, one paused, one verified" %}

## Tips

- A paused transfer waits until you resume it, even when the connection drops and comes back.
- Single files continue where they stopped. Folders, archives and copies between two servers start again.
- While AirSCP reconnects to the server by itself, **Resume** waits: resume once the connection is back.
- AirSCP can't tell whether a file changed while its transfer was paused. Resume only a file that stayed the same, or
  turn on **Verify transfers with SHA-256** in Settings to check the copy.
- **Cancel** a paused transfer to throw away the part that was copied. Disconnecting and quitting do that too, and
  AirSCP asks first.
- Paused transfers don't keep your Mac awake, and the Dock icon doesn't count them.
