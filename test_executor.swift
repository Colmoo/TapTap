import Foundation

func runProcess(_ path: String, arguments: [String]) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    
    // Read output to see what happens
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    
    try process.run()
    process.waitUntilExit()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    print("Process exited with \((process.terminationStatus)). Output:", String(data: data, encoding: .utf8) ?? "")
}

Task {
    do {
        print("Running shell lock-screen test (as an example)...")
        try await runProcess("/bin/zsh", arguments: ["-c", "echo 'Hello from shell'"])
        print("Success")
    } catch {
        print("Error:", error)
    }
    exit(0)
}
RunLoop.main.run()
