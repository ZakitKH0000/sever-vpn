import SwiftUI
import UniformTypeIdentifiers

enum SeverStyle {
    static let background = Color(red: 0.035, green: 0.055, blue: 0.085)
    static let panel = Color(red: 0.075, green: 0.10, blue: 0.14)
    static let accent = Color(red: 0.40, green: 0.87, blue: 0.74)
}

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var vpn: VPNController
    @State private var settings = false
    var body: some View {
        TabView {
            HomeView().tabItem { Label("Подключение", systemImage: "power.circle") }
            ServersView().tabItem { Label("Серверы", systemImage: "globe.europe.africa") }
            DiagnosticsView().tabItem { Label("Проверка", systemImage: "waveform.path.ecg") }
        }
        .sheet(isPresented: $settings) { SettingsView() }
        .alert("Север", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("Понятно") { store.message = nil }
        } message: { Text(store.message ?? "") }
    }
}

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var vpn: VPNController
    @State private var settings = false
    @State private var connecting = false
    private var statusTitle: String {
        switch vpn.status {
        case .connected: return "Туннель включён"
        case .connecting: return "Подключаемся"
        case .reasserting: return "Восстанавливаем связь"
        case .disconnecting: return "Отключаемся"
        default: return "Готов к подключению"
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    HStack(spacing: 9) {
                        Image(systemName: "location.north.circle.fill").foregroundStyle(SeverStyle.accent)
                        Text("СЕВЕР").font(.headline).tracking(5)
                        Spacer()
                        Text("Личный VPN").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 18) {
                        ZStack {
                            Circle().stroke(SeverStyle.accent.opacity(0.10), lineWidth: 22).frame(width: 174, height: 174)
                            Circle().stroke(SeverStyle.accent.opacity(vpn.isActive ? 0.75 : 0.2), lineWidth: 1).frame(width: 148, height: 148)
                            Image(systemName: "power").font(.system(size: 49, weight: .light)).foregroundStyle(vpn.isActive ? SeverStyle.accent : .secondary)
                        }.padding(.top, 20)
                        Text(statusTitle).font(.title2.weight(.semibold))
                        Text(vpn.status == .connected ? "Проверьте доступ в интернет во вкладке «Проверка»" : "Выберите сервер и включите подключение")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button {
                            connecting = true
                            Task {
                                defer { connecting = false }
                                do {
                                    if vpn.isActive { try await vpn.disconnect() }
                                    else {
                                        if store.selected == nil { await store.updateFreeServers() }
                                        try await vpn.connect(envelope: store.envelope(), name: store.selected?.name ?? "Север")
                                    }
                                } catch let error as SeverError { store.message = error.localizedDescription }
                                catch { store.message = VPNFailure.text(error) }
                            }
                        } label: {
                            HStack { if connecting { ProgressView().tint(.black) }; Text(vpn.isActive ? "Выключить" : "Подключиться").fontWeight(.semibold) }.frame(maxWidth: .infinity).padding(.vertical, 7)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(connecting || vpn.status == .disconnecting)
                        if !vpn.phase.isEmpty { Text(vpn.phase).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                        if let error = vpn.lastError { Text(error).font(.footnote).foregroundStyle(.orange).textSelection(.enabled) }
                    }.padding(22).background(SeverStyle.panel, in: RoundedRectangle(cornerRadius: 26))

                    HStack {
                        Image(systemName: "globe").font(.title2).foregroundStyle(SeverStyle.accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(vpn.isActive ? vpn.activeName : (store.selected?.name ?? "Сервер пока не выбран")).font(.headline)
                            Text(vpn.isActive ? "Активное подключение" : (store.selected.map { "\($0.engineLabel) · \($0.nodes) узл." } ?? "Обновите каталог во вкладке «Серверы»")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.busy { ProgressView() }
                    }.padding(18).background(SeverStyle.panel, in: RoundedRectangle(cornerRadius: 20))
                    Label("При потере связи — переподключение без прямого резервного маршрута", systemImage: "lock.shield")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Бесплатные узлы VPN Gate предоставляют добровольцы. Скорость и доступность меняются; владельцы ведут журналы соединений.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(20)
            }
            .background(SeverStyle.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { settings = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Настройки") } }
            .sheet(isPresented: $settings) { SettingsView() }
        }
    }
}

struct ServersView: View {
    @EnvironmentObject private var store: AppStore
    @State private var importing = false
    @State private var addSheet = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { Task { await store.updateFreeServers() } } label: { Label("Обновить бесплатные серверы", systemImage: "arrow.clockwise") }.disabled(store.busy)
                    Button { Task { await store.chooseFastest() } } label: { Label("Выбрать по отклику TCP", systemImage: "bolt") }.disabled(store.busy || store.profiles.isEmpty)
                    if !store.catalogStatus.isEmpty {
                        HStack(spacing: 10) { if store.busy { ProgressView() }; Text(store.catalogStatus).font(.footnote) }
                    }
                    if let date = store.state.feedUpdatedAt { Text("Список от " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    if let error = store.catalogError {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Обновление не выполнено", systemImage: "exclamationmark.arrow.triangle.2.circlepath").font(.footnote.weight(.semibold))
                            Text(error).font(.caption).textSelection(.enabled)
                        }.foregroundStyle(.orange)
                    }
                    if let warning = store.storageWarning { Text(warning).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                } footer: { Text("Отклик TCP проверяет доступность порта, а не скорость или успешность VPN. Список обновляется при открытии приложения, не чаще раза в час. Выбор сервера применяется при следующем подключении.") }
                Section("Подключения · \(store.profiles.count)") {
                    if store.profiles.isEmpty { Text(store.catalogError == nil ? "Список загружается. Причина возможной ошибки появится выше" : "Список недоступен. Подробности ошибки указаны выше; можно импортировать профиль").foregroundStyle(.secondary) }
                    ForEach(store.profiles) { profile in
                        Button { store.selectedID = profile.id } label: {
                            HStack(spacing: 12) {
                                Image(systemName: profile.id == store.selected?.id ? "checkmark.circle.fill" : "circle").foregroundStyle(profile.id == store.selected?.id ? SeverStyle.accent : .secondary)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(profile.name).foregroundStyle(.primary).lineLimit(2)
                                    Text(profile.engineLabel + (profile.source == "vpngate" ? " · VPN Gate" : " · Импорт")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let latency = profile.latency { Text("\(latency) мс").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                            }.padding(.vertical, 5)
                        }
                    }
                }
            }.scrollContentBackground(.hidden).background(SeverStyle.background)
            .navigationTitle("Серверы")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu { Button("Импортировать файл") { importing = true }; Button("Вставить конфигурацию или подписку") { addSheet = true } } label: { Image(systemName: "plus") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .data], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.fileSizeKey])
                    guard (values.fileSize ?? 0) <= 4 * 1024 * 1024 else { throw SeverError.message("Файл больше 4 МБ") }
                    let text = try String(contentsOf: url, encoding: .utf8)
                    try store.importText(text)
                } catch let error as SeverError { store.message = error.localizedDescription }
                catch { store.message = "Не удалось прочитать файл конфигурации" }
            }
            .sheet(isPresented: $addSheet) { ImportView() }
        }
    }
}

struct ImportView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var working = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Конфигурация или HTTPS-подписка") { TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minHeight: 220).autocorrectionDisabled().textInputAutocapitalization(.never) }
                Section { Text("Xray JSON, ссылки VLESS/Trojan, Base64-список или OpenVPN со встроенными сертификатами. Ссылка подписки и параметры доступа сохраняются зашифрованными на устройстве.").font(.footnote).foregroundStyle(.secondary) }
                Button(working ? "Импортируем…" : "Добавить") {
                    working = true
                    Task {
                        defer { working = false }
                        do {
                            if text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("https://") { try await store.addSubscription(text) }
                            else { try store.importText(text) }
                            dismiss()
                        } catch let error as SeverError { store.message = error.localizedDescription }
                        catch { store.message = "Импорт не выполнен. Проверьте формат и доступность источника" }
                    }
                }.disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.navigationTitle("Добавить профиль").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var vpn: VPNController
    var body: some View {
        NavigationStack {
            List {
                Section("Последнее подключение") {
                    Text(vpn.phase.isEmpty ? "VPN ещё не запускался" : vpn.phase).font(.footnote)
                    if let error = vpn.lastError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                    Button("Получить причину отключения iOS") { Task { await vpn.readLastError() } }
                }
                Section {
                    Button { Task { await store.diagnose() } } label: { Label(store.checking ? "Проверяем…" : "Проверить доступ в интернет", systemImage: "waveform.path.ecg") }.disabled(store.checking)
                    ForEach(store.checks) { check in
                        HStack { Image(systemName: check.ok ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(check.ok ? SeverStyle.accent : .orange); Text(check.title); Spacer(); Text(check.ok ? "\(check.milliseconds) мс" : "Нет ответа").font(.caption).foregroundStyle(.secondary) }
                    }
                } footer: { Text("Проверяются только три заранее заданных адреса Cloudflare, Google и Apple. История ваших посещений не собирается. Успех этих проверок не гарантирует доступность каждого сайта.") }
                Section {
                    Button { Task { await store.askAI(tunnelStatus: vpn.statusCode) } } label: { Label(store.aiBusy ? "Анализируем…" : "Проанализировать", systemImage: "sparkles") }.disabled(store.aiBusy || store.checks.isEmpty)
                    if !store.explanation.isEmpty { Text(store.explanation).textSelection(.enabled) }
                } header: { Text("Помощник ИИ") } footer: { Text("Только по этой кнопке выбранному ИИ-сервису отправятся результаты проверок. Конфигурации, ключи, адреса серверов и история в отчёт не входят. Советы не применяются автоматически. Используется ваш API-ключ; бесплатность зависит от тарифа сервиса.") }
            }.scrollContentBackground(.hidden).background(SeverStyle.background).navigationTitle("Проверка")
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var settings = AISettings()
    @State private var showingLicenses = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("HTTPS-адрес API /chat/completions", text: $settings.endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Название модели", text: $settings.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API-ключ", text: $settings.key).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("ИИ по желанию") } footer: { Text("Без ИИ работают импорт, подключение, выбор серверов и проверка связи. Выбирайте API с подходящим бесплатным тарифом. Ключ хранится в Keychain.") }
                Section("О приложении") {
                    LabeledContent("Версия", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.2")
                    Link("Бесплатная сеть VPN Gate", destination: URL(string: "https://www.vpngate.net/en/about_abuse.aspx")!)
                    Button("Открытый код и лицензии") { showingLicenses = true }
                    Text("Проверка поведения при обрыве на iPhone ещё требуется. Пока не считайте эту сборку гарантией отсутствия утечек.").font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("Настройки").navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $showingLicenses) { LicensesView() }
                .task { do { settings = try AISettings.load() } catch { store.message = "Не удалось прочитать настройки ИИ" } }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Сохранить") {
                        do { try settings.save(); dismiss() } catch { store.message = "Не удалось сохранить настройки ИИ" }
                    } }
                }
        }
    }
}

struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss
    private let files = ["AGPL-3.0", "LibXray-MIT", "Xray-MPL-2.0", "ThirdParty"]
    var body: some View {
        NavigationStack {
            List(files, id: \.self) { file in
                NavigationLink(file) {
                    ScrollView {
                        Text(text(file)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding()
                    }.navigationTitle(file).navigationBarTitleDisplayMode(.inline)
                }
            }.navigationTitle("Лицензии").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }
    private func text(_ file: String) -> String {
        guard let url = Bundle.main.url(forResource: file, withExtension: "txt"), let value = try? String(contentsOf: url, encoding: .utf8) else { return "Текст лицензии не найден в сборке" }
        return value
    }
}
