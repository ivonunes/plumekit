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

  // PlumeKit framework commands — run the CLI (preferring ./plumekit) and report.
  const frameworkCommands = {
    "plumekit.dev": ["dev"],
    "plumekit.serve": ["serve"],
    "plumekit.build": ["build"],
    "plumekit.deploy": ["deploy"],
    "plumekit.migrate": ["migrate"],
    "plumekit.routes": ["routes"],
    "plumekit.doctor": ["doctor"]
  };
  Object.keys(frameworkCommands).forEach(function(id) {
    nova.commands.register(id, function() {
      runPlumekit(id.replace("plumekit.", ""), frameworkCommands[id]);
    });
  });
  nova.commands.register("plumekit.generate", function() {
    const kinds = ["resource", "auth", "model", "controller", "migration", "view", "middleware", "job", "seeder"];
    nova.workspace.showChoicePalette(kinds, { placeholder: "Generate…" }, function(kind) {
      if (!kind) return;
      if (kind === "auth") { runPlumekit("generate", ["generate", "auth"]); return; }
      nova.workspace.showInputPalette(`Name (and fields) for the ${kind}`, {}, function(name) {
        if (name) runPlumekit("generate", ["generate", kind].concat(name.trim().split(/\s+/)));
      });
    });
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

  // Prefer the project's committed ./plumekit wrapper — it pins the CLI version.
  const workspacePlumekit = nova.workspace.path ? nova.path.join(nova.workspace.path, "plumekit") : null;
  if (workspacePlumekit && nova.fs.access(workspacePlumekit, nova.fs.X_OK)) {
    return plumeCommand(workspacePlumekit);
  }

  return {
    path: "/usr/bin/env",
    languageServerArgs: ["plumekit", "language-server"],
    checkArgs: ["plumekit", "check"]
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

// How to invoke `plumekit <subArgs>` — the project's ./plumekit wrapper if present,
// else `plumekit` on PATH via /usr/bin/env.
function plumekitInvocation(subArgs) {
  const local = nova.workspace.path ? nova.path.join(nova.workspace.path, "plumekit") : null;
  if (local && nova.fs.access(local, nova.fs.X_OK)) {
    return { path: local, args: subArgs };
  }
  return { path: "/usr/bin/env", args: ["plumekit"].concat(subArgs) };
}

function runPlumekit(name, subArgs) {
  const invocation = plumekitInvocation(subArgs);
  const workspace = nova.workspace.path || undefined;
  console.log(`plumekit ${subArgs.join(" ")}`);
  const process = new Process(invocation.path, { args: invocation.args, cwd: workspace });
  let output = "";
  process.onStdout(function(line) { output += line; console.log(line); });
  process.onStderr(function(line) { output += line; console.error(line); });
  process.onDidExit(function(status) {
    const ok = status === 0;
    notify(`PlumeKit ${name}${ok ? "" : " failed"}`,
           output.trim() || (ok ? "Done." : `Exited with status ${status}. See the Extension Console.`));
  });
  try {
    process.start();
  } catch (error) {
    notify(`PlumeKit ${name} failed`, error && error.message ? error.message : String(error));
  }
}
