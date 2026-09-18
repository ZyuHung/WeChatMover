import Foundation
import AppKit

/// 修复双开：微信自动升级会整包替换双开副本（如 WeChat2.app），
/// bundle ID 变回 com.tencent.xinWeChat、签名变回官方，副本从此只会唤起主微信。
/// 修复 = 改回副本的 bundle ID → 重新登记到 LaunchServices →（调用方）ad-hoc 重签名。
///
/// 与重签名一样在进程内直接执行、不提权：WeChat2.app 所有者是当前用户，
/// 真正需要的是 WeChatMover 自身的「App 管理」权限。
enum DualInstanceRepairer {
    static let plistBuddy = URL(fileURLWithPath: "/usr/libexec/PlistBuddy")
    static let lsregister = URL(fileURLWithPath:
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")

    static func plistBuddyArguments(bundleID: String, appPath: String) -> [String] {
        ["-c", "Set :CFBundleIdentifier \(bundleID)", appPath + "/Contents/Info.plist"]
    }

    /// 包不可写或未授权时在终端里执行的完整兜底命令（改 bundle ID + 重签名）。
    static func terminalCommand(bundleID: String, appPath: String) -> String {
        let plist = CodeSigner.shellQuoted(appPath + "/Contents/Info.plist")
        return "/usr/libexec/PlistBuddy -c \"Set :CFBundleIdentifier \(bundleID)\" \(plist)"
            + " && " + CodeSigner.shellCommand(appPath: appPath)
    }

    /// 改写副本 Info.plist 的 CFBundleIdentifier（异步，completion 在后台线程回调）。
    /// 结果分类与 codesign 一致：TCC 拒绝同样表现为 Operation not permitted。
    static func setBundleIdentifier(
        _ bundleID: String, appPath: String,
        completion: @escaping @Sendable (CodeSigner.ResignResult) -> Void
    ) {
        CodeSigner.run(
            executableURL: plistBuddy,
            arguments: plistBuddyArguments(bundleID: bundleID, appPath: appPath),
            completion: completion)
    }

    /// 让 LaunchServices 立即按新 bundle ID 重新登记（尽力而为，失败不影响修复结果）。
    static func register(appPath: String) {
        let process = Process()
        process.executableURL = lsregister
        process.arguments = ["-f", appPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// 按 App 路径找运行中的进程：被还原的副本 bundle ID 与主微信相同，不能按 bundle ID 找，
    /// 否则会误退主微信。
    static func runningApps(at appURL: URL) -> [NSRunningApplication] {
        let target = appURL.standardizedFileURL.resolvingSymlinksInPath().path
        return NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == target
        }
    }

    /// 退出该路径下的副本（优雅 → 超时强杀），只影响这一个 App。
    static func ensureQuit(appURL: URL) async -> Bool {
        await WeChatQuitter.ensureQuit(
            isRunning: { !runningApps(at: appURL).isEmpty },
            graceful: { runningApps(at: appURL).forEach { $0.terminate() } },
            force: { runningApps(at: appURL).forEach { $0.forceTerminate() } })
    }
}
