<!-- Copyright (c) 2026 Manicode Worldwide, Inc. Proprietary and confidential. -->

# Manicode Installer

One command that sets up Claude Code in a repo to start every chat with the Manicode prompts for the repo's stack.

## Install

Run from the root of the repo:

```bash
curl -fsSL https://raw.githubusercontent.com/manicode/install/main/install.sh | bash
```

It asks for your Manicode API key. To skip the prompt, export `MANICODE_REGISTRY_API_KEY` first.

It writes:

- `.claude/settings.json`: the `manicode` marketplace, `forge@manicode` enabled, and a hook that installs the plugin in each teammate's first chat.
- `.gitignore`: `.claude/settings.local.json`, unless it's already ignored.
- `.claude/settings.local.json`: your API key. Not checked in.

Check in the first two. Re-running it is safe.

Each teammate can run the command to save their API key.

## Updates

The plugin updates itself (`autoUpdate` in the marketplace entry). To update by hand instead, delete `autoUpdate` before checking in. To pin a version, add a `"ref"` branch or tag to the marketplace source, or point the source at your own mirror.

## Opting out

To turn forge off on one machine, add this to the repo's `.claude/settings.local.json`:

```json
{
  "enabledPlugins": {
    "forge@manicode": false
  }
}
```

## Uninstall

1. Remove from the repo's `.claude/settings.json`: `extraKnownMarketplaces.manicode`, `enabledPlugins["forge@manicode"]`, and the `SessionStart` entry whose command adds `manicode/external-claude-code-plugins`.
2. On each machine: `claude plugin uninstall forge@manicode --scope local`, and remove `MANICODE_REGISTRY_API_KEY` from `.claude/settings.local.json`.
