import Foundation

let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
guard let handle = handle,
      let sym = dlsym(handle, "MRMediaRemoteSendCommand") else {
    print("Failed to load symbol")
    exit(1)
}

typealias MRSendCommand = @convention(c) (Int, AnyObject?) -> Bool
let f = unsafeBitCast(sym, to: MRSendCommand.self)
let success = f(2, nil) // playPause
print("Success:", success)
