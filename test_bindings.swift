import Foundation

struct GestureBinding: Codable {
    var gesture: String
    var actionType: String
    var value: String
    var enabled: Bool
}

let bindingsKey = "TapTap.bindings"
if let data = UserDefaults.standard.data(forKey: bindingsKey) {
    if let list = try? JSONDecoder().decode([GestureBinding].self, from: data) {
        print("Bindings parsed:", list)
    } else {
         print("Failed to decode bindings from data:", String(data: data, encoding: .utf8) ?? "null")
    }
} else {
    print("No bindings data in UserDefaults")
}
