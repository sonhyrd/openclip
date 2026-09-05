// ClaudeCLIProvider.swift
// OpenClip
//
// Runs an AI preset through the user's own locally installed, locally authenticated `claude`
// binary, billed to their Claude subscription. One shot, not streaming: the CLI's single JSON
// object is what carries the error flag and the usage data, so the stream yields the finished
// text exactly once and finishes.
import Foundation
import Core

@MainActor
public final class ClaudeCLIProvider: AIProvider {
    public var type: AIProviderType { .claudeCLI }

    /// Hands back the already-resolved binary path. A closure rather than a plain `String` because
    /// `AIServiceManager.currentProvider` is a *computed* property that rebuilds the provider on
    /// every access, and resolution is async — a `String` snapshot would be empty until something
    /// else had resolved it. The closure calls the manager's cached resolver, so the login shell is
    /// spawned at most once per app launch, never once per transform. Resolution itself must not
    /// move into this type.
    private let resolveBinaryPath: @MainActor () async throws -> String

    /// Appended to the shared rules block so the model knows where the text is. Not localized: it
    /// is part of the prompt payload, like the model id and the role line.
    static let stdinSentence = "\n\nThe text to transform is provided on standard input."

    public init(resolveBinaryPath: @escaping @MainActor () async throws -> String) {
        self.resolveBinaryPath = resolveBinaryPath
    }

    public func processStream(prompt: String, text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Before any process launch, per the ticket: an empty selection must never
                    // cost a spawn.
                    let input = try AIRequestSupport.requireNonEmptyText(text)
                    let binary = try await resolveBinaryPath()

                    let invocation = ShellProcessRunner.Invocation(
                        executableURL: URL(fileURLWithPath: binary),
                        // The rules block every other provider uses, plus the stdin sentence.
                        arguments: ClaudeCLI.arguments(
                            prompt: AIRequestSupport.systemPrompt(for: prompt) + Self.stdinSentence
                        ),
                        environment: ClaudeCLI.childEnvironment(
                            inherited: ProcessInfo.processInfo.environment,
                            binaryPath: binary
                        ),
                        // The selection goes over stdin and is never an argument, so quotes,
                        // backticks and newlines in it can't be misread as flags.
                        stdinText: AIRequestSupport.userContent(for: input),
                        timeout: Constants.scriptTimeout,
                        // Never inherit OpenClip's cwd (`/`): the CLI walks it. See `ClaudeCLI`.
                        currentDirectoryURL: ClaudeCLI.isolatedWorkingDirectory()
                    )

                    let output: ShellProcessRunner.Output
                    do {
                        output = try await ShellProcessRunner.runCapturingExit(invocation)
                    } catch is CancellationError {
                        // The runner now kills the child on task cancellation; propagate the
                        // cancellation as itself rather than dressing it up as a launch failure.
                        throw CancellationError()
                    } catch {
                        // The remaining throws from the runner: the watchdog, and a failed spawn.
                        throw Self.launchOrTimeoutFailure(error)
                    }

                    switch ClaudeCLI.classify(
                        stdout: output.stdout,
                        stderr: output.stderr,
                        exitStatus: output.terminationStatus
                    ) {
                    case .success(let success):
                        Self.logSuccess(success, exitStatus: output.terminationStatus)
                        continuation.yield(success.text)
                        continuation.finish()
                    case .failure(let failure):
                        throw failure
                    }
                } catch let failure as ClaudeCLI.Failure {
                    // Every typed failure maps to the shared provider-unavailable case; its payload
                    // is already a localized, actionable sentence. No new `AIError` case.
                    Log.ai.error("Claude CLI request failed: \(failure.message)")
                    continuation.finish(throwing: AIError.providerUnavailable(failure.message))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Cancelling the popup cancels this task, and the shared executor now kills the
            // child's process group with it (upstream 1.3.0 made `ShellProcessRunner` consult task
            // cancellation). The watchdog stays as the upper bound at `Constants.scriptTimeout`.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `runCapturingExit` throws on the watchdog kill, on a failed spawn and on task cancellation
    /// (handled by its own catch above) — a non-zero exit comes back as a value. The watchdog's NSError is the one identity that distinguishes them,
    /// so a hung child surfaces as the timeout message (with its bound stated) rather than a
    /// generic launch failure.
    private static func launchOrTimeoutFailure(_ error: Error) -> ClaudeCLI.Failure {
        let nsError = error as NSError
        if nsError.domain == Constants.actionErrorDomain,
           nsError.code == Constants.actionErrorCode + 1 {
            return .timedOut(seconds: Int(Constants.scriptTimeout))
        }
        return .launchFailed(nsError.localizedDescription)
    }

    /// Model, exit status and thinking tokens are `.public` so they are readable in the log; the
    /// selection and the transformed text are never logged at all.
    private static func logSuccess(_ success: ClaudeCLI.Success, exitStatus: Int32) {
        let model = success.modelUsage.loggedModel
        let thinkingTokens = success.thinkingTokens.map(String.init) ?? "unreported"
        Log.ai.info("""
            Claude CLI transform succeeded (exit \(exitStatus, privacy: .public), \
            model \(model, privacy: .public), thinking tokens \(thinkingTokens, privacy: .public))
            """)
        // Log-only, ratified: the transform succeeded and the text is in hand. A moved telemetry
        // field never withholds it from the user.
        if let warning = success.modelUsage.warning {
            Log.ai.warning("\(warning, privacy: .public)")
        }
    }
}
