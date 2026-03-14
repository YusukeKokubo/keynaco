import Cocoa
import InputMethodKit

var gServer: IMKServer?

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard
            let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String,
            let bundleID = Bundle.main.bundleIdentifier
        else {
            NSLog("ykey: InputMethodConnectionName not found")
            return
        }
        gServer = IMKServer(name: connectionName, bundleIdentifier: bundleID)
        NSLog("ykey: IMKServer started connection=\(connectionName) bundle=\(bundleID)")
    }
}
