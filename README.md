# SpokenShelf

SpokenShelf is a native Omarchy shell player for [Audiobookshelf](https://www.audiobookshelf.org/). Browse and search your library, resume in-progress books, stream or download audio, and keep listening progress synchronized with your server.

## Features

- Continue Listening and Recently Added home shelves.
- Searchable library with cover artwork and per-book progress.
- Server streaming with automatic resume.
- Resumable, quota-limited downloads and offline playback.
- On-device deletion for completed and partial downloads.
- Offline progress reconciliation after reconnecting.
- Book and chapter seek controls with elapsed and remaining time.
- Selectable audio output with automatic system-default tracking.
- Playback volume and 30-second skip controls.
- MPRIS integration for keyboard media keys and desktop media controls.
- API-token or local username/password authentication.

## Requirements

- Omarchy with the plugin-capable shell.
- An Audiobookshelf server. SpokenShelf is tested against Audiobookshelf 2.36.1.
- Python 3, `zenity`, and `secret-tool` (from `libsecret`).
- Optional: the Python `dbus-next` package for MPRIS media-key and desktop media controls.
- Qt Multimedia support for the audio formats stored by your server.

Install missing command-line dependencies with:

```sh
omarchy pkg add python zenity libsecret python-dbus-next
```

SpokenShelf does not install packages, request elevated privileges, or modify system configuration.
Missing connection-form and MPRIS dependencies are reported inside the SpokenShelf panel.

## Install

```sh
omarchy plugin add https://github.com/jxsparrou/spokenshelf.git --enable
```

Add the widget to the bar if it is not inserted automatically:

```sh
omarchy bar put io.github.jxsparrou.spokenshelf --section right
```

### Replacing OmaShelf

If you installed the project before it was renamed, remove the old plugin before installing SpokenShelf:

```sh
omarchy plugin remove io.github.jxsparrou.omashelf --yes
omarchy plugin add https://github.com/jxsparrou/spokenshelf.git --enable --yes
omarchy bar put io.github.jxsparrou.spokenshelf --section right
```

The rename does not remove saved credentials, downloads, or queued listening progress.

## Update

Update the Git-managed plugin and restart the shell so QML changes are loaded reliably:

```sh
omarchy plugin update io.github.jxsparrou.spokenshelf --yes
omarchy restart shell
```

## Connect

Open SpokenShelf from the status bar and enter your Audiobookshelf server URL. Then use either:

- Your Audiobookshelf username and password.
- An Audiobookshelf API token.

Username and password credentials are sent only to the configured server's `/login` endpoint and are never stored. Use HTTPS when signing in over a network; HTTP is supported for trusted local servers. The access token returned by login, or the API token you provide, is stored in the desktop keyring through `secret-tool`. The server URL is stored as non-secret local state.

## Usage

- **Home** shows books in progress and recently added books.
- **Library** lists all books and supports title, author, and series search.
- **Offline** lists downloaded books and active partial downloads. Use the trash action there to delete a download or cancel and remove a partial download.
- Selecting a downloaded book from any page prefers its local audio file.
- Progress refreshes from the server when the panel opens and before playback resumes. Downloaded books upload queued offline listening before applying server progress when connected.
- Resuming after at least 10 seconds paused rewinds playback by 5 seconds for context.
- **Playing** provides book and chapter seeking, transport controls, volume, source status, and downloads.
- Hardware play/pause keys work through MPRIS while SpokenShelf has a loaded book.
- Use **Log out** in the panel header to forget the current server credentials and connect to another server. Downloads are kept.

Downloads and queued offline sessions are stored under `~/.local/state/omarchy-audiobookshelf/`. The state directory is restricted to the current user. Each track is limited to 8 GiB and each book to 64 GiB. Downloads are not removed automatically.

## Remove

Remove the plugin:

```sh
omarchy plugin remove io.github.jxsparrou.spokenshelf
```

Optional: remove downloaded books and local state:

```sh
rm -rf ~/.local/state/omarchy-audiobookshelf
```

Optional: remove a saved token for a server:

```sh
secret-tool clear service omarchy-audiobookshelf server https://your-server.example
```

## Security And Privacy

- Tokens are stored in the desktop keyring, not in plugin files.
- Passwords are not persisted.
- Cover images communicate directly with the configured Audiobookshelf server. Authenticated API, login, download, and audio requests pass through the bundled Python transport.
- Cover artwork uses Audiobookshelf's unauthenticated item-cover endpoint; audio and API requests are authenticated.
- Qt Multimedia receives only a random-capability URL on an ephemeral `127.0.0.1` relay. The relay adds the bearer header upstream, accepts only same-server URLs and redirects, and keeps tokens out of media URLs, process arguments, files, and logs.
- Login responses are limited to 256 KiB, API responses to 8 MiB, and API request bodies to 1 MiB. Library pages and queued listening-session uploads are processed in bounded batches.
- Downloads use resumable partial files, reject unsafe paths and symbolic links, and enforce 8 GiB per-track and 64 GiB per-book storage limits while streaming.
- The local MPRIS bridge publishes the current title, author, cover URL, duration, position, playback state, and volume on the user's session D-Bus so desktop media controls can work.
- Download metadata and queued progress include library details and listening history and are stored in user-only local state files.

## Development

```sh
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" Service.qml BarWidget.qml BookRow.qml
python -m unittest discover -s tests -v
python -m py_compile transport.py mpris.py
```

Do not commit server URLs, API tokens, passwords, downloaded audio, state files, or keyring exports.

## License

MIT
