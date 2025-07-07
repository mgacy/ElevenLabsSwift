//
//  Connection.swift
//  ElevenLabsSDK
//
//  Created by Mathew Gacy on 7/6/25.
//

import Foundation

final class Connection: @unchecked Sendable {
    typealias Constants = ElevenLabsSDK.Constants
    typealias ElevenLabsError = ElevenLabsSDK.ElevenLabsError
    typealias SessionConfig = ElevenLabsSDK.SessionConfig

    let socket: URLSessionWebSocketTask
    let conversationId: String
    let sampleRate: Int

    private init(socket: URLSessionWebSocketTask, conversationId: String, sampleRate: Int) {
        self.socket = socket
        self.conversationId = conversationId
        self.sampleRate = sampleRate
    }

    static func create(config: SessionConfig) async throws -> Connection {
        let origin = ProcessInfo.processInfo.environment["ELEVENLABS_CONVAI_SERVER_ORIGIN"] ?? Constants.defaultApiOrigin
        let pathname = ProcessInfo.processInfo.environment["ELEVENLABS_CONVAI_SERVER_PATHNAME"] ?? Constants.defaultApiPathname

        let urlString: String
        if let signedUrl = config.signedUrl {
            urlString = signedUrl
        } else if let agentId = config.agentId {
            urlString = "\(origin)\(pathname)\(agentId)"
        } else {
            throw ElevenLabsError.invalidConfiguration
        }

        guard let url = URL(string: urlString) else {
            throw ElevenLabsError.invalidURL
        }

        let session = URLSession(configuration: .default)
        let socket = session.webSocketTask(with: url)
        socket.resume()

        // Always send initialization event
        var initEvent: [String: Any] = ["type": "conversation_initiation_client_data"]

        // Add overrides if present
        if let overrides = config.overrides,
           let overridesDict = overrides.dictionary
        {
            initEvent["conversation_config_override"] = overridesDict
        }

        // Add custom body if present
        if let customBody = config.customLlmExtraBody {
            initEvent["custom_llm_extra_body"] = customBody.mapValues { $0.jsonValue }
        }

        // Add dynamic variables if present - Convert to JSON-compatible values
        if let dynamicVars = config.dynamicVariables {
            initEvent["dynamic_variables"] = dynamicVars.mapValues { $0.jsonValue }
        }

        let jsonData = try JSONSerialization.data(withJSONObject: initEvent)
        let jsonString = String(data: jsonData, encoding: .utf8)!
        try await socket.send(.string(jsonString))

        let configData = try await receiveInitialMessage(socket: socket)
        return Connection(socket: socket, conversationId: configData.conversationId, sampleRate: configData.sampleRate)
    }

    private static func receiveInitialMessage(
        socket: URLSessionWebSocketTask
    ) async throws -> (conversationId: String, sampleRate: Int) {
        return try await withCheckedThrowingContinuation { continuation in
            socket.receive { result in
                switch result {
                case let .success(message):
                    switch message {
                    case let .string(text):
                        guard let data = text.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                              let type = json["type"] as? String,
                              type == "conversation_initiation_metadata",
                              let metadata = json["conversation_initiation_metadata_event"] as? [String: Any],
                              let conversationId = metadata["conversation_id"] as? String,
                              let audioFormat = metadata["agent_output_audio_format"] as? String
                        else {
                            continuation.resume(throwing: ElevenLabsError.invalidInitialMessageFormat)
                            return
                        }

                        let sampleRate = Int(audioFormat.replacingOccurrences(of: "pcm_", with: "")) ?? 16000
                        continuation.resume(returning: (conversationId: conversationId, sampleRate: sampleRate))

                    case .data:
                        continuation.resume(throwing: ElevenLabsError.unexpectedBinaryMessage)

                    @unknown default:
                        continuation.resume(throwing: ElevenLabsError.unknownMessageType)
                    }
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() {
        socket.cancel(with: .goingAway, reason: nil)
    }
}
