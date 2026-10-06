---
title: Tunnels
nav_order: 10
---

# Open a tunnel (port forwarding)

A tunnel opens a port on your Mac that leads through the server: to the server itself, or to another machine only the
server can reach, such as a database or an internal web page. Or the other way round. It goes through the host's
connection, so nothing else needs to be open.

## Steps

1. Connect to the server and click the **Tunnels** tab.
2. Click **Add Tunnel…**.
3. Choose the type:
   - **Local**: open a port on this Mac. Connections to it go through the server, to the server itself or to another
     machine the server can reach (ssh `-L`).
   - **Remote**: open a port on the server. Connections to it come back through the tunnel, to this Mac or to another
     machine your Mac can reach (ssh `-R`).
   - **SOCKS proxy**: use a port on this Mac as a proxy for your apps. Their traffic leaves from the server (ssh `-D`).
4. Fill in the sentence: the port to open, where it leads (**The server itself**, or **Another machine the server can
   reach** and its name), and the port there. The second port is the same as the first until you change it.
5. Check the line under it. It shows the whole route, for example
   `localhost:8080 on this Mac → web-01 → localhost:80 on web-01 (the server itself)`.
6. Click **Save**, then switch the tunnel on in the list.

{% include shot.html name="tunnel-editor" alt="The tunnel sheet: open port 8080 on this Mac, through web-01, to the server itself, port 80, with the route under it" %}

{% include shot.html name="tunnels" alt="The Tunnels tab with three saved tunnels, each with its route and its switch" %}

## Examples

| You want | Type | Open port | To | Port there |
|---|---|---|---|---|
| The server's own web admin page | Local | `8080` on this Mac | The server itself | `80` |
| A database the server can reach | Local | `15432` on this Mac | Another machine: `db-01.internal` | `5432` |
| Let the server reach a dev server on your Mac | Remote | `3000` on the server | This Mac | `3000` |
| Browse as if you were in the server's network | SOCKS proxy | `1080` on this Mac | | |

With the first example on, open `http://localhost:8080` in your browser.

## Tips

- **The server itself** is `localhost` as the server sees it. The server also looks up the name you type for
  **Another machine**, so use a name or address the server knows.
- For **Remote**, **This Mac** is your Mac itself. Other machines can use the server's port only if the server's SSH
  settings allow it (`GatewayPorts`).
- Ports below 1024 on this Mac need administrator rights: use 1024 and above.
- Your Mac's end listens on 127.0.0.1 only, so other computers can't use your tunnel.
- All tunnels go off when the connection ends. When AirSCP reconnects by itself, it switches on again the ones that
  were on; after you reconnect, switch them on yourself.
- A tunnel can be edited only while it is off.

## If something goes wrong

- **“The port … is already in use on this Mac”**: another program or tunnel listens on it. Choose another port.
