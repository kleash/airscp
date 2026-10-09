---
title: Browse a server's folders
parent: Files
nav_order: 1
---

# Browse a server's folders

Move around a server's folders like in Finder.

## Steps

- **Open a folder**: double-click it, or select it and press <kbd>⌘↓</kbd> (**Go ▸ Open Selection**).
- **Go up**: the **↑** button, or <kbd>⌘↑</kbd> (**Go ▸ Enclosing Folder**).
- **Back and forward**: the arrow buttons, or <kbd>⌘[</kbd> and <kbd>⌘]</kbd>.
- **Home folder**: the house button, or <kbd>⇧⌘H</kbd>.
- **Type a path**: <kbd>⇧⌘G</kbd> (**Go ▸ Go to Folder…**). `~` means your home folder.
- **Click a folder in the path bar** under the buttons to jump there.
- **Filter**: type in **Filter by name** (or press <kbd>⌘F</kbd>) to show only matching names.
- **Hidden files**: the eye button, or <kbd>⇧⌘.</kbd>, shows names that start with a dot.
- **Refresh**: the circle arrow, or <kbd>⌘R</kbd>.

{% include shot.html name="files" alt="The server pane with its path bar, buttons and filter field" %}

## Columns and sorting

- Click a column heading to sort by it. Click again to reverse.
- Right-click the headings (or **View ▸ Columns**) to show or hide columns: size, date modified, permissions, owner,
  group and kind.
- **Owner** and **Group** show names, as **Get Info** does. Point at one to see its number (user ID or group ID).
  Servers that allow only file transfers (sftp) show the names without numbers.
- Folders show “—” as their size. **View ▸ Calculate Folder Sizes** (the **Σ** button) works them out. **Settings** can
  do it always.

## Favourites

- **Go ▸ Add to Favourites** keeps the server folder you see, for that host.
- **Go ▸ Favourites** lists them: choose one to go there, or **Remove** one.

## Tips

- The status line under each pane shows the number of items, your selection and its size, and the free space.
- A folder your account can't read shows an error, not an empty list.
- Large folders list fast: 50,000 items in about a second on most Linux servers.
