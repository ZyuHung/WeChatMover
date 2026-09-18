import Foundation

/// 一个微信实例：主微信（/Applications/WeChat.app）或双开副本
/// （如复制为 WeChat2.app 并把 CFBundleIdentifier 改成 com.tencent.xinWeChat2）。
/// 不同实例的容器、外置数据目录、偏好记录互相独立。
struct WeChatInstance: Hashable, Identifiable, Sendable {
    let bundleID: String
    let appURL: URL

    var id: String { bundleID }

    static let primaryBundleID = "com.tencent.xinWeChat"
    static let primary = WeChatInstance(
        bundleID: primaryBundleID,
        appURL: URL(fileURLWithPath: "/Applications/WeChat.app"))

    var isPrimary: Bool { bundleID == Self.primaryBundleID }

    /// bundle ID 去掉主微信前缀后的部分（主微信为空，com.tencent.xinWeChat2 → "2"）。
    var suffix: String {
        guard bundleID.hasPrefix(Self.primaryBundleID) else { return bundleID }
        return String(bundleID.dropFirst(Self.primaryBundleID.count))
    }

    /// 沙盒容器 Data 根目录：~/Library/Containers/<bundleID>/Data
    var containerRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bundleID)/Data")
    }

    /// 外置数据目录名：主微信 WeChatData，双开 WeChatData2 等，同一目标文件夹下互不冲突。
    var dataFolderName: String {
        let safe = suffix.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return WeChatPaths.defaultDataFolder + safe
    }

    /// 需要迁移的候选子目录（3.x 兼容目录以 bundle ID 命名）。
    var candidateSubdirs: [String] {
        [
            "Documents/xwechat_files",                     // 4.x 主力数据
            "Documents/app_data",
            "Library/Application Support/\(bundleID)",     // 3.x 兼容
        ]
    }

    /// 界面显示名：主微信「微信」，双开「WeChat2」（取 .app 文件名）。
    var displayName: String {
        isPrimary ? "微信" : appURL.deletingPathExtension().lastPathComponent
    }

    /// 偏好键：主微信沿用旧键（兼容已有记录），双开追加 bundle ID。
    func defaultsKey(_ base: String) -> String {
        isPrimary ? base : "\(base).\(bundleID)"
    }

    /// 是否为微信实例的 bundle ID：主微信本身或其无点后缀变体（排除 .WeChatMacShare 等扩展）。
    static func isWeChatBundleID(_ id: String) -> Bool {
        guard id.hasPrefix(primaryBundleID) else { return false }
        return !id.dropFirst(primaryBundleID.count).contains(".")
    }

    /// 由 App 文件名推断双开副本应有的 bundle ID：WeChat2.app → com.tencent.xinWeChat2。
    /// 用于识别「被微信自动升级还原」的副本（此时 Info.plist 已变回主微信的 bundle ID）。
    static func inferredBundleID(forAppNamed name: String) -> String? {
        let base = (name as NSString).deletingPathExtension
        guard base.hasPrefix("WeChat") else { return nil }
        let suffix = base.dropFirst("WeChat".count)
        guard !suffix.isEmpty,
              suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return primaryBundleID + suffix
    }

    /// 扫描应用程序目录，找出主微信与所有双开副本。主微信总在首位（未安装也保留，
    /// 以便界面给出「未检测到微信」提示），其余按 bundle ID 排序。
    ///
    /// 双开副本被微信自动升级整包替换后，bundle ID 会变回 com.tencent.xinWeChat：
    /// 这类「非 WeChat.app 却自称主微信」的包按 `known`（App 路径 → 此前记住的 bundle ID）
    /// 或文件名推断归回原实例，由界面提示「修复双开」。
    static func discover(
        in directories: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ],
        known: [String: String] = [:]
    ) -> [WeChatInstance] {
        var found: [String: WeChatInstance] = [:]
        let fm = FileManager.default
        for dir in directories {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names.sorted() where name.hasSuffix(".app") {
                let app = dir.appendingPathComponent(name, isDirectory: true)
                let plist = app.appendingPathComponent("Contents/Info.plist")
                guard let dict = NSDictionary(contentsOf: plist),
                      var id = dict["CFBundleIdentifier"] as? String,
                      isWeChatBundleID(id) else { continue }
                if id == primaryBundleID, name != "WeChat.app" {
                    guard let intended = known[app.path] ?? inferredBundleID(forAppNamed: name),
                          intended != primaryBundleID, isWeChatBundleID(intended) else { continue }
                    id = intended
                }
                if found[id] == nil {
                    found[id] = WeChatInstance(bundleID: id, appURL: app)
                }
            }
        }
        let primary = found.removeValue(forKey: primaryBundleID) ?? .primary
        return [primary] + found.values.sorted { $0.bundleID < $1.bundleID }
    }
}

/// 微信容器内外的所有路径模型。
enum WeChatPaths {
    /// 主微信（官网 DMG 版）容器内的 Data 根目录。
    static let defaultContainerRoot: URL = WeChatInstance.primary.containerRoot

    /// 主微信的外置数据目录名。
    static let defaultDataFolder = "WeChatData"

    /// 主微信需要迁移的候选子目录（相对容器 Data 根，若存在且非软链则迁移）。
    static let candidateSubdirs: [String] = WeChatInstance.primary.candidateSubdirs

    /// 用户选择的目标文件夹下的数据根目录：<base>/<folder>（默认 WeChatData）
    static func targetRoot(forBase base: URL, folder: String = defaultDataFolder) -> URL {
        base.appendingPathComponent(folder, isDirectory: true)
    }

    /// 某个候选子目录在外置盘上的目标位置：<base>/<folder>/<子目录末级名>
    static func targetDirectory(base: URL, subdir: String, folder: String = defaultDataFolder) -> URL {
        targetRoot(forBase: base, folder: folder)
            .appendingPathComponent((subdir as NSString).lastPathComponent, isDirectory: true)
    }

    /// 候选子目录在容器内的源位置。
    static func sourceDirectory(containerRoot: URL, subdir: String) -> URL {
        containerRoot.appendingPathComponent(subdir, isDirectory: true)
    }

    /// 迁移后保留的本地备份位置：源目录同级、原名加 "_backup" 后缀
    /// （如 xwechat_files → xwechat_files_backup）。
    static func backupDirectory(for source: URL) -> URL {
        source.deletingLastPathComponent()
            .appendingPathComponent(source.lastPathComponent + "_backup", isDirectory: true)
    }
}
