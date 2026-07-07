import _Concurrency
import PlumeCore

/// Decode a request blob, attach the per-request `context`, dispatch it through
/// `app`, and return the encoded response blob.
///
/// This is the async heart of the worker — shared by the wasm entry (which
/// supplies a JSPI-backed context) and by native tests (which supply an
/// in-process context). No pointers and no wasm specifics, so it builds and runs
/// on both.
public func processRequest(_ app: Application, _ data: [UInt8], context: Context) async -> [UInt8] {
    let response: Response
    if var request = decodeRequest(data) {
        request.context = context
        response = await app.handle(request)
    } else {
        response = Response.text("400 Bad Request", status: 400)
    }
    return encodeResponse(response)
}
