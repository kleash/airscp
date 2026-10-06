---
title: Limit the speed
parent: Transfers & queue
nav_order: 2
---

# Limit the speed

Big transfers can fill a slow or shared connection. A speed limit leaves room for everything else.

## Steps

1. In the Transfers list, click **Speed** (it shows the limit now, for example **Speed: Unlimited**).
2. Choose **1 MB/s**, **5 MB/s**, **10 MB/s** or **50 MB/s**. **Unlimited** is the default.

{% include shot.html name="transfers" alt="The Speed menu set to 5 MB/s above the Transfers list" %}

## Tips

- The limit applies to every host's transfers that start from then on. Transfers that are running keep their speed.
- Large files copy at scp's full speed when there is no limit.
