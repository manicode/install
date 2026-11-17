#!/usr/bin/env bash
# Copyright (c) 2026 Manicode Worldwide, Inc. Proprietary and confidential.

# Installs forge in the repo it runs from; see README.md.
#
#   curl -fsSL https://raw.githubusercontent.com/manicode/install/main/install.sh | bash
#
# npm run build inlines write-claude-settings.js at the @inline line, into
# installer/dist/; this source file doesn't run on its own. The settings are
# written directly, not with `claude plugin marketplace add --scope project`,
# because the CLI can't write the bootstrap hook or the API key.

set -euo pipefail

LOCAL_SETTINGS=.claude/settings.local.json

fail() {
  echo "forge install: $*" >&2
  exit 1
}

[ -e .git ] || fail "run this from the root of the git repo adopting forge"
command -v node >/dev/null 2>&1 || fail "node is required — forge's hook runs on node"

# The script itself arrives on stdin under `curl | bash`, so the prompt reads
# the terminal directly. CI never prompts.
key="${MANICODE_REGISTRY_API_KEY:-}"
if [ -z "$key" ] && [ -z "${CI:-}" ] && { : </dev/tty; } 2>/dev/null; then
  printf "Manicode API key (input hidden): " >/dev/tty
  IFS= read -rs key </dev/tty || true
  printf "\n" >/dev/tty
fi
[ -n "$key" ] ||
  fail "no API key — set MANICODE_REGISTRY_API_KEY, or run in a terminal to be asked for it; nothing was written"

MANICODE_REGISTRY_API_KEY="$key" node - <<'NODE'
// Copyright (c) 2026 Manicode Worldwide, Inc. Proprietary and confidential.

// Runs from the root of the repo adopting forge, with the API key in
// MANICODE_REGISTRY_API_KEY.

const { existsSync, mkdirSync, readFileSync, writeFileSync } = require("node:fs");
const { join } = require("node:path");

const MARKETPLACE_REPO = "manicode/external-claude-code-plugins";
const MARKETPLACE_NAME = "manicode";
const PLUGIN_ID = "forge@manicode";
const API_KEY_VAR = "MANICODE_REGISTRY_API_KEY";
// autoUpdate is deliberate: without it a security patch pushed to the plugin
// repo sits unseen in teammates' caches until a manual marketplace update.
// Orgs that prefer explicit updates delete the flag in review.
const MARKETPLACE_ENTRY = {
  source: { source: "github", repo: MARKETPLACE_REPO },
  autoUpdate: true,
};

// Claude Code doesn't install a checked-in plugin by itself, so this hook does:
// once per repo per machine, until forge@manicode appears in local settings
// (an explicit false opts out). It then loads prompts for that first chat.
// `|| true` keeps a failure from blocking session start.
const BOOTSTRAP_COMMAND =
  `cd "\${CLAUDE_PROJECT_DIR:-.}" && grep -qs ${PLUGIN_ID} .claude/settings.local.json || { ` +
  `claude plugin marketplace add ${MARKETPLACE_REPO} --scope local 1>&2; ` +
  `claude plugin install ${PLUGIN_ID} --scope local 1>&2; ` +
  `d="$(ls -d "$HOME"/.claude/plugins/cache/${MARKETPLACE_NAME}/forge/*/ 2>/dev/null | sort | tail -n 1)"; ` +
  `[ -n "$d" ] && node "\${d}hooks/load-prompts.js"; } || true`;
const BOOTSTRAP_HOOK_ENTRY = {
  matcher: "startup|clear|compact",
  hooks: [{ type: "command", command: BOOTSTRAP_COMMAND }],
};

// A SessionStart entry whose command adds this marketplace is a forge
// bootstrap, possibly written by an earlier version of this installer.
function isForgeBootstrap(entry) {
  return (entry.hooks ?? []).some((hook) =>
    hook.command?.includes(`marketplace add ${MARKETPLACE_REPO}`)
  );
}

const SETTINGS_DIR = join(process.cwd(), ".claude");
const PROJECT_SETTINGS_FILE = ".claude/settings.json";
const LOCAL_SETTINGS_FILE = ".claude/settings.local.json";

function fail(message) {
  console.error(`forge install: ${message}`);
  process.exit(1);
}

function readSettings(file) {
  const path = join(process.cwd(), file);
  if (!existsSync(path)) return {};
  let settings;
  try {
    settings = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    fail(`${file} is not valid JSON — fix it and re-run; nothing was written`);
  }
  if (typeof settings !== "object" || settings === null || Array.isArray(settings)) {
    fail(`${file} is not a JSON object — fix it and re-run; nothing was written`);
  }
  return settings;
}

function writeSettings(file, settings) {
  mkdirSync(SETTINGS_DIR, { recursive: true });
  writeFileSync(join(process.cwd(), file), JSON.stringify(settings, null, 2) + "\n");
}

function sameJson(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

// Returns the updated settings.json, or null when it is already current.
function projectSettingsWithForge(settings) {
  const sessionStart = settings.hooks?.SessionStart ?? [];
  const bootstraps = sessionStart.filter(isForgeBootstrap);
  const bootstrapCurrent = bootstraps.length === 1 && sameJson(bootstraps[0], BOOTSTRAP_HOOK_ENTRY);
  const alreadyInstalled =
    settings.enabledPlugins?.[PLUGIN_ID] === true &&
    sameJson(settings.extraKnownMarketplaces?.[MARKETPLACE_NAME], MARKETPLACE_ENTRY) &&
    bootstrapCurrent;
  if (alreadyInstalled) return null;

  const updated = {
    ...settings,
    extraKnownMarketplaces: {
      ...settings.extraKnownMarketplaces,
      [MARKETPLACE_NAME]: MARKETPLACE_ENTRY,
    },
    enabledPlugins: { ...settings.enabledPlugins, [PLUGIN_ID]: true },
  };
  if (!bootstrapCurrent) {
    const nonForgeEntries = sessionStart.filter((entry) => !isForgeBootstrap(entry));
    updated.hooks = { ...settings.hooks, SessionStart: [...nonForgeEntries, BOOTSTRAP_HOOK_ENTRY] };
  }
  return updated;
}

// Returns the updated settings.local.json, or null when the key is already saved.
function localSettingsWithKey(localSettings, key) {
  if (localSettings.env?.[API_KEY_VAR] === key) return null;
  return { ...localSettings, env: { ...localSettings.env, [API_KEY_VAR]: key } };
}

// Both files are read and checked before either is written, so a bad file
// leaves everything untouched.
function main() {
  const projectUpdate = projectSettingsWithForge(readSettings(PROJECT_SETTINGS_FILE));
  const localUpdate = localSettingsWithKey(readSettings(LOCAL_SETTINGS_FILE), process.env[API_KEY_VAR]);

  if (projectUpdate) {
    writeSettings(PROJECT_SETTINGS_FILE, projectUpdate);
    console.log(`forge install: wrote ${PROJECT_SETTINGS_FILE}`);
  } else {
    console.log(`forge install: already installed — ${PROJECT_SETTINGS_FILE} is up to date`);
  }
  if (localUpdate) {
    writeSettings(LOCAL_SETTINGS_FILE, localUpdate);
    console.log(`forge install: saved the API key to ${LOCAL_SETTINGS_FILE}`);
  }
}

main();
NODE

# The key file must never be committed. Ignore it in the checked-in .gitignore,
# so every clone is covered, unless a checked-in .gitignore rule already does.
# Global and info/exclude rules don't count: they cover this machine only.
rule="$(git -c core.excludesFile=/dev/null check-ignore -v "$LOCAL_SETTINGS" 2>/dev/null || true)"
rule_source="${rule%%:*}"
rule_pattern="$(printf '%s' "$rule" | cut -d: -f3 | cut -f1)"
if [ "${rule_source##*/}" != .gitignore ] || [ "${rule_pattern#!}" != "$rule_pattern" ]; then
  if ! grep -qxF "$LOCAL_SETTINGS" .gitignore 2>/dev/null; then
    if [ -s .gitignore ] && [ -n "$(tail -c 1 .gitignore)" ]; then echo >>.gitignore; fi
    echo "$LOCAL_SETTINGS" >>.gitignore
    echo "forge install: added $LOCAL_SETTINGS to .gitignore"
  fi
fi

echo "Manicode prompts active in Claude Code"
