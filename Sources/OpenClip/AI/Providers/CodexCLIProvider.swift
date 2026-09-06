// CodexCLIProvider.swift
// OpenClip
//
// Runs an AI preset through the user's own locally installed, locally authenticated `codex`
// binary, billed to their ChatGPT subscription. The same shape as `ClaudeCLIProvider`: one shot,
// not streaming, the selection over stdin, the shared executor, every typed failure mapped to the
// shared provider-unavailable case. See ADR 0002.
import Foundation
import Core

@MainActor
public final class CodexCLIProvider: AIProvider {
    public var type: AIProviderType { .codexCLI }

    /// The manager's cached resolver, for the reason `ClaudeCLIProvider` gives: `currentProvider`
    /// rebuilds the provider on every access, and resolution is async and must run once per launch.
    private let resolveBinaryPath: @MainActor () async throws -> String

    /// The wire id sent over `-m`: the user's choice from Provider Settings, or the default.
    private let model: String

    /// Appended to the shared rules block. `codex exec` appends piped stdin as a `<stdin>` block,
    /// so the sentence names that block. Not localized: it is part of the prompt payload.
    static let stdinSentence = "\n\nThe text to transform is provided in the <stdin> block."

    public init(model: String, resolveBinaryPath: @escaping @MainActor () async throws -> String) {
        self.model = model
        self.resolveBinaryPath = resolveBinaryPath
    }

    public func processStream(prompt: String, text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // An empty selection must never cost a spawn.
                    let input = try AIRequestSupport.requireNonEmptyText(text)
                    let binary = try await resolveBinaryPath()
                    let workingDirectory = CodexCLI.isolatedWorkingDirectory()

                    let invocation = ShellProcessRunner.Invocation(
                        executableURL: URL(fileURLWithPath: binary),
                        arguments: CodexCLI.arguments(
                            prompt: AIRequestSupport.systemPrompt(for: prompt) + Self.stdinSentence,
                            model: model,
                            workingDirectory: workingDirectory.path
                        ),
                        environment: CodexCLI.childEnvironment(
                            inherited: ProcessInfo.processInfo.environment,
                            binaryPath: binary
                        ),
                        // The selection goes over stdin and is never an argument.
                        stdinText: AIRequestSupport.userContent(for: input),
                        timeout: Constants.scriptTimeout,
                        currentDirectoryURL: workingDirectory
                    )

                    let output: ShellProcessRunner.Output
                    do {
                        output = try await ShellProcessRunner.runCapturingExit(invocation)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw Self.launchOrTimeoutFailure(error)
                    }

                    switch CodexCLI.classify(
                        stdout: output.stdout,
                        stderr: output.stderr,
                        exitStatus: output.terminationStatus
                    ) {
                    case .success(let success):
                        // Model and exit status only: codex has no thinking-token knob to log, and
                        // the selection and the transformed text are never logged at all.
                        Log.ai.info("""
                            Codex CLI transform succeeded (exit \(output.terminationStatus, privacy: .public), \
                            model \(self.model, privacy: .public))
                            """)
                        continuation.yield(success.text)
                        continuation.finish()
                    case .failure(let failure):
                        throw failure
                    }
                } catch let failure as CodexCLI.Failure {
                    Log.ai.error("Codex CLI request failed: \(failure.message)")
                    continuation.finish(throwing: AIError.providerUnavailable(failure.message))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Cancelling the popup cancels this task, and the shared executor kills the child's
            // process group with it. The watchdog stays as the upper bound.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The watchdog's NSError is the one identity that distinguishes a hung child from a failed
    /// spawn; see `ClaudeCLIProvider`.
    private static func launchOrTimeoutFailure(_ error: Error) -> CodexCLI.Failure {
        let nsError = error as NSError
        if nsError.domain == Constants.actionErrorDomain,
           nsError.code == Constants.actionErrorCode + 1 {
            return .timedOut(seconds: Int(Constants.scriptTimeout))
        }
        return .launchFailed(nsError.localizedDescription)
    }
}
