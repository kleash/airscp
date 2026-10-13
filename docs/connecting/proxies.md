---
title: Connect through a proxy
parent: Connecting
nav_order: 7
---

# Connect through a proxy

Some company networks reach the internet only through a proxy. AirSCP can send a host's connection through an HTTP
proxy (HTTP CONNECT) or a SOCKS5 proxy, with or without a user name and password. Most people need none.

## Steps

1. Choose **Host ▸ Proxies…** (or click **Proxies** at the bottom of the sidebar).
2. Click **Add Proxy…**. Choose its **Type** (**HTTP** or **SOCKS5**), then type its **Name**, **Address** and **Port**.
   Your network admin knows these.
3. If the proxy needs a login, type the **User name**. The password field appears then; leave it empty to be asked.
4. Click **Add**, then **Done**.
5. Edit the host (**Host ▸ Edit…**), click **Advanced**, and choose the proxy under **Proxy**.

{% include shot.html name="proxies" alt="The Proxies sheet with one proxy" %}

{% include shot.html name="proxy-editor" alt="The proxy sheet with name, address, port and user name" %}

## Tips

- A host that connects through a jump host uses the jump host's proxy: the proxy is only on the way to the jump
  host.
- AirSCP logs in to an HTTP proxy the way it asks: Basic, or Digest (MD5 or SHA-256). With Digest, your password never
  goes over the network.
- A **SOCKS5** proxy is often on port 1080, or is an `ssh -D` tunnel. With a user name, AirSCP logs in with it.
- **Copy ssh Command** works for a host behind a proxy without a login: the command reaches the proxy with macOS's
  `nc`.
- The sidebar shows **via proxy …** under a host that goes through a proxy.
- The proxy's password is kept in your Keychain. A password the proxy refuses is forgotten, so you are asked again.
- A proxy that hosts still use can't be removed.

## If something goes wrong

- **“The proxy rejected the user name or password”**: edit the proxy and check the user name; connect again to type
  the password.
- SOCKS4 proxies aren't supported: only HTTP proxies that allow CONNECT, and SOCKS5 proxies.
