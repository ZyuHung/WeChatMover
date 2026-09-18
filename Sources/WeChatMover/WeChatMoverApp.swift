import SwiftUI
import AppKit

@main
struct WeChatMoverApp: App {
    @StateObject private var store = InstanceStore()

    var body: some Scene {
        WindowGroup("WeChatMover") {
            InstanceRootView()
                .environmentObject(store)
                .frame(minWidth: 760, minHeight: 580)
        }
        .defaultSize(width: 920, height: 720)
        .windowResizability(.contentSize)
    }
}

/// 微信实例（主微信 + 双开副本）与各自的视图模型。
/// 每个实例一个独立 AppViewModel：切换实例不打断另一个实例进行中的操作，日志也各自保留。
@MainActor
final class InstanceStore: ObservableObject {
    @Published private(set) var instances: [WeChatInstance] = []
    @Published var selectedID: String = WeChatInstance.primaryBundleID
    private var viewModels: [String: AppViewModel] = [:]
    private let defaults: UserDefaults
    /// 记住的双开副本：App 路径 → bundle ID。副本被微信升级还原后 bundle ID 丢失，靠它归回原实例。
    static let knownInstancesKey = "knownDualInstances"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rescan()
    }

    /// 重新扫描应用程序目录（新装了双开副本、或副本被升级还原后可刷新出来）。
    func rescan() {
        var known = defaults.dictionary(forKey: Self.knownInstancesKey) as? [String: String] ?? [:]
        let found = WeChatInstance.discover(known: known)
        for instance in found where !instance.isPrimary {
            known[instance.appURL.path] = instance.bundleID
        }
        defaults.set(known, forKey: Self.knownInstancesKey)
        if found != instances { instances = found }
        if !instances.contains(where: { $0.id == selectedID }) {
            selectedID = WeChatInstance.primaryBundleID
        }
    }

    var selected: WeChatInstance {
        instances.first { $0.id == selectedID } ?? .primary
    }

    func viewModel(for instance: WeChatInstance) -> AppViewModel {
        if let vm = viewModels[instance.id] { return vm }
        let vm = AppViewModel(instance: instance)
        viewModels[instance.id] = vm
        return vm
    }
}

/// 根视图：检测到双开时顶部显示实例切换；下方为所选实例的完整仪表盘。
struct InstanceRootView: View {
    @EnvironmentObject var store: InstanceStore

    var body: some View {
        let vm = store.viewModel(for: store.selected)
        VStack(spacing: 0) {
            if store.instances.count > 1 {
                HStack {
                    Picker("微信实例", selection: $store.selectedID) {
                        ForEach(store.instances) { instance in
                            Text(instance.displayName).tag(instance.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Text("\(store.selected.appURL.path) · 外置目录 \(store.selected.dataFolderName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, DesignTokens.Spacing.xl)
                .padding(.vertical, DesignTokens.Spacing.sm)
                Divider()
            }
            ContentView()
                .environmentObject(vm)
                .id(vm.instance.id)
        }
        .onAppear {
            store.rescan()
            store.viewModel(for: store.selected).refresh()
        }
        .onChange(of: store.selectedID) { _ in
            store.viewModel(for: store.selected).refresh()
        }
        // 切回本 App 时轻量复检：微信刚自动升级、双开副本被还原时立刻提示「修复双开」
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            store.rescan()
            store.viewModel(for: store.selected).refreshWeChatInfo()
        }
    }
}
