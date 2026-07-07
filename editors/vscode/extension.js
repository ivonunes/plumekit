const fs = require("fs");
const path = require("path");
const childProcess = require("child_process");
const vscode = require("vscode");
const { LanguageClient } = require("vscode-languageclient/node");

let client;
let outputChannel;

function activate(context) {
  outputChannel = vscode.window.createOutputChannel("Plume");
  context.subscriptions.push(outputChannel);

  startLanguageServer(context);

  context.subscriptions.push(vscode.commands.registerCommand("plume.restartLanguageServer", async () => {
    if (client) {
      await client.stop();
      client = undefined;
    }
    startLanguageServer(context);
  }));

  context.subscriptions.push(vscode.commands.registerCommand("plume.checkTheme", () => {
    const workspace = workspaceFolder();
    const command = resolveToolCommand(workspace);
    outputChannel.show(true);
    outputChannel.appendLine(`Running ${command.display} ${command.checkArgs.join(" ")}`);
    childProcess.execFile(command.path, command.checkArgs, { cwd: workspace }, (error, stdout, stderr) => {
      if (stdout) outputChannel.append(stdout);
      if (stderr) outputChannel.append(stderr);
      if (error) {
        showCommandError(command, "Plume check failed.");
      } else {
        vscode.window.showInformationMessage("Plume check passed.");
      }
    });
  }));

  // PlumeKit framework commands — run the CLI (preferring the ./plumekit wrapper) in
  // an integrated terminal.
  const frameworkCommands = {
    "plumekit.dev": ["dev"],
    "plumekit.serve": ["serve"],
    "plumekit.build": ["build"],
    "plumekit.deploy": ["deploy"],
    "plumekit.migrate": ["migrate"],
    "plumekit.routes": ["routes"],
    "plumekit.doctor": ["doctor"]
  };
  for (const id of Object.keys(frameworkCommands)) {
    context.subscriptions.push(
      vscode.commands.registerCommand(id, () => runPlumekit(frameworkCommands[id])));
  }
  context.subscriptions.push(vscode.commands.registerCommand("plumekit.generate", async () => {
    const kind = await vscode.window.showQuickPick(
      ["resource", "auth", "model", "controller", "migration", "view", "middleware", "job", "seeder"],
      { placeHolder: "Generate…" });
    if (!kind) return;
    if (kind === "auth") { runPlumekit(["generate", "auth"]); return; }
    const name = await vscode.window.showInputBox({ prompt: `Name (and fields) for the ${kind}` });
    if (!name) return;
    runPlumekit(["generate", kind, ...name.trim().split(/\s+/)]);
  }));
}

async function deactivate() {
  if (client) {
    await client.stop();
    client = undefined;
  }
}

function startLanguageServer(context) {
  const workspace = workspaceFolder();
  const command = resolveToolCommand(workspace);
  client = new LanguageClient(
    "plume",
    "Plume",
    {
      command: command.path,
      args: command.languageServerArgs,
      options: { cwd: workspace }
    },
    {
      documentSelector: [{ scheme: "file", language: "plume" }],
      outputChannel
    }
  );
  context.subscriptions.push(client.start());
}

function resolveToolCommand(workspace) {
  const configured = vscode.workspace.getConfiguration("plume").get("toolPath");
  if (configured && configured.trim()) {
    const toolPath = configured.trim();
    return path.basename(toolPath) === "inkstead-writer"
      ? writerCommand(toolPath, toolPath)
      : plumekitCommand(toolPath, toolPath);
  }

  if (workspace) {
    const localWriter = path.join(workspace, "inkstead-writer");
    if (fs.existsSync(localWriter)) {
      return writerCommand(localWriter, "./inkstead-writer");
    }
    // Prefer the project's committed ./plumekit wrapper — it pins the CLI version.
    const localPlumekit = path.join(workspace, "plumekit");
    if (fs.existsSync(localPlumekit)) {
      return plumekitCommand(localPlumekit, "./plumekit");
    }
  }

  return plumekitCommand("plumekit", "plumekit");
}

function writerCommand(path, display) {
  return {
    path,
    display,
    languageServerArgs: ["theme", "language-server"],
    checkArgs: ["theme", "check"]
  };
}

function plumekitCommand(path, display) {
  return {
    path,
    display,
    languageServerArgs: ["language-server"],
    checkArgs: ["check"]
  };
}

// The `plumekit` executable to run framework commands with — the project's committed
// ./plumekit wrapper when present, else `plumekit` on PATH.
function resolvePlumekitCli(workspace) {
  if (workspace && fs.existsSync(path.join(workspace, "plumekit"))) return "./plumekit";
  return "plumekit";
}

let plumekitTerminal;
function runPlumekit(args) {
  const workspace = workspaceFolder();
  const cli = resolvePlumekitCli(workspace);
  if (!plumekitTerminal || plumekitTerminal.exitStatus !== undefined) {
    plumekitTerminal = vscode.window.createTerminal({ name: "PlumeKit", cwd: workspace });
  }
  plumekitTerminal.show();
  plumekitTerminal.sendText(`${cli} ${args.join(" ")}`);
}

function workspaceFolder() {
  const editor = vscode.window.activeTextEditor;
  if (editor) {
    const folder = vscode.workspace.getWorkspaceFolder(editor.document.uri);
    if (folder) return folder.uri.fsPath;
  }
  const folder = vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders[0];
  return folder ? folder.uri.fsPath : process.cwd();
}

function showCommandError(command, fallback) {
  if (command.display === "plumekit") {
    vscode.window.showErrorMessage(`${fallback} Install the PlumeKit CLI, or set plume.toolPath to a plumekit executable.`);
  } else {
    vscode.window.showErrorMessage(`${fallback} See the Plume output for details.`);
  }
}

module.exports = { activate, deactivate };
