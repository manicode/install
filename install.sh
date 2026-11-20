#!/usr/bin/env bash
# Copyright (c) 2026 Manicode Worldwide, Inc. Proprietary and confidential.

# Installs forge in the repo it runs from; see README.md.
#
#   curl -fsSL https://raw.githubusercontent.com/manicode/install/main/install.sh | bash
#
# npm run build inlines each @inline file, bundled, into installer/dist/; this
# source file doesn't run on its own. The settings are written directly, not
# with `claude plugin marketplace add --scope project`, because the CLI can't
# write the bootstrap hook or the API key.

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

# The forge command goes where Claude Code's own installer puts claude. A
# forge whose second line isn't the marker belongs to another tool and is
# left alone. Nothing here stops the install.
CLI_DIR="$HOME/.local/bin"
CLI_PATH="$CLI_DIR/forge"
CLI_MARKER="// Installed by the Manicode forge installer."

write_cli() {
  mkdir -p "$CLI_DIR" &&
    {
      printf '#!/usr/bin/env node\n%s\n' "$CLI_MARKER"
      cat <<'FORGE_CLI'
// Copyright (c) 2026 Manicode Worldwide, Inc. Proprietary and confidential.

// cli/forge.js
var VERSION = true ? "0.8.0" : "dev";
var USAGE = `forge: Manicode prompts for Claude Code

Usage: forge [options]

Options:
  -h, --help     Show this help
  -v, --version  Show the forge version
`;
function main() {
  const [arg] = process.argv.slice(2);
  switch (arg) {
    case void 0:
    case "-h":
    case "--help":
      process.stdout.write(USAGE);
      return;
    case "-v":
    case "--version":
      console.log(`forge ${VERSION}`);
      return;
    default:
      console.error(`forge: unknown argument: ${arg}`);
      process.stderr.write(USAGE);
      process.exitCode = 1;
  }
}
main();
FORGE_CLI
    } >"$CLI_PATH" &&
    chmod 755 "$CLI_PATH"
}

install_cli() {
  if [ -e "$CLI_PATH" ] && [ "$(sed -n 2p "$CLI_PATH" 2>/dev/null)" != "$CLI_MARKER" ]; then
    echo "forge install: ~/.local/bin/forge belongs to another tool; forge command not installed" >&2
    return
  fi
  local error
  if ! error="$(write_cli 2>&1)"; then
    echo "forge install: forge command not installed: ${error:-could not write $CLI_PATH}" >&2
    return
  fi
  echo "forge install: installed the forge command to ~/.local/bin/forge"
  case ":$PATH:" in
    *":$CLI_DIR:"*) ;;
    *) echo "forge install: ~/.local/bin is not on your PATH; add this line to your shell's startup file, then open a new terminal: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
  esac
}

install_cli

MANICODE_REGISTRY_API_KEY="$key" node - <<'NODE'
// installer/write-claude-settings.js
var { existsSync, mkdirSync, readFileSync, writeFileSync } = require("node:fs");
var { join } = require("node:path");
var MARKETPLACE_REPO = "manicode/external-claude-code-plugins";
var MARKETPLACE_NAME = "manicode";
var PLUGIN_ID = "forge@manicode";
var API_KEY_VAR = "MANICODE_REGISTRY_API_KEY";
var MARKETPLACE_ENTRY = {
  source: { source: "github", repo: MARKETPLACE_REPO },
  autoUpdate: true
};
var BOOTSTRAP_COMMAND = `cd "\${CLAUDE_PROJECT_DIR:-.}" && grep -qs ${PLUGIN_ID} .claude/settings.local.json || { claude plugin marketplace add ${MARKETPLACE_REPO} --scope local 1>&2; claude plugin install ${PLUGIN_ID} --scope local 1>&2; d="$(ls -d "$HOME"/.claude/plugins/cache/${MARKETPLACE_NAME}/forge/*/ 2>/dev/null | sort | tail -n 1)"; [ -n "$d" ] && node "\${d}hooks/load-prompts.js"; } || true`;
var BOOTSTRAP_HOOK_ENTRY = {
  matcher: "startup|clear|compact",
  hooks: [{ type: "command", command: BOOTSTRAP_COMMAND }]
};
function isForgeBootstrap(entry) {
  return (entry.hooks ?? []).some(
    (hook) => hook.command?.includes(`marketplace add ${MARKETPLACE_REPO}`)
  );
}
var SETTINGS_DIR = join(process.cwd(), ".claude");
var PROJECT_SETTINGS_FILE = ".claude/settings.json";
var LOCAL_SETTINGS_FILE = ".claude/settings.local.json";
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
    fail(`${file} is not valid JSON \u2014 fix it and re-run; nothing was written`);
  }
  if (typeof settings !== "object" || settings === null || Array.isArray(settings)) {
    fail(`${file} is not a JSON object \u2014 fix it and re-run; nothing was written`);
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
function projectSettingsWithForge(settings) {
  const sessionStart = settings.hooks?.SessionStart ?? [];
  const bootstraps = sessionStart.filter(isForgeBootstrap);
  const bootstrapCurrent = bootstraps.length === 1 && sameJson(bootstraps[0], BOOTSTRAP_HOOK_ENTRY);
  const alreadyInstalled = settings.enabledPlugins?.[PLUGIN_ID] === true && sameJson(settings.extraKnownMarketplaces?.[MARKETPLACE_NAME], MARKETPLACE_ENTRY) && bootstrapCurrent;
  if (alreadyInstalled) return null;
  const updated = {
    ...settings,
    extraKnownMarketplaces: {
      ...settings.extraKnownMarketplaces,
      [MARKETPLACE_NAME]: MARKETPLACE_ENTRY
    },
    enabledPlugins: { ...settings.enabledPlugins, [PLUGIN_ID]: true }
  };
  if (!bootstrapCurrent) {
    const nonForgeEntries = sessionStart.filter((entry) => !isForgeBootstrap(entry));
    updated.hooks = { ...settings.hooks, SessionStart: [...nonForgeEntries, BOOTSTRAP_HOOK_ENTRY] };
  }
  return updated;
}
function localSettingsWithKey(localSettings, key) {
  if (localSettings.env?.[API_KEY_VAR] === key) return null;
  return { ...localSettings, env: { ...localSettings.env, [API_KEY_VAR]: key } };
}
function main() {
  const projectUpdate = projectSettingsWithForge(readSettings(PROJECT_SETTINGS_FILE));
  const localUpdate = localSettingsWithKey(readSettings(LOCAL_SETTINGS_FILE), process.env[API_KEY_VAR]);
  if (projectUpdate) {
    writeSettings(PROJECT_SETTINGS_FILE, projectUpdate);
    console.log(`forge install: wrote ${PROJECT_SETTINGS_FILE}`);
  } else {
    console.log(`forge install: already installed \u2014 ${PROJECT_SETTINGS_FILE} is up to date`);
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

# Claude Code reads rule files before SessionStart hooks run, so the hook's
# first write would only reach the second chat.
MANICODE_REGISTRY_API_KEY="$key" node - <<'NODE'
var __getOwnPropNames = Object.getOwnPropertyNames;
var __commonJS = (cb, mod) => function __require() {
  try {
    return mod || (0, cb[__getOwnPropNames(cb)[0]])((mod = { exports: {} }).exports, mod), mod.exports;
  } catch (e) {
    throw mod = 0, e;
  }
};

// list-files.js
var require_list_files = __commonJS({
  "list-files.js"(exports2, module2) {
    var { execFileSync } = require("child_process");
    function listFiles(root) {
      const out = execFileSync(
        "git",
        ["ls-files", "--cached", "--others", "--exclude-standard"],
        { cwd: root, encoding: "utf8" }
      );
      return out.split("\n").filter(Boolean);
    }
    module2.exports = { listFiles };
  }
});

// detect-language.js
var require_detect_language = __commonJS({
  "detect-language.js"(exports2, module2) {
    var { extname } = require("path");
    var { listFiles } = require_list_files();
    var LANGUAGE_BY_EXT = {
      ".js": "javascript",
      ".jsx": "javascript",
      ".mjs": "javascript",
      ".cjs": "javascript"
    };
    function detectLanguages(root) {
      const found = /* @__PURE__ */ new Set();
      for (const file of listFiles(root)) {
        const lang = LANGUAGE_BY_EXT[extname(file)];
        if (lang) found.add(lang);
      }
      return [...found].sort();
    }
    module2.exports = { detectLanguages };
  }
});

// stack-detection/js-technologies.js
var require_js_technologies = __commonJS({
  "stack-detection/js-technologies.js"(exports2, module2) {
    var STACK_GROUP = "js";
    var JAVASCRIPT_VERSION = "ES2026";
    var PACKAGE_TECHNOLOGIES = [
      { technology: "react", npmPackage: "react" },
      { technology: "nextjs", npmPackage: "next" },
      { technology: "express", npmPackage: "express" }
    ];
    module2.exports = { STACK_GROUP, JAVASCRIPT_VERSION, PACKAGE_TECHNOLOGIES };
  }
});

// detect-stack.js
var require_detect_stack = __commonJS({
  "detect-stack.js"(exports2, module2) {
    var { readFileSync } = require("fs");
    var { join } = require("path");
    var { detectLanguages } = require_detect_language();
    var {
      STACK_GROUP,
      JAVASCRIPT_VERSION,
      PACKAGE_TECHNOLOGIES
    } = require_js_technologies();
    function readJson(path) {
      try {
        return JSON.parse(readFileSync(path, "utf8"));
      } catch {
        return null;
      }
    }
    function lowestVersion(range) {
      if (typeof range !== "string") return null;
      const match = /^[\s^~>=v]*(\d+)(?:\.(\d+))?(?:\.(\d+))?/.exec(range);
      if (!match) return null;
      const [, major, minor = "0", patch = "0"] = match;
      return `${major}.${minor}.${patch}`;
    }
    function packageVersion(root, npmPackage, range, lockfile) {
      const installed = readJson(
        join(root, "node_modules", npmPackage, "package.json")
      );
      const locked = lockfile?.packages?.[`node_modules/${npmPackage}`];
      return installed?.version ?? locked?.version ?? lowestVersion(range);
    }
    function stackItem(technology, version) {
      return { group: STACK_GROUP, technology, version };
    }
    function detectStack(root) {
      const stack = [];
      if (detectLanguages(root).includes("javascript")) {
        stack.push(stackItem("javascript", JAVASCRIPT_VERSION));
      }
      const manifest = readJson(join(root, "package.json"));
      if (!manifest) return stack;
      stack.push(stackItem("nodejs", process.versions.node));
      const declared = { ...manifest.dependencies, ...manifest.devDependencies };
      const lockfile = readJson(join(root, "package-lock.json"));
      for (const { technology, npmPackage } of PACKAGE_TECHNOLOGIES) {
        if (!(npmPackage in declared)) continue;
        const version = packageVersion(
          root,
          npmPackage,
          declared[npmPackage],
          lockfile
        );
        if (version) stack.push(stackItem(technology, version));
      }
      return stack;
    }
    module2.exports = { detectStack };
  }
});

// state.js
var require_state = __commonJS({
  "state.js"(exports2, module2) {
    var { execFileSync } = require("child_process");
    var { writeFileSync, mkdirSync } = require("fs");
    var { join, dirname } = require("path");
    var { detectStack } = require_detect_stack();
    function repoRoot() {
      return execFileSync("git", ["rev-parse", "--show-toplevel"], {
        encoding: "utf8"
      }).trim();
    }
    function detectAndStore() {
      const root = repoRoot();
      const state = {
        stack: detectStack(root),
        detectedAt: (/* @__PURE__ */ new Date()).toISOString()
      };
      const file = join(root, ".forge", "state.json");
      mkdirSync(dirname(file), { recursive: true });
      writeFileSync(join(dirname(file), ".gitignore"), "*\n");
      writeFileSync(file, JSON.stringify(state, null, 2) + "\n");
      return state;
    }
    module2.exports = { detectAndStore, repoRoot };
  }
});

// fetch-prompts.js
var require_fetch_prompts = __commonJS({
  "fetch-prompts.js"(exports2, module2) {
    var API_KEY_VAR = "MANICODE_REGISTRY_API_KEY";
    var DEFAULT_REGISTRY_URL = "https://manicode-context-registry.fly.dev";
    async function fetchPrompts(stack) {
      if (stack.length === 0) return [];
      const baseUrl = process.env.MANICODE_REGISTRY_URL || DEFAULT_REGISTRY_URL;
      const apiKey = process.env[API_KEY_VAR];
      if (!apiKey) throw new Error(`${API_KEY_VAR} is not set`);
      let response;
      try {
        response = await fetch(new URL("/api/prompts", baseUrl), {
          method: "POST",
          headers: {
            Accept: "application/json",
            Authorization: `Bearer ${apiKey}`,
            "Content-Type": "application/json"
          },
          body: JSON.stringify({ stack }),
          signal: AbortSignal.timeout(5e3)
        });
      } catch (error) {
        throw new Error(`registry at ${baseUrl} not reachable: ${error.message}`, {
          cause: error
        });
      }
      if (response.status === 401) {
        throw new Error(`the registry rejected ${API_KEY_VAR}`);
      }
      if (!response.ok) {
        throw new Error(
          `registry at ${baseUrl} responded ${response.status} for /api/prompts`
        );
      }
      return response.json();
    }
    module2.exports = { fetchPrompts };
  }
});

// write-rule-files.js
var require_write_rule_files = __commonJS({
  "write-rule-files.js"(exports2, module2) {
    var {
      existsSync,
      mkdirSync,
      readdirSync,
      readFileSync,
      rmSync,
      writeFileSync
    } = require("fs");
    var { join } = require("path");
    var RULES_DIR = join(".claude", "rules", "forge");
    function writeRuleFiles(root, prompts) {
      const dir = join(root, RULES_DIR);
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, ".gitignore"), "*\n");
      const wanted = new Map(
        prompts.map(({ technology, text }) => [`${technology}.md`, text])
      );
      let changed = false;
      for (const [name, text] of wanted) {
        const file = join(dir, name);
        if (existsSync(file) && readFileSync(file, "utf8") === text) continue;
        writeFileSync(file, text);
        changed = true;
      }
      for (const name of readdirSync(dir)) {
        if (name.endsWith(".md") && !wanted.has(name)) {
          rmSync(join(dir, name));
          changed = true;
        }
      }
      return changed;
    }
    module2.exports = { writeRuleFiles };
  }
});

// sync-prompts.js
var require_sync_prompts = __commonJS({
  "sync-prompts.js"(exports2, module2) {
    var { detectAndStore, repoRoot } = require_state();
    var { fetchPrompts } = require_fetch_prompts();
    var { writeRuleFiles } = require_write_rule_files();
    async function syncPrompts2() {
      const prompts = await fetchPrompts(detectAndStore().stack);
      return writeRuleFiles(repoRoot(), prompts);
    }
    module2.exports = { syncPrompts: syncPrompts2 };
  }
});

// installer/write-prompts.js
var { syncPrompts } = require_sync_prompts();
syncPrompts().then(
  () => console.log("forge install: wrote the prompts to .claude/rules/forge/"),
  (error) => {
    const [reason] = error.message.split("\n");
    console.error(`forge install: prompts not written: ${reason}; they load at the next chat`);
  }
);
NODE

echo "Manicode prompts active in Claude Code"
