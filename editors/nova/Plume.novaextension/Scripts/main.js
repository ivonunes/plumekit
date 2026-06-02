let client = null;

function notify(title, body) {
  const request = new NotificationRequest(`plume-${Date.now()}`);
  request.title = title;
  if (body) request.body = body;
  nova.notifications.add(request).catch(error => console.error(error));
}

exports.activate = function() {
  console.log("Activating Plume extension.");

  nova.commands.register("plume.restartLanguageServer", function() {
    stopLanguageServer();
    startLanguageServer();
  });

  nova.commands.register("plume.checkTheme", function() {
    const command = commandConfiguration();
    const workspace = nova.workspace.path || undefined;
    console.log(`Running ${command.path} ${command.checkArgs.join(" ")}`);
    const process = new Process(command.path, {
      args: command.checkArgs,
      cwd: workspace
    });

    let output = "";
    process.onStdout(function(line) {
      output += line;
      console.log(line);
    });
    process.onStderr(function(line) {
      output += line;
      console.error(line);
    });
    process.onDidExit(function(status) {
      if (status === 0) {
        console.log("Plume check passed.");
        notify("Plume check passed", output.trim() || "No template issues found.");
      } else {
        console.error("Plume check failed.");
        notify("Plume check failed", output.trim() || `Exited with status ${status}. See the Extension Console for details.`);
      }
    });

    try {
      process.start();
    } catch (error) {
      const message = error && error.message ? error.message : String(error);
      console.error(`Failed to run Plume check: ${message}`);
      notify("Plume check failed", message);
    }
  });

  startLanguageServer();
};

exports.deactivate = function() {
  stopLanguageServer();
};

function startLanguageServer() {
  try {
    const command = commandConfiguration();
    client = new LanguageClient(
      "plume",
      "Plume",
      {
        path: command.path,
        args: command.languageServerArgs,
        type: "stdio"
      },
      {
        syntaxes: ["plume"]
      }
    );
    console.log(`Starting Plume language server: ${command.path} ${command.languageServerArgs.join(" ")}`);
    client.start();
  } catch (error) {
    console.error(`Failed to start Plume language server: ${error && error.message ? error.message : error}`);
    client = null;
  }
}

function stopLanguageServer() {
  if (client) {
    client.stop();
    client = null;
  }
}

function commandConfiguration() {
  const configured = nova.config.get("plume.toolPath");
  if (configured && configured.trim().length > 0) {
    const path = configured.trim();
    return pathBaseName(path) === "inkstead-writer"
      ? writerCommand(path)
      : plumeCommand(path);
  }

  const workspaceLauncher = nova.workspace.path ? nova.path.join(nova.workspace.path, "inkstead-writer") : null;
  if (workspaceLauncher && nova.fs.access(workspaceLauncher, nova.fs.X_OK)) {
    return writerCommand(workspaceLauncher);
  }

  return {
    path: "/usr/bin/env",
    languageServerArgs: ["plume", "language-server"],
    checkArgs: ["plume", "check"]
  };
}

function writerCommand(path) {
  return {
    path: path,
    languageServerArgs: ["theme", "language-server"],
    checkArgs: ["theme", "check"]
  };
}

function plumeCommand(path) {
  return {
    path: path,
    languageServerArgs: ["language-server"],
    checkArgs: ["check"]
  };
}

function pathBaseName(path) {
  const parts = path.split(/[\\/]/);
  return parts[parts.length - 1];
}
