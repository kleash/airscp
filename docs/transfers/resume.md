---
title: When the connection drops during a transfer
parent: Transfers & queue
nav_order: 1
---

# When the connection drops during a transfer

If the connection is lost in the middle of a transfer, AirSCP keeps what was copied. After reconnecting, a single file
continues where it stopped instead of starting again.

## Steps

1. Wait: AirSCP reconnects by itself (see [Stay connected](../connecting/stay-connected.md)) and runs the transfers
   again.
2. Or select the failed transfer and click **Retry**.

{% include shot.html name="transfers" alt="The Transfers list with Retry and Clear Finished buttons" %}

## Tips

- Single files continue where they stopped. Folders and archive streams start again.
- While AirSCP reconnects to the server by itself, **Retry** waits: the cut-off transfers run again on their own once
  the connection is back.
- If the kept part is gone, or the file on the other side got shorter, the file is copied again from the start.
- AirSCP can't tell whether the source file changed between the tries. Retry only a file that stayed the same.
- **Remove**, **Clear Finished**, **Cancel All**, disconnecting and quitting throw the kept part away.
