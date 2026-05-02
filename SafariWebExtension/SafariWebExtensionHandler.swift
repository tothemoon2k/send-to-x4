import SafariServices
import os.log

/// Native handler stub for the Safari Web Extension. The actual Send-to-X4
/// logic lives in `background.js` (which talks to the localhost daemon at
/// 127.0.0.1:47821); this class only exists because Safari Web Extensions
/// need a native handler in their containing app extension.
class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["echo": "ok"]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
