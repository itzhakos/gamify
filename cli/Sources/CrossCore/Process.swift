import Foundation

/// Replace this process with `program` (execve). Only returns on failure.
public func execReplacing(program: String, arguments: [String], environment: [String: String], cwd: String? = nil) -> Never {
    if let cwd, chdir(cwd) != 0 {
        perror("cross: chdir \(cwd)")
        exit(1)
    }
    let argv = ([program] + arguments).map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    execve(program, argv, envp)
    perror("cross: exec \(program)")
    exit(127)
}

/// Run a program to completion and return its exit status.
@discardableResult
public func runWaiting(program: String, arguments: [String], environment: [String: String], cwd: String? = nil,
                quiet: Bool = false) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: program)
    p.arguments = arguments
    p.environment = environment
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    if quiet {
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
    }
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

public func warn(_ message: String) {
    FileHandle.standardError.write(("cross: " + message + "\n").data(using: .utf8)!)
}

/// A fully resolved process launch: what `cross` execve()s and the GUI posix_spawn()s,
/// so both run with the same program, argv, envp and working directory.
public struct Invocation {
    public var program: String
    /// argv[1...]; argv[0] is always `program`, as with execReplacing.
    public var arguments: [String]
    public var environment: [String: String]
    public var cwd: String?

    public init(program: String, arguments: [String], environment: [String: String], cwd: String? = nil) {
        self.program = program
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
    }
}

public func execReplacing(_ invocation: Invocation) -> Never {
    execReplacing(program: invocation.program, arguments: invocation.arguments,
                  environment: invocation.environment, cwd: invocation.cwd)
}

@discardableResult
public func runWaiting(_ invocation: Invocation, quiet: Bool = false) throws -> Int32 {
    try runWaiting(program: invocation.program, arguments: invocation.arguments,
                   environment: invocation.environment, cwd: invocation.cwd, quiet: quiet)
}

/// How a spawned process ended.
public enum Termination: Equatable, CustomStringConvertible {
    case exited(Int32)
    case signaled(Int32)

    init(waitStatus status: Int32) {
        let sig = status & 0x7f
        self = sig == 0 ? .exited((status >> 8) & 0xff) : .signaled(sig)
    }

    public var description: String {
        switch self {
        case .exited(let code): return "exit \(code)"
        case .signaled(let sig): return "signal \(sig)"
        }
    }
}

/// Start `invocation` without replacing or blocking the caller (the GUI's execReplacing):
/// argv[0] = program, exactly `environment` as envp, chdir to `cwd`. stdin is /dev/null;
/// stdout and stderr are appended to `output` (a file, not a pipe, so the child keeps
/// running and logging when the caller quits). The child gets its own process group and
/// default signal dispositions. `onExit` runs on a background thread.
@discardableResult
public func spawnDetached(_ invocation: Invocation, output: URL,
                          onExit: (@Sendable (Termination) -> Void)? = nil) throws -> pid_t {
    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, output.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    posix_spawn_file_actions_adddup2(&actions, 1, 2)
    if let cwd = invocation.cwd {
        posix_spawn_file_actions_addchdir_np(&actions, cwd)
    }

    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    var allSignals = sigset_t(), noSignals = sigset_t()
    sigfillset(&allSignals)
    sigemptyset(&noSignals)
    posix_spawnattr_setsigdefault(&attr, &allSignals)
    posix_spawnattr_setsigmask(&attr, &noSignals)
    posix_spawnattr_setpgroup(&attr, 0)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK |
                                          POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))

    let argv = ([invocation.program] + invocation.arguments).map { strdup($0) } + [nil]
    let envp = invocation.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { (argv + envp).forEach { free($0) } }

    var pid: pid_t = 0
    let rc = posix_spawn(&pid, invocation.program, &actions, &attr, argv, envp)
    guard rc == 0 else {
        throw CrossError("cannot start \(invocation.program): \(String(cString: strerror(rc)))")
    }
    let child = pid
    Thread.detachNewThread {
        var status: Int32 = 0
        while waitpid(child, &status, 0) == -1 && errno == EINTR {}
        onExit?(Termination(waitStatus: status))
    }
    return pid
}
