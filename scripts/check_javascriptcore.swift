import Foundation
import JavaScriptCore

let script = try String(contentsOfFile: "ios/Sever/Resources/sever-core.js", encoding: .utf8)
guard let context = JSContext() else { fatalError("JavaScriptCore unavailable") }
context.evaluateScript(script)
guard context.exception == nil else { fatalError("Core failed to load in JavaScriptCore") }
let uuid = "11111111-2222-4333-8444-555555555555"
let sample = "vless://\(uuid)@example.invalid:443?security=reality&pbk=test#Test"
let inputData = try JSONSerialization.data(withJSONObject: sample, options: .fragmentsAllowed)
let input = String(data: inputData, encoding: .utf8)!
let reply = context.objectForKeyedSubscript("severCall")!.call(withArguments: ["importText", input])!.toString()!
let object = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as! [String: Any]
guard object["ok"] as? Bool == true else { fatalError("Import failed in JavaScriptCore") }
print("JavaScriptCore import smoke check passed")
