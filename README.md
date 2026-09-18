# PRQueue

A small macOS menu bar app that shows where my open pull requests are sitting in
the merge queue, so I stop refreshing GitHub tabs all day.

This is an internal tool. It is built for one specific setup — GitHub repos that
use an `automerge` label and a queue bot that comments the position — and it is
public only because there is nothing secret in it. No support, no roadmap.

## What it shows

The menu bar title is a count: `3 ⏳  1 ❌` (queued, failed). Open it and you get
one line per PR, grouped by repo:

```
monorepo-typescript
❌ #8373
⏳ #8821  6/11
```

- `⏳` — the PR has the `automerge` label and is waiting in the queue. The
  number next to it (`6/11`) is its position, read from the queue bot's comment.
- `❌` — the PR had `automerge` removed today, i.e. it got kicked out.
- Click any line to open the PR on GitHub. That is the only interaction.
Two optional counts, both off by default, toggled under "Repos & PRs" in the popover:

- `✅` — your PRs merged today.
- `👀` — open PRs where someone requested a review from you by name. Requests
  that went to a whole team are not counted. It is a count only; the PRs are
  not listed.

## Watching other people's PRs

I also merge PRs I did not write. Under "Repos & PRs", paste a PR URL into the
second field and hit "Watch". Watched PRs are tracked by number rather than by
author, so they show up in the same `⏳` / `❌` lines and feed the same counts,
including `✅` when they merge. The repo does not have to be in the repo list.

The URL is trimmed down to the PR, so anything GitHub hands you works:
`.../pull/9285`, `.../pull/9285/files`, `.../pull/9285/commits/abc123`.

It polls every 5 minutes, and on launch, on opening the menu, and on Refresh.

## Requirements

- macOS with Swift installed (Xcode command line tools)
- [`gh`](https://cli.github.com) installed and logged in — the app shells out to
  `gh api graphql` and uses whatever account that is

## Build and run

```bash
./build.sh
open PRQueue.app
```

Add repos from the "Repos & PRs" section in the popover — paste a repo URL or an
`owner/name` slug. Paste a PR URL in the field below it to watch a single PR.

To start it at login, add `PRQueue.app` in System Settings → General → Login Items.
