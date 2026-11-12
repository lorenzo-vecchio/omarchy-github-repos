# GitHub Repos (shdw.github)

Omarchy bar widget that browses every GitHub repository the signed-in `gh`
account can see — personal plus organizations — and acts on them.

## Install

Requires [Omarchy](https://omarchy.org), an authenticated `gh`, `jq`, and
`git`.

```bash
omarchy plugin add https://github.com/lorenzo-vecchio/omarchy-github-repos.git --enable
```

Then add the widget to the bar if it is not placed yet:

```bash
omarchy bar put shdw.github --section right
```

To update later:

```bash
omarchy plugin update shdw.github
```

To remove it:

```bash
omarchy plugin remove shdw.github --yes
```

That disables the widget and deletes the plugin directory. If its entry is
still in the bar layout in `~/.config/omarchy/shell.json`, delete it there too.

## What it shows

- One tab per owner: **All**, **Personal**, then one tab for each organization.
- A filter box matching name, owner, and description.
- Per repository: open issues, open pull requests, last commit age, and the
  check status of the default branch HEAD (`passing`, `failing`, `pending`,
  `no checks`).
- Whether the repository already exists under the Projects folder (scanned
  up to three levels deep, matched by `origin` remote URL, with a unique
  directory-name fallback). The list is split in two sections: **Already
  cloned** (checkouts found on this machine) first, then **Not cloned**.

## Actions

| Row state | Buttons |
|---|---|
| Cloned | agent (robot glyph) · editor (`>_`) · show in Files |
| Not cloned | clone into `projectsDir` |

- **Agent** starts `omarchy-agent` in the project directory, so the default
  agent recorded in `~/.config/omarchy/defaults/agent` opens there.
- **Editor** runs `omarchy-launch-editor <path>`, using the editor recorded in
  `~/.local/state/omarchy/defaults/editor` (nvim when unset).
- **Clone** runs `gh repo clone <owner/name> <projectsDir>/<name>` in the
  background; the row shows a spinner, then the list refreshes.

Bar button: left = panel · middle = refresh · right = open Projects in Files.

## Settings

Stored inline in `~/.config/omarchy/shell.json` on the widget entry:

| Key | Default | Meaning |
|---|---|---|
| `projectsDir` | `~/Projects` | Where clones land and where local checkouts are detected |
| `refreshMinutes` | `5` | Re-read interval while the panel is open |
| `includeForks` | `true` | Show forks |

```bash
omarchy bar set shdw.github projectsDir '~/Code'
omarchy bar set shdw.github refreshMinutes 15
omarchy bar move shdw.github --section left
```

## IPC

```bash
omarchy-shell shdw.github refresh
omarchy-shell shdw.github clone lorenzo-vecchio/learn-rust
omarchy-shell shdw.github toggle
```

## Data path

`bin/gh-repos` produces one JSON snapshot:

1. `gh api user/repos?affiliation=owner,organization_member` for the list.
2. Batched GraphQL (`10` repositories per request, `6` in parallel) for issue
   counts, PR counts, last commit date, and `statusCheckRollup` state.
3. `git config remote.origin.url` for every `.git` found under the Projects
   folder to compute `localPath`.

Requires `gh` (authenticated), `jq`, and `git`. The panel still lists
repositories if the metadata call fails; it just shows zeros and a warning.
