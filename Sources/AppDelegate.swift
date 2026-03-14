import Cocoa
import InputMethodKit

// IMKCandidates の生成に必要なためグローバルで保持
var gServer: IMKServer?

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard
            let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String,
            let bundleID = Bundle.main.bundleIdentifier
        else {
            NSLog("ykey: Info.plist に InputMethodConnectionName が見つかりません")
            NSApp.terminate(nil)
            return
        }

        gServer = IMKServer(name: connectionName, bundleIdentifier: bundleID)
        NSLog("ykey: IMKServer 起動 (\(connectionName))")
    }
}
