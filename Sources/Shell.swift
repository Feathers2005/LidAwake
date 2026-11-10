import Foundation

/// 一次子进程调用的结果。
struct ProcResult {
    let status: Int32
    let out: String
    let err: String

    var ok: Bool { status == 0 }

    /// 给用户看的一段错误/输出文本。
    var message: String {
        let o = out.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = err.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { return e }
        if !o.isEmpty { return o }
        return "退出码 \(status)"
    }
}

enum Shell {
    /// 同步执行一个命令，带超时。绝不在主线程调用。
    @discardableResult
    static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 300) -> ProcResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return ProcResult(status: -1, out: "", err: "无法执行 \(launchPath)：\(error.localizedDescription)")
        }

        let sem = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in sem.signal() }

        if sem.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = sem.wait(timeout: .now() + 2)
            _ = outPipe.fileHandleForReading.readDataToEndOfFile()
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            return ProcResult(status: -2, out: "", err: "操作超时（\(Int(timeout)) 秒未完成）")
        }

        // 进程已退出，读干净两个管道（输出很小，不会撑满缓冲区）。
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return ProcResult(
            status: process.terminationStatus,
            out: String(data: outData, encoding: .utf8) ?? "",
            err: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// 把字符串安全地放进 sh 的单引号里。
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
