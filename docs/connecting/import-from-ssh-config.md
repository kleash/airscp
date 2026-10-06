---
title: Import hosts from ~/.ssh/config
parent: Connecting
nav_order: 2
---

# Import hosts from ~/.ssh/config

Already use ssh in Terminal? AirSCP can make a host for each alias in your `~/.ssh/config`. ssh keeps reading their
settings from your config, so later changes there apply in AirSCP too.

## Steps

1. Choose **File ▸ Import from ~/.ssh/config…** (the welcome sheet has this button too).
2. AirSCP lists the aliases from the `Host` lines, with the user and address ssh makes of each one.
3. Tick the ones you want. Aliases that are in AirSCP already are greyed out.
4. Click **Import**.

{% include shot.html name="import-ssh-config" alt="The Import from ~/.ssh/config sheet with a list of aliases" %}

## Tips

- AirSCP also reads the files that your config's `Include` lines name.
- Patterns such as `Host *` or `Host *.example.com` are skipped: they aren't one server.
- AirSCP never changes your `~/.ssh/config`.

## If something goes wrong

- **“No hosts found in ~/.ssh/config”**: your config has no `Host` lines with plain names. Add a host with
  **File ▸ New Host…** instead.
