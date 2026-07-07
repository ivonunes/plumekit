import PlumeCore
import PlumeORM
import PlumeRuntime

// A typed form-input struct: explicit mapping, no reflection.
struct PostForm: FormDecodable {
    let title: String
    let views: Int
    init(form: FormValues) {
        self.title = form.string("title")
        self.views = form.int("views") ?? 0
    }
}

/// The post form fragment: a real `<form method="post">` (works with no JS), an
/// auto-included CSRF token, validation errors, and preserved input. Values are
/// escaped via Plume's HTML buffer.
func renderPostForm(title: String, views: Int, errors: [ValidationError]) -> HTML {
    var html = HTML()
    html.literal(#"<form method="post" action="/api/posts" id="post-form">"#)
    html.literal(#"<input type="hidden" name="_csrf" value=""#)
    html.text(RenderContext.currentCSRFToken)
    html.literal(#"">"#)
    if !errors.isEmpty {
        html.literal(#"<ul class="errors">"#)
        for error in errors {
            html.literal("<li>")
            html.text(error.field + ": " + error.message)
            html.literal("</li>")
        }
        html.literal("</ul>")
    }
    html.literal(#"<input name="title" value=""#)
    html.text(title)
    html.literal(#""><input name="views" value=""#)
    html.text(views)
    html.literal(#""><button type="submit">Save</button></form>"#)
    return html
}

/// Wrap a fragment in a full page (the no-JS response), including the stream target.
func fullPage(_ body: HTML) -> HTML {
    var html = HTML()
    html.literal(#"<!doctype html><html><body><ul id="post-list"></ul>"#)
    html.append(body.bytes)
    html.literal("</body></html>")
    return html
}
