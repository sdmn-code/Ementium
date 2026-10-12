import Foundation
import os

/// Принимает соединение от Ementium. Последнее соединение закрылось — процесс завершается: так кэши
/// декодеров и пиковая память уходят вместе с ним, а зависшее декодирование обрывается.
final class ServiceDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let connections = OSAllocatedUnfairLock(initialState: 0)

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: (any DecoderProtocol).self)
        connection.exportedObject = DecoderService()
        connection.invalidationHandler = { [connections] in
            let remaining = connections.withLock { count -> Int in
                count -= 1
                return count
            }
            // `_exit`, а не `exit`: зависший декодер может держать блокировки, на которых повисли бы обработчики выхода.
            if remaining <= 0 { _exit(0) }
        }
        connections.withLock { $0 += 1 }
        connection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
