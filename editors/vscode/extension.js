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
      : plumeCommand(toolPath, toolPath);
  }

  const localWriter = path.join(workspace, "inkstead-writer");
  if (fs.existsSync(localWriter)) {
    return writerCommand(localWriter, "./inkstead-writer");
  }

  return plumeCommand("plume", "plume");
}

function writerCommand(path, display) {
  return {
    path,
    display,
    languageServerArgs: ["theme", "language-server"],
    checkArgs: ["theme", "check"]
  };
}

function plumeCommand(path, display) {
  return {
    path,
    display,
    languageServerArgs: ["language-server"],
    checkArgs: ["check"]
  };
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
  if (command.display === "plume") {
    vscode.window.showErrorMessage(`${fallback} Install the Plume CLI, or set plume.toolPath to a plume or inkstead-writer executable.`);
  } else {
    vscode.window.showErrorMessage(`${fallback} See the Plume output for details.`);
  }
}

module.exports = { activate, deactivate };
