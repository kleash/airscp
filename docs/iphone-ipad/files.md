---
title: Files on iPhone and iPad
parent: iPhone and iPad
nav_order: 2
---

# Files on iPhone and iPad

The **Files** tab has two sides: an open server, and **On iPhone** (on an iPad, **On iPad**), which is AirSCP's own
folder on your device. You copy between them. An iPhone shows one side at a time; an iPad shows both, next to each
other.

<!-- picture: iphone-files; iPhone, portrait; Files: the switcher web-01 / On iPhone at the top, the path / › var › www, and the server's folders and files -->

## Move around

1. Open a server in **Servers**, then tap **Files**.
2. On an iPhone, tap the side you want to see at the top: the server's name or **On iPhone**.
3. Tap a folder to open it. Tap a folder in the path above the list to go back up to it.

- Pull the list down to read the folder again.
- **More** (…) ▸ **Show Hidden Files** shows the names that start with a dot.
- More than one server open? Tap the server's name left of the path, and choose another one.
- **More ▸ Show** chooses what this side shows: an open server, or **On iPhone**. Show a second server there to copy
  between two servers.

## Copy files

1. Swipe left on a file or folder.
2. Tap **Download** (from the server to your device), **Upload** (from your device to the server) or **Send** (from one
   server to another). It goes into the folder that the other side shows.

To copy several items: tap **More ▸ Select**, tap the items, then tap **Download**, **Upload** or **Send** in the bar at
the bottom. **Done** stops selecting. On an iPad, you can also drag items to the other side, or onto a folder there.

<!-- picture: iphone-files-select; iPhone, portrait; Select: three files selected, and the bar with Download, Add to Tray, Share, Zip and Delete -->

- When an item with the same name is there already, AirSCP asks once for all of them: **Replace**, **Keep Both** (the
  new ones get a number), **Skip** or **Cancel**. Between two servers, there is no **Keep Both**.
- The copy goes to [Transfers](transfers.md). A copied file shows **Checksums match** when it is the same as the
  original.
- Between two servers, the files go through your iPhone or iPad.

## Open and edit a file

- Tap a text file on a server to edit it (up to 4 MB). **Edit** shows the text in colours, **Changes** the lines you
  changed, **Info** the file's details. Tap **Save** to write it back.
- If someone changed the file on the server after you opened it, AirSCP asks before it saves: **Overwrite**, **Show
  Server Version** (copy what you need, then save again) or **Cancel**.
- **Go to Line** (at the top) goes to a line by its number. **Close** asks first if you didn't save.
- Tap a file **On iPhone** to see it.
- To open a server's picture, PDF or other file in another app: touch and hold it, tap **Share**, and choose the app.

<!-- picture: iphone-editor; iPhone, portrait; The editor: a shell script in colours, with Edit, Changes and Info at the top and Saved at 10:42 at the bottom -->

## Share, save and import

- **Share**: touch and hold a server's file, then tap **Share**. AirSCP downloads it first, then you choose: Mail,
  Messages, AirDrop, **Save to Files** and more.
- **Save to Files**: touch and hold an item **On iPhone**, then tap **Save to Files**. A copy goes where you choose in
  the Files app.
- **Import from Files**: tap **More ▸ Import from Files** and choose files. On a server, they are uploaded into the
  folder shown. **On iPhone**, they are copied there.
- The Files app shows **On iPhone** too: **On My iPhone ▸ AirSCP**. Files you put there show in AirSCP.
- On an iPad, drag files from another app onto a side to upload them. Drag a server's file to another app: AirSCP
  downloads it first.

## Carry files with the tray

The tray collects files from several folders and servers, then takes them all to one place: a server's folder, the
Files app or another app.

1. Tap **More ▸ Select**, tap the items, then tap **Add to Tray**. Do it again in other folders, or on other servers.
2. Tap the tray at the top of **Files** or **Transfers**. A number shows how many items it holds.
3. Choose where they go:
   - **Send**, then a server: everything goes into the folder that server shows in **Files** (else its home folder).
   - **Save**: into the Files app.
   - **Share**: to another app.

Sent items leave the tray. Swipe left on an item to **Remove** it; **Empty** takes them all out.

<!-- picture: iphone-tray; iPhone, portrait; The tray: files from two servers and from the iPhone, with Send, Save and Share at the bottom -->

## New folder, rename, delete, zip

- **New Folder** (the folder with a plus, at the top): type a name and tap **Create**.
- Swipe left on an item: **Rename** or **Delete**. AirSCP asks before it deletes. This can't be undone.
- **Zip**: select items, then tap **Zip**. The server packs them into a `.zip` in the same folder. It works on a
  server's files, not on S3 storage or **On iPhone**.

## Find a file

Tap **Search**, type part of the name, then tap **Find “…” in** and the server. Tap a result to show it here, selected
in its folder. See [Search and run on several servers](search.md).

## Tips

- **More ▸ Monitor** shows the server's CPU, memory, disks and processes. See
  [Monitor on iPhone and iPad](monitor.md).
- On an iPad with a keyboard, <kbd>⌘C</kbd> and <kbd>⌘V</kbd> copy items between the sides, and more shortcuts work.
  See [Keyboard shortcuts](ipad.md#keyboard-shortcuts).
