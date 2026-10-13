import AppKit
import OWABridgeCore

let application = NSApplication.shared
let controller = AppController()
application.delegate = controller
application.setActivationPolicy(.accessory)
application.run()
