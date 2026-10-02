# PRQueue

## Populating the lists from the command line

The app stores its lists in macOS user defaults (domain `local.prqueue`). It re-reads them on every refresh (every 5 min, or click Refresh).

```sh
defaults read local.prqueue                                            # show everything
defaults write local.prqueue repos -array-add monta-app/server         # add a repo (owner/name)
defaults write local.prqueue watched -array-add monta-app/server#1234  # watch a PR (owner/name#number)
defaults write local.prqueue repos -array monta-app/a monta-app/b      # replace the whole repo list
defaults delete local.prqueue watched                                   # clear watched PRs
```

Use the exact formats above. The UI accepts full URLs, `defaults` does not normalise them.

## Build

`./build.sh`, then `cp -R PRQueue.app /Applications/`. Only Command Line Tools are installed (no Xcode), so don't use `@State` (its macro plugin is missing); use an `ObservableObject`.
