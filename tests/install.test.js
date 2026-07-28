const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const test = require("node:test");

const installerPath = path.resolve(__dirname, "../hooks/install.js");
const uninstallerPath = path.resolve(__dirname, "../hooks/uninstall.js");
const staleNode = "/opt/homebrew/Cellar/node/26.5.0/bin/node";

const runScript = (scriptPath, home) => {
  const script = [
    `require("node:child_process").execSync = () => {};`,
    `Object.defineProperty(process, "execPath", { value: process.env.MOCK_EXEC_PATH });`,
    `require(process.env.SCRIPT_PATH);`,
  ].join("\n");

  execFileSync(process.execPath, ["-e", script], {
    env: {
      ...process.env,
      HOME: home,
      SCRIPT_PATH: scriptPath,
      MOCK_EXEC_PATH: staleNode,
    },
    stdio: "pipe",
  });
};

const runInstaller = (home) => runScript(installerPath, home);
const runUninstaller = (home) => runScript(uninstallerPath, home);

const readSettings = (home) => {
  const settingsPath = path.join(home, ".claude", "settings.json");
  return JSON.parse(fs.readFileSync(settingsPath, "utf8"));
};

const statusBarCommands = (settings) => {
  return Object.values(settings.hooks)
    .flat()
    .flatMap((entry) => entry.hooks || [])
    .map((hook) => hook.command || "")
    .filter((command) => command.startsWith("node "));
};

const shellQuote = (value) => `'${value.replace(/'/g, `'\\''`)}'`;

test("installs portable, quoted hook commands and replaces stale hooks", (t) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "claude $`\"' status bar test-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));

  const claudeDir = path.join(home, ".claude");
  const settingsPath = path.join(claudeDir, "settings.json");
  const oldScript = path.join(claudeDir, "statusbar", "update.js");
  const unrelatedCommand = "echo keep-me";
  const original = {
    customSetting: true,
    hooks: {
      PreToolUse: [
        {
          matcher: "*",
          hooks: [
            { type: "command", command: `${staleNode} ${oldScript} pre` },
            { type: "command", command: unrelatedCommand },
            { type: "prompt" },
          ],
        },
      ],
      Notification: [{ matcher: "empty-entry" }],
    },
  };
  fs.mkdirSync(claudeDir, { recursive: true });
  fs.writeFileSync(settingsPath, JSON.stringify(original, null, 2));
  const oldAgentPlist = path.join(
    home,
    "Library",
    "LaunchAgents",
    "com.local.claudestatusbar.watcher.plist",
  );
  fs.mkdirSync(path.dirname(oldAgentPlist), { recursive: true });
  fs.writeFileSync(oldAgentPlist, "obsolete");

  runInstaller(home);

  const settings = readSettings(home);
  const commands = statusBarCommands(settings);
  const updatePath = path.join(claudeDir, "statusbar", "update.js");
  const lifecyclePath = path.join(claudeDir, "statusbar", "lifecycle.js");

  assert.equal(settings.customSetting, true);
  assert.equal(fs.existsSync(oldAgentPlist), false);
  assert.equal(commands.length, 8);
  assert.ok(commands.every((command) => command.startsWith("node ")));
  assert.ok(commands.every((command) => !command.includes(staleNode)));
  assert.ok(commands.every((command) => !command.includes(process.execPath)));
  assert.ok(commands.includes(`node ${shellQuote(updatePath)} pre`));
  assert.ok(commands.includes(`node ${shellQuote(lifecyclePath)} start`));

  const lifecycleEnd = commands.find((command) => command.endsWith(" end"));
  execFileSync("/bin/sh", ["-c", lifecycleEnd], {
    env: {
      ...process.env,
      HOME: home,
      PATH: `${path.dirname(process.execPath)}:/usr/bin:/bin`,
    },
    input: JSON.stringify({ session_id: "quoted-path-test" }),
    stdio: "pipe",
  });

  const allCommands = Object.values(settings.hooks)
    .flat()
    .flatMap((entry) => entry.hooks || [])
    .map((hook) => hook.command);
  assert.equal(allCommands.filter((command) => command === unrelatedCommand).length, 1);
  assert.equal(
    settings.hooks.PreToolUse.flatMap((entry) => entry.hooks).filter(
      (hook) => hook.type === "prompt",
    ).length,
    1,
  );
  assert.deepEqual(
    JSON.parse(fs.readFileSync(`${settingsPath}.bak-statusbar`, "utf8")),
    original,
  );

  const firstInstall = settings;
  runInstaller(home);
  assert.deepEqual(readSettings(home), firstInstall);

  runUninstaller(home);
  const uninstalled = readSettings(home);
  assert.equal(statusBarCommands(uninstalled).length, 0);
  assert.equal(uninstalled.customSetting, true);
  assert.equal(
    uninstalled.hooks.PreToolUse.flatMap((entry) => entry.hooks).filter(
      (hook) => hook.command === unrelatedCommand,
    ).length,
    1,
  );
});

test("reinstalling is idempotent", (t) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "claude status bar test-"));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));

  runInstaller(home);
  const first = readSettings(home);
  runInstaller(home);
  const second = readSettings(home);

  assert.deepEqual(second, first);
  assert.equal(statusBarCommands(second).length, 8);
});
