# shade-torrent

A basic torrent downloader for macOS. Uses [libtorrent](https://libtorrent.org) for the actual torrenting underneath.

## Download

Grab the latest `.dmg` from [Releases](../../releases/latest).

> **Note:** The app is not notarized. After dragging it to Applications, run this once to bypass Gatekeeper:
> ```bash
> xattr -dr com.apple.quarantine /Applications/shade-torrent.app
> ```
