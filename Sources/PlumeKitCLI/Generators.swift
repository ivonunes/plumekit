import Foundation

// Code generators behind `plumekit generate <kind>`. Everything here emits code that
// compiles in a scaffolded project; generators never overwrite an existing file.

// MARK: - Naming helpers (mirror the @Model macro so generated tables/columns match)

/// ASCII snake_case — identical rules to PlumeMacros so a generated migration's table
/// and column names match what `@Model` produces at compile time.
func generatorSnakeCase(_ name: String) -> String {
    let bytes = Array(name.utf8)
    if bytes.isEmpty { return name }
    func isUpper(_ b: UInt8) -> Bool { b >= 0x41 && b <= 0x5a }
    func isLower(_ b: UInt8) -> Bool { b >= 0x61 && b <= 0x7a }
    func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    var out: [UInt8] = []
    for i in 0..<bytes.count {
        let byte = bytes[i]
        if isUpper(byte) {
            let previous = i > 0 ? bytes[i - 1] : 0
            let next = i + 1 < bytes.count ? bytes[i + 1] : 0
            if !out.isEmpty, out.last != 0x5f, isLower(previous) || isDigit(previous) || isLower(next) {
                out.append(0x5f)
            }
            out.append(byte + 32)
        } else if byte == 0x2d || byte == 0x20 {
            if !out.isEmpty, out.last != 0x5f { out.append(0x5f) }
        } else {
            out.append(byte)
        }
    }
    return String(decoding: out, as: UTF8.self)
}

/// Naive English pluraliser — matches PlumeMacros' table-name rules.
func generatorPluralize(_ word: String) -> String {
    if word.hasSuffix("y"), let last = word.dropLast().last, !"aeiou".contains(last) {
        return word.dropLast() + "ies"
    }
    if word.hasSuffix("s") || word.hasSuffix("x") || word.hasSuffix("z")
        || word.hasSuffix("ch") || word.hasSuffix("sh") { return word + "es" }
    return word + "s"
}

/// The table name `@Model` derives for a type: pluralized snake_case.
func generatorTable(_ model: String) -> String { generatorPluralize(generatorSnakeCase(model)) }

func firstLowercased(_ s: String) -> String {
    guard let first = s.first else { return s }
    return first.lowercased() + s.dropFirst()
}

func generatorSwiftType(_ token: String) -> String {
    switch token {
    case "string", "text": return "String"
    case "int": return "Int"
    case "int64": return "Int64"
    case "bool": return "Bool"
    case "double": return "Double"
    case "blob": return "[UInt8]"
    default: return "String"
    }
}

func generatorSQLType(_ token: String) -> String {
    switch token {
    case "int", "int64", "bool": return "INTEGER"
    case "double": return "REAL"
    case "blob": return "BLOB"
    default: return "TEXT"
    }
}

struct GeneratedField {
    let name: String
    let token: String
    var swiftType: String { generatorSwiftType(token) }
    var sqlType: String { generatorSQLType(token) }
    var column: String { generatorSnakeCase(name) }
    /// The schema-builder method for this field's type (`t.text`, `t.integer`, …).
    var builderMethod: String {
        switch token {
        case "int", "int64": return "integer"
        case "bool": return "boolean"
        case "double": return "real"
        case "blob": return "blob"
        default: return "text"
        }
    }
}

func parseFields(_ fields: [String]) -> [GeneratedField] {
    fields.map { field in
        let parts = field.split(separator: ":", maxSplits: 1)
        return GeneratedField(name: String(parts[0]), token: parts.count > 1 ? String(parts[1]) : "string")
    }
}

func generatorCapitalize(_ s: String) -> String {
    s.prefix(1).uppercased() + s.dropFirst()
}

/// The validation rules a generated resource applies to a field before saving.
func validationRules(_ f: GeneratedField) -> String {
    switch f.token {
    case "int", "int64": return "[.required, .integer]"
    case "double": return "[.required, .decimal]"
    default: return "[.required]"
    }
}

/// What `generate model`/`generate resource` output needs: the generated code
/// queries through `Database.current`, which traps when the capability is off.
/// Declared next to the generators; the generate command gates on it.
let modelRequiredCapabilities = ["database"]

/// A `form[...]` expression that yields the field's Swift type. The handler binds
/// `let form = request.form` once — parsing is per access, so per-field
/// `request.form[...]` reads would re-parse the body for every field.
func formValueExpr(_ f: GeneratedField) -> String {
    switch f.token {
    case "int": return "Int(form[\"\(f.name)\"] ?? \"\") ?? 0"
    case "int64": return "Int64(form[\"\(f.name)\"] ?? \"\") ?? 0"
    case "double": return "Double(form[\"\(f.name)\"] ?? \"\") ?? 0"
    case "bool": return "form[\"\(f.name)\"] == \"true\""
    case "blob": return "Array((form[\"\(f.name)\"] ?? \"\").utf8)"
    default: return "form[\"\(f.name)\"] ?? \"\""
    }
}

/// A default Swift literal for a field — used in generated factories.
func factoryDefaultValue(_ f: GeneratedField) -> String {
    switch f.token {
    case "int", "int64": return "1"
    case "double": return "1.0"
    case "bool": return "false"
    case "blob": return "[]"
    default: return "\"example\""
    }
}

/// A default urlencoded form value for a field — used in generated tests.
func formDefaultValue(_ f: GeneratedField) -> String {
    switch f.token {
    case "int", "int64": return "1"
    case "double": return "1.0"
    case "bool": return "true"
    case "blob": return "x"
    default: return "example"
    }
}

/// The `let` binding name for a migration, e.g. "CreateBookmarks" -> "createBookmarks".
func migrationBinding(_ name: String) -> String { firstLowercased(name) }

/// A UTC timestamp (`yyyyMMddHHmmss`) prefixing migration versions and filenames, so
/// they order by creation time and two branches never collide on the same number.
func migrationTimestamp() -> String {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
    func pad(_ n: Int, _ width: Int) -> String { String(format: "%0\(width)d", n) }
    return pad(c.year!, 4) + pad(c.month!, 2) + pad(c.day!, 2)
        + pad(c.hour!, 2) + pad(c.minute!, 2) + pad(c.second!, 2)
}

/// A migration FILE that creates a table with explicit columns. Spelled out (not
/// derived from the model) so editing the model later never rewrites this migration.
/// Returns the filename (timestamp-prefixed) and file contents.
func createTableMigrationFile(model: String, fields: [GeneratedField]) -> (fileName: String, binding: String, contents: String) {
    let table = generatorTable(model)
    let binding = "create" + generatorPluralize(model)
    let stamp = migrationTimestamp()
    var columns = ["            t.id()"]
    for f in fields { columns.append("            t.\(f.builderMethod)(\"\(f.column)\")") }
    let contents = """
    import PlumeORM

    let \(binding) = Migration(
        version: "\(stamp)_create_\(table)",
        up: { db in
            try await db.createTable("\(table)") { t in
    \(columns.joined(separator: "\n"))
            }
        },
        down: { db in try await db.dropTable("\(table)") }
    )

    """
    return (fileName: "\(stamp)_Create\(generatorPluralize(model)).swift", binding: binding, contents: contents)
}

// MARK: - File writer

func writeGenerated(_ contents: String, to path: String, label: String) -> Int32 {
    if FileManager.default.fileExists(atPath: path) {
        errorLine("\(path) already exists — not overwriting")
        return 1
    }
    let dir = (path as NSString).deletingLastPathComponent
    if !dir.isEmpty { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
    guard writeFile(contents, to: path) else { return 1 }
    print("  + \(path)  (\(label))")
    return 0
}

// MARK: - model

func generateModel(name: String, fields rawFields: [String]) -> Int32 {
    let fields = parseFields(rawFields)
    var lines = ["import PlumeORM", "", "@Model", "final class \(name): Model {", "    var id: Int"]
    for f in fields { lines.append("    var \(f.name): \(f.swiftType)") }
    lines.append("}")
    let status = writeGenerated(lines.joined(separator: "\n") + "\n", to: "Sources/App/Models/\(name).swift", label: "model")
    guard status == 0 else { return status }
    let migration = createTableMigrationFile(model: name, fields: fields)
    if writeGenerated(migration.contents, to: "Sources/App/Database/Migrations/\(migration.fileName)", label: "migration") != 0 { return 1 }
    print("")
    print("  Run `plumekit migrate` — the migration is picked up automatically.")
    return 0
}

// MARK: - controller

func generateController(name: String) -> Int32 {
    let contents = """
    import PlumeCore
    import PlumeORM

    // The seven RESTful actions. `new`/`edit` return HTML forms (GET /new, GET /:id/edit);
    // implement only what you need — the rest fall back to 405. Delete any you don't use.
    struct \(name)Controller: Controller {
        func index(_ request: Request) async throws -> Response {
            .text("TODO: \(name)Controller.index")
        }

        func new(_ request: Request) async throws -> Response {
            .text("TODO: \(name)Controller.new — the create form")
        }

        func create(_ request: Request) async throws -> Response {
            .text("TODO: \(name)Controller.create", status: 201)
        }

        func show(_ request: Request) async throws -> Response {
            .text("TODO: \(name)Controller.show")
        }

        func edit(_ request: Request) async throws -> Response {
            .text("TODO: \(name)Controller.edit — the edit form")
        }

        func update(_ request: Request) async throws -> Response {
            .text("TODO: \(name)Controller.update")
        }

        func destroy(_ request: Request) async throws -> Response {
            .text("TODO: \(name)Controller.destroy")
        }
    }

    """
    let status = writeGenerated(contents, to: "Sources/App/Controllers/\(name)Controller.swift", label: "controller")
    if status == 0 {
        print("  Register in buildApp(): app.resources(\"\(generatorTable(name))\", \(name)Controller())")
    }
    return status
}

// MARK: - migration

func generateMigration(name: String) -> Int32 {
    let binding = migrationBinding(name)
    let stamp = migrationTimestamp()
    let contents = """
    import PlumeORM

    // Spell the change out so this migration is a frozen record of one change. Use the
    // schema builder (db.createTable/alterTable/addIndex/…), or run db.query("...")
    // directly for anything it doesn't cover.
    let \(binding) = Migration(
        version: "\(stamp)_\(name)",
        up: { db in
            // e.g. try await db.createTable("widgets") { t in
            //     t.id(); t.text("name"); t.integer("count")
            // }
        },
        down: { db in
            // e.g. try await db.dropTable("widgets")
        }
    )

    """
    let status = writeGenerated(contents, to: "Sources/App/Database/Migrations/\(stamp)_\(name).swift", label: "migration")
    if status == 0 { print("  Fill in up/down, then `plumekit migrate` — it's picked up automatically.") }
    return status
}

// MARK: - middleware

func generateMiddleware(name: String) -> Int32 {
    let contents = """
    import PlumeCore

    struct \(name)Middleware: Middleware {
        func respond(to request: Request, next: Responder) async throws -> Response {
            // Runs before the handler. Return early to short-circuit.
            let response = try await next(request)
            // Runs after the handler.
            return response
        }
    }

    """
    let status = writeGenerated(contents, to: "Sources/App/Middleware/\(name)Middleware.swift", label: "middleware")
    if status == 0 { print("  Register in buildApp(): app.use(\(name)Middleware())") }
    return status
}

// MARK: - job

func generateJob(name: String) -> Int32 {
    let contents = """
    import PlumeCore

    struct \(name)Job: Job {
        static let name = "\(firstLowercased(name))"

        init(payload: [UInt8]) {}
        func payload() -> [UInt8] { [] }

        func perform(_ context: Context) async throws {
            // Background work. Reach host bindings through `context` (e.g. context.database).
        }
    }

    """
    let status = writeGenerated(contents, to: "Sources/App/Jobs/\(name)Job.swift", label: "job")
    if status == 0 {
        print("  Auto-registered — jobs under Sources/App/Jobs/ are discovered on the next build.")
        print("  Enqueue: try await \(name)Job().enqueue(on: request.bindings.queue)")
    }
    return status
}

// MARK: - seeder

func generateSeeder(name: String) -> Int32 {
    let value = firstLowercased(name) + "Seeder"
    let contents = """
    import PlumeORM

    let \(value) = Seeder { _ in
        // Insert seed rows, e.g. `_ = try await Widget(name: "…").save()`. Make it
        // idempotent (upsert) if it may run more than once.
    }

    """
    let status = writeGenerated(contents, to: "Sources/App/Database/Seeders/\(name)Seeder.swift", label: "seeder")
    if status == 0 { print("  Fill it in, then `plumekit seed` (or `plumekit seed \(firstLowercased(name))`).") }
    return status
}

// MARK: - view (a standalone Plume component)

func generateView(name: String) -> Int32 {
    let contents = """
    @component \(name)(title: String) {<section>
      <h1>{title}</h1>
    </section>}
    """
    let status = writeGenerated(contents + "\n", to: "Views/\(name).plume", label: "view")
    if status == 0 {
        print("  Renders as \(firstLowercased(name))(title: \"…\", into: &out) after compile (serve/build do it).")
    }
    return status
}

// MARK: - test

func generateTest(name: String) -> Int32 {
    let contents = """
    import Testing
    @testable import App
    import PlumeTesting

    @Suite struct \(name)Tests {
        @Test func example() async throws {
            // Each test boots a fresh, migrated in-memory database + a TestHTTPClient.
            let app = try await TestApp.boot(buildApp, migrations: runMigrations)
            let response = await app.client.get("/")
            #expect(response.hasStatus(200))
        }
    }
    """
    return writeGenerated(contents + "\n", to: "Tests/AppTests/\(name)Tests.swift", label: "test")
}

// MARK: - resource (the full scaffold: model + controller + views + migration + routes)

func generateResource(name: String, fields rawFields: [String]) -> Int32 {
    let fields = parseFields(rawFields)
    let table = generatorTable(name)
    let lower = firstLowercased(name)
    let labelField = fields.first(where: { $0.token == "string" || $0.token == "text" })?.name ?? "id"

    // 1. Model
    var modelLines = ["import PlumeORM", "", "@Model", "final class \(name): Model {", "    var id: Int"]
    for f in fields { modelLines.append("    var \(f.name): \(f.swiftType)") }
    modelLines.append("}")
    if writeGenerated(modelLines.joined(separator: "\n") + "\n", to: "Sources/App/Models/\(name).swift", label: "model") != 0 { return 1 }

    // 2. Controller (functional CRUD over the model + views).
    //    String/number fields are validated on create; a failed validation re-renders
    //    the New form (422) with the submitted values and per-field messages inline.
    let initArgs = fields.map { "\($0.name): \(formValueExpr($0))" }.joined(separator: ", ")
    let assigns = fields.map { "        item.\($0.name) = \(formValueExpr($0))" }.joined(separator: "\n")
    let validated = fields.filter { $0.token != "bool" && $0.token != "blob" }
    let rules = validated.map { "(\"\($0.name)\", \(validationRules($0)))" }.joined(separator: ", ")
    let reRenderArgs = validated.map {
        "old\(generatorCapitalize($0.name)): input.string(\"\($0.name)\"), \($0.name)Error: input.errors.first(\"\($0.name)\")"
    }.joined(separator: ", ")
    // One parse, many field reads (form access parses per call).
    let formBinding = fields.isEmpty ? "" : "\n        let form = request.form"
    let validationBlock = validated.isEmpty ? "" : """

            let input = request.validate([\(rules)])
            guard input.isValid else {
                return .view(\(lower)New(\(reRenderArgs)), status: 422)   // re-render the form with errors
            }
    """
    let controller = """
    import PlumeCore
    import PlumeORM
    import PlumeRuntime

    /// The resource's paths, declared once — registration (`app.resources`) and every
    /// redirect build from these, so renaming the path is a one-line change.
    enum \(name)Routes {
        static let index = Route("/\(table)")
        static let new = Route("/\(table)/new")
        static let show = Route1("/\(table)/:id")
        static let edit = Route1("/\(table)/:id/edit")
    }

    struct \(name)Controller: Controller {
        func index(_ request: Request) async throws -> Response {
            let items = try await \(name).query().order(by: \(name).id, .descending).all()
            return .view(\(lower)Index(items: items,
                                       flash: request.flash?.message ?? ""))
        }

        func new(_ request: Request) async throws -> Response {
            .view(\(lower)New())
        }

        func show(_ request: Request) async throws -> Response {
            guard let item = try await \(name).find(request) else { return .status(404) }
            return .view(\(lower)Show(item: item))
        }

        func edit(_ request: Request) async throws -> Response {
            guard let item = try await \(name).find(request) else { return .status(404) }
            return .view(\(lower)Edit(item: item))
        }

        func create(_ request: Request) async throws -> Response {\(validationBlock)\(formBinding)
            let item = \(name)(\(initArgs))
            _ = try await item.save()
            return .redirect(to: \(name)Routes.index.path).flash("\(name) created")
        }

        func update(_ request: Request) async throws -> Response {
            guard let item = try await \(name).find(request) else { return .status(404) }\(formBinding)
    \(assigns.isEmpty ? "        _ = item" : assigns)
            _ = try await item.save()
            return .redirect(to: \(name)Routes.show.path(item.id)).flash("\(name) updated")
        }

        func destroy(_ request: Request) async throws -> Response {
            if let item = try await \(name).find(request) {
                try await item.delete()
            }
            return .redirect(to: \(name)Routes.index.path).flash("\(name) deleted")
        }
    }

    """
    if writeGenerated(controller, to: "Sources/App/Controllers/\(name)Controller.swift", label: "controller") != 0 { return 1 }

    // 3. Views, grouped under Views/<Name>/ so the directory stays organized as the app
    //    grows (Index/New/Show/Edit.plume) — PascalCase to match the rest of the tree. The
    //    `@component` names stay globally qualified (\(name)Index): they compile to
    //    top-level render functions; the folder just groups the files. Uses the scaffold's
    //    Layout.
    let formInputs = fields.map { field in
        guard validated.contains(where: { $0.name == field.name }) else {
            return "    <input name=\"\(field.name)\" placeholder=\"\(field.name)\">"
        }
        let old = "old\(generatorCapitalize(field.name))"
        let error = "\(field.name)Error"
        return "    <p><input name=\"\(field.name)\" placeholder=\"\(field.name)\" value=\"{\(old)}\">"
            + "@if \(error) != \"\" {<span class=\"field-error\">{\(error)}</span>}</p>"
    }.joined(separator: "\n")
    let indexView = """
    @component \(name)Index(items: [\(name)], flash: String = "") {@Layout(title: "\(generatorPluralize(name))") {
      <h1>\(generatorPluralize(name))</h1>
      @if flash != "" {<p class="flash">{flash}</p>}
      <p><a href="/\(table)/new">New \(name)</a></p>
      <ul>@for item in items {<li><a href="/\(table)/{item.id}">{item.\(labelField)}</a></li>}</ul>
    }}
    """
    if writeGenerated(indexView + "\n", to: "Views/\(name)/Index.plume", label: "view") != 0 { return 1 }

    // The create form (GET /new). Repopulates submitted values and shows per-field
    // messages when a create fails validation (the controller re-renders New with
    // old*/*Error filled), mirroring Edit.
    let newStateParams = validated.map {
        "old\(generatorCapitalize($0.name)): String = \"\", \($0.name)Error: String = \"\""
    }.joined(separator: ", ")
    let newView = """
    @component \(name)New(\(newStateParams)) {@Layout(title: "New \(name)") {
      <h1>New \(name)</h1>
      <form method="post" action="/\(table)">
        @csrf
    \(formInputs)
        <button type="submit">Create</button>
      </form>
      <a href="/\(table)">Cancel</a>
    }}
    """
    if writeGenerated(newView + "\n", to: "Views/\(name)/New.plume", label: "view") != 0 { return 1 }

    let showRows = fields.map { "  <p><strong>\($0.name):</strong> {item.\($0.name)}</p>" }.joined(separator: "\n")
    let showView = """
    @component \(name)Show(item: \(name)) {@Layout(title: "\(name)") {
      <h1>\(name) {item.id}</h1>
    \(showRows)
      <a href="/\(table)/{item.id}/edit">Edit</a>
      <form method="post" action="/\(table)/{item.id}" style="display:inline">
        @csrf
        <input type="hidden" name="_method" value="DELETE">
        <button type="submit">Delete</button>
      </form>
      <a href="/\(table)">Back</a>
    }}
    """
    if writeGenerated(showView + "\n", to: "Views/\(name)/Show.plume", label: "view") != 0 { return 1 }

    // The edit form: pre-filled inputs, method-overridden to PATCH → update.
    let editInputs = fields.map {
        "    <p>\($0.name): <input name=\"\($0.name)\" value=\"{item.\($0.name)}\"></p>"
    }.joined(separator: "\n")
    let editView = """
    @component \(name)Edit(item: \(name)) {@Layout(title: "Edit \(name)") {
      <h1>Edit \(name) {item.id}</h1>
      <form method="post" action="/\(table)/{item.id}">
        @csrf
        <input type="hidden" name="_method" value="PATCH">
    \(editInputs)
        <button type="submit">Save</button>
      </form>
      <a href="/\(table)/{item.id}">Cancel</a>
    }}
    """
    if writeGenerated(editView + "\n", to: "Views/\(name)/Edit.plume", label: "view") != 0 { return 1 }

    // 4. Factory (with sensible defaults) + a test exercising the routes.
    let factoryArgs = fields.map { "\($0.name): \(factoryDefaultValue($0))" }.joined(separator: ", ")
    let factory = """
    import PlumeORM

    extension \(name) {
        // Override attributes per instance; use Fake.string()/int()/email() for unique values.
        static let factory = Factory { \(name)(\(factoryArgs)) }
    }
    """
    if writeGenerated(factory + "\n", to: "Sources/App/Database/Factories/\(name)Factory.swift", label: "factory") != 0 { return 1 }

    let formFields = fields.map { "(\"\($0.name)\", \"\(formDefaultValue($0))\")" }.joined(separator: ", ")
    let test = """
    import Testing
    @testable import App
    import PlumeTesting

    @Suite struct \(name)Tests {
        @Test func lists\(name)Records() async throws {
            let app = try await TestApp.boot(buildApp, migrations: runMigrations)
            _ = try await \(name).factory.create(in: app.database)
            #expect((await app.client.get("/\(table)")).hasStatus(200))
        }

        @Test func creates\(name)ViaForm() async throws {
            let app = try await TestApp.boot(buildApp, migrations: runMigrations)
            // app.postForm encodes the fields and adds the CSRF token automatically.
            #expect((await app.postForm("/\(table)", [\(formFields)])).isRedirect)
        }
    }
    """
    if writeGenerated(test + "\n", to: "Tests/AppTests/\(name)Tests.swift", label: "test") != 0 { return 1 }

    // 5. Migration file (explicit schema, auto-discovered) + route registration hint.
    let migration = createTableMigrationFile(model: name, fields: fields)
    if writeGenerated(migration.contents, to: "Sources/App/Database/Migrations/\(migration.fileName)", label: "migration") != 0 { return 1 }
    print("")
    print("  Register the routes:  app.resources(\"\(table)\", \(name)Controller())  in registerRoutes(_:)")
    print("  Then run `plumekit migrate` — the migration is picked up automatically.")
    return 0
}
