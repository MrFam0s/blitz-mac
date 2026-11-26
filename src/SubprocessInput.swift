import Darwin
import Foundation

/// A child closing stdin must fail the parent's write with EPIPE, even if the parent handles SIGPIPE normally.
func makeSubprocessInputPipe() throws -> Pipe {
    let pipe = Pipe()
    guard fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return pipe
}
