import SwiftUI
import AppKit
import StratagemCore

struct StratagemIcon: View {
    let entry: Stratagem
    var body: some View {
        Group {
            if let image = GameArtwork.shared.image(for: entry) { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: entry.icon.hasPrefix("/") ? "questionmark.square" : entry.icon).resizable().scaledToFit().foregroundStyle(.yellow) }
        }.frame(width: 26, height: 26)
    }
}
struct ConfigurationView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var category = "全部"
    @State private var showSettings = false
    @State private var batchMode = false
    @State private var selectedIDs: Set<String> = []
    var filtered: [Stratagem] {
        model.entries.filter { (category == "全部" || $0.category == category) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "command.square.fill").foregroundStyle(.yellow).font(.title)
                VStack(alignment: .leading) { Text("STRATAGEM DESK").font(.headline); Text("桌面战备命令终端").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("打开战备终端") { model.showOverlay?() }
                Button("设置", systemImage: "gearshape") { showSettings = true }
                Button(model.dirty ? "保存更改 ●" : "保存", systemImage: "checkmark.circle") { model.save() }.keyboardShortcut("s")
            }.padding()
            if let error = model.hotkeyError {
                HStack {
                    Label(error, systemImage: "keyboard.badge.ellipsis").font(.caption)
                    Spacer()
                    Button("热键设置") { showSettings = true }
                }.padding(10).background(Color.orange.opacity(0.12))
            }
            Divider()
            NavigationSplitView {
                VStack {
                    TextField("搜索战备", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal)
                    Picker("分类", selection: $category) {
                        Text("全部").tag("全部")
                        ForEach(Array(Set(model.entries.map(\.category))).sorted(), id: \.self) { Text($0).tag($0) }
                    }.padding(.horizontal)
                    HStack {
                        Button(batchMode ? "完成选择" : "批量选择") {
                            batchMode.toggle(); selectedIDs.removeAll()
                        }
                        Spacer()
                        if batchMode {
                            Button("全选") { selectedIDs = Set(filtered.map(\.id)) }.disabled(filtered.isEmpty)
                            Button("清空") { selectedIDs.removeAll() }.disabled(selectedIDs.isEmpty)
                        }
                    }.padding(.horizontal)
                    if batchMode {
                        HStack {
                            Text("已选 \(selectedIDs.count) 项").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("启用") { model.setEnabled(true, for: selectedIDs) }
                            Button("停用") { model.setEnabled(false, for: selectedIDs) }
                        }.disabled(selectedIDs.isEmpty).padding(.horizontal)
                    }
                    List(filtered, selection: $model.selection) { entry in
                        HStack(spacing: 10) {
                            if batchMode {
                                Toggle("选择 \(entry.name)", isOn: Binding(
                                    get: { selectedIDs.contains(entry.id) },
                                    set: { if $0 { selectedIDs.insert(entry.id) } else { selectedIDs.remove(entry.id) } }
                                )).toggleStyle(.checkbox).labelsHidden()
                            }
                            StratagemIcon(entry: entry)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.name).lineLimit(1)
                                Text(entry.sequenceText.isEmpty ? "未设置序列" : entry.sequenceText).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if entry.enabled { Circle().fill(.green).frame(width: 7, height: 7).accessibilityLabel("已启用") }
                        }.padding(.vertical, 5).tag(entry.id)
                    }
                    HStack { Button("新建", systemImage: "plus") { model.add() }; Spacer(); Text("\(filtered.count) 项").foregroundStyle(.secondary) }.padding()
                }.padding(.top, 10).navigationSplitViewColumnWidth(min: 245, ideal: 290)
            } detail: {
                if let id = model.selection, model.entry(id) != nil {
                    StratagemEditor(model: model, entry: model.binding(id)).id(id)
                } else {
                    ContentUnavailableView("选择或新建战备", systemImage: "arrow.up.arrow.down", description: Text("配置方向序列和工作流，审核动作后保存。\n默认按住 ⌥⌘S"))
                }
            }
            Divider()
            HStack {
                Text(model.message.isEmpty ? "\(model.entries.filter(\.enabled).count) 个战备已启用 · \(model.dirty ? "有未保存更改" : "已保存的配置用于全局热键")" : model.message).lineLimit(2).font(.caption)
                Spacer()
                if model.loadFailed { Button("备份并恢复默认") { model.restoreDefaults() } }
            }.padding(10)
        }.frame(minWidth: 1000, minHeight: 700)
            .sheet(isPresented: $showSettings) { SettingsView(model: model).frame(width: 640, height: 650) }
            .onChange(of: filtered.map(\.id)) { _, ids in selectedIDs.formIntersection(ids) }
    }
}
struct StratagemEditor: View {
    @ObservedObject var model: AppModel
    @Binding var entry: Stratagem
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    StratagemIcon(entry: entry)
                    Text(entry.name).font(.title2.bold())
                    Spacer()
                    Button("复制") { model.duplicate(entry) }
                    Button("删除", role: .destructive) { model.delete(entry) }
                }
                StratagemProfileView(model: model, entryID: entry.id)
                GroupBox("战备配置") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("名称", text: $entry.name)
                        TextField("分类", text: $entry.category)
                        TextField("说明", text: $entry.description)
                        HStack {
                            TextField("SF Symbol 名称或本地图片路径", text: $entry.icon)
                            Button("选择图片…") {
                                let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .svg, .bmp]
                                if panel.runModal() == .OK, let path = panel.url?.path { entry.icon = path }
                            }
                        }
                        HStack {
                            Text(entry.sequenceText.isEmpty ? "点击方向按钮设置序列" : entry.sequenceText).font(.system(.title3, design: .monospaced)).accessibilityIdentifier("sequencePreview")
                            Spacer()
                            Button("退格") { if !entry.sequence.isEmpty { entry.sequence.removeLast() } }
                            Button("清空") { entry.sequence = [] }
                        }
                        HStack {
                            ForEach(Direction.allCases, id: \.self) { direction in
                                Button(direction.symbol) { if entry.sequence.count < 32 { entry.sequence.append(direction) } }.frame(width: 45)
                            }
                            Spacer()
                            Toggle("启用战备", isOn: $entry.enabled)
                            Toggle("执行前确认", isOn: $entry.confirmation)
                        }
                    }.padding(8).textFieldStyle(.roundedBorder)
                }
                if !model.conflicts.isEmpty {
                    Text(model.conflicts.joined(separator: "\n")).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Text("顺序工作流").font(.title3.bold())
                    Spacer()
                    Menu("复制已有动作") {
                        ForEach(model.configuration.actions) { action in
                            Button(action.name) { model.copyAction(action, to: entry.id) }
                        }
                    }
                    Menu("添加步骤") { ForEach(ActionKind.allCases, id: \.self) { kind in Button(kind.title) { model.addAction(kind, to: entry.id) } } }
                }
                Text("动作编辑仅影响此战备，修改内容后需重新审核。参数不会进行 Shell 字符串拼接。").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(entry.steps.enumerated()), id: \.element.id) { index, step in
                    if let binding = model.actionBinding(step, for: entry.id) {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("\(index + 1). \(binding.wrappedValue.kind.title)").font(.headline)
                                    Spacer()
                                    Button("↑") { entry.steps.swapAt(index, index - 1) }.disabled(index == 0)
                                    Button("↓") { entry.steps.swapAt(index, index + 1) }.disabled(index + 1 == entry.steps.count)
                                    Button("测试此步") { model.testStep(step) }.disabled(model.executor.runningID != nil)
                                    Button("移除") { entry.steps.removeAll { $0.id == step.id } }
                                }
                                ActionEditor(action: binding)
                                HStack {
                                    Toggle("失败后继续", isOn: stepBinding(step).continueOnFailure)
                                    Spacer()
                                    Text("步骤后延迟（秒）")
                                    TextField("秒", value: stepBinding(step).delayAfter, format: .number).frame(width: 80)
                                }
                            }.padding(8)
                        }
                    }
                }
                if entry.steps.isEmpty { Text("添加动作，将方向序列绑定到系统命令。").foregroundStyle(.secondary).padding(.vertical) }
                HStack {
                    Button("预览并测试工作流", systemImage: "play.fill") { model.run(entry) }.disabled(entry.steps.isEmpty)
                    Text("测试使用当前编辑内容；热键使用已保存内容。").font(.caption).foregroundStyle(.secondary)
                }
                ExecutionLogView(executor: model.executor)
            }.padding(22)
        }
    }
    private func stepBinding(_ step: WorkflowStep) -> Binding<WorkflowStep> {
        Binding(get: { entry.steps.first(where: { $0.id == step.id }) ?? step }, set: { value in
            guard let index = entry.steps.firstIndex(where: { $0.id == step.id }) else { return }
            entry.steps[index] = value
        })
    }
}
struct StratagemProfileView: View {
    @ObservedObject var model: AppModel
    let entryID: String
    var body: some View {
        let original = model.defaultProfile(entryID)
        let current = model.configuration.profile(for: entryID, builtins: model.builtins)
        let saved = model.savedProfile(entryID)
        let unchanged = saved.map { current?.equivalent(to: $0) == true } ?? false
        return VStack(alignment: .leading, spacing: 8) {
            Text("独立状态档案").font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        snapshot("默认", profile: original)
                        Text(model.builtins.contains(where: { $0.id == entryID }) ? "出厂配置" : "自定义战备的空白模板").font(.caption2).foregroundStyle(.secondary)
                        Button("恢复默认") { model.restoreProfile(entryID, useDefault: true) }
                            .disabled(current?.equivalent(to: original) == true)
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        snapshot("当前", profile: current)
                        Text(unchanged ? "与已保存一致" : "尚未保存的内容").font(.caption2).foregroundStyle(unchanged ? Color.secondary : Color.orange)
                        Button("保存此战备") { model.saveProfile(entryID) }.disabled(unchanged || model.loadFailed)
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        snapshot("已保存", profile: saved)
                        Text("终端使用此状态").font(.caption2).foregroundStyle(.secondary)
                        Button("撤销此战备更改") { model.restoreProfile(entryID, useDefault: false) }
                            .disabled(saved == nil || unchanged)
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                }.fixedSize(horizontal: false, vertical: true)
                Text("恢复只修改当前内容；单独保存通过校验后生效。顶部“保存”仍保存全部更改。").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }
    @ViewBuilder private func snapshot(_ title: String, profile: StratagemProfile?) -> some View {
        Text(title).font(.headline)
        if let profile {
            Text(profile.entry.name).font(.caption.bold()).lineLimit(2)
            Text(profile.entry.sequenceText.isEmpty ? "未设置序列" : profile.entry.sequenceText)
                .font(.system(.caption, design: .monospaced))
            Text("\(profile.entry.enabled ? "已启用" : "已停用") · \(profile.entry.steps.count) 个步骤").font(.caption)
            DisclosureGroup("配置与操作") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("分类：\(profile.entry.category)")
                    Text("图标：\(profile.entry.icon)").textSelection(.enabled)
                    if !profile.entry.description.isEmpty { Text(profile.entry.description) }
                    Text(profile.entry.confirmation ? "执行前确认" : "直接执行")
                    ForEach(Array(profile.entry.steps.enumerated()), id: \.element.id) { index, step in
                        if let action = profile.actions.first(where: { $0.id == step.actionID }) {
                            Text("\(index + 1). \(action.sensitive ? "敏感动作" : action.name) · \(action.kind.title)").bold()
                            Text(action.preview).textSelection(.enabled)
                            Text("\(action.approved ? "已审核" : "未审核") · 超时 \(action.timeout, specifier: "%g")s")
                            Text("失败后\(step.continueOnFailure ? "继续" : "停止") · 延迟 \(step.delayAfter, specifier: "%g")s")
                        } else { Text("缺失动作").foregroundStyle(.red) }
                    }
                }.font(.caption2).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.caption)
        } else { Text("尚无保存档案").font(.caption).foregroundStyle(.secondary) }
    }
}
struct ActionEditor: View {
    @Binding var action: ActionDefinition
    @State private var environmentError = ""
    @State private var environmentText: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("动作名称", text: $action.name)
            switch action.kind {
            case .shell:
                TextField("Shell 绝对路径", text: $action.shell)
                Text("脚本（$1、$2… 为下方参数）").font(.caption)
                TextEditor(text: $action.target).font(.system(.body, design: .monospaced)).frame(minHeight: 95).border(.quaternary)
            case .delay:
                HStack { Text("延迟秒数"); TextField("秒", value: $action.seconds, format: .number) }
            case .notification:
                TextField("通知 / 状态文本", text: $action.target)
            default:
                TextField(targetLabel, text: $action.target)
            }
            if [.shell, .executable, .application, .shortcut].contains(action.kind) {
                Text("参数：每行一个参数，不需要 Shell 引号").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { action.arguments.joined(separator: "\n") }, set: { action.arguments = $0.isEmpty ? [] : $0.components(separatedBy: "\n") }))
                    .font(.system(.caption, design: .monospaced)).frame(height: 52).border(.quaternary)
            }
            if [.shell, .executable, .shortcut].contains(action.kind) {
                TextField("工作目录（留空为用户主目录）", text: $action.workingDirectory)
                DisclosureGroup("环境变量（JSON 对象）") {
                    TextEditor(text: $environmentText).font(.system(.caption, design: .monospaced)).frame(height: 70)
                        .onChange(of: environmentText) { _, text in
                            do { action.environment = try JSONDecoder().decode([String: String].self, from: Data(text.utf8)); environmentError = "" }
                            catch { environmentError = "环境变量 JSON 无效；未应用此修改"; action.approved = false }
                        }
                    if !environmentError.isEmpty { Text(environmentError).foregroundStyle(.red).font(.caption) }
                }
            }
            HStack {
                Text("动作超时（秒）")
                TextField("秒", value: $action.timeout, format: .number).frame(width: 80)
                Spacer()
                Toggle("敏感：隐藏输出及导出参数", isOn: $action.sensitive)
            }
            Toggle("我已审核此动作，允许执行", isOn: $action.approved).disabled(!environmentError.isEmpty).foregroundStyle(action.approved ? Color.primary : Color.orange)
        }.textFieldStyle(.roundedBorder)
        .onAppear {
            let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
            environmentText = String(data: (try? e.encode(action.environment)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
        }
    }
    var targetLabel: String {
        switch action.kind {
        case .application: return "应用 .app 绝对路径或 Bundle ID"
        case .open: return "URL、URL Scheme 或文件 / 目录绝对路径"
        case .shortcut: return "快捷指令名称"
        default: return "可执行文件绝对路径"
        }
    }
}
struct ExecutionLogView: View {
    @ObservedObject var executor: WorkflowExecutor
    var body: some View {
        GroupBox("执行结果") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if executor.runningID != nil { ProgressView().controlSize(.small) }
                    Text(executor.summary).font(.headline)
                    Spacer()
                    if executor.runningID != nil { Button("取消工作流", role: .destructive) { executor.cancel() } }
                }
                ForEach(executor.logs) { log in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(log.name) · \(log.status.rawValue)").font(.caption.bold())
                        Text(log.detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(8).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}
