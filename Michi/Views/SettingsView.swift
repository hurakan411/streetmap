import CoreLocation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDeletion = false
    @State private var pendingRecordingMode: RecordingMode?
    @State private var permissionStatusForAlert: CLAuthorizationStatus = .notDetermined
    @State private var showsPermissionAlert = false

    var body: some View {
        NavigationStack {
            ZStack {
                store.theme.backgroundColor.ignoresSafeArea()

                Circle()
                    .fill(store.theme.interactionColor.opacity(0.12))
                    .frame(width: 300, height: 300)
                    .blur(radius: 90)
                    .offset(x: 150, y: -250)
                    .allowsHitTesting(false)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 32) {
                        settingsHero

                        sectionTitle("00", "言語", "アプリの表示言語")
                        HStack(spacing: 12) {
                            Image(systemName: "globe")
                                .foregroundStyle(store.theme.interactionColor)
                                .frame(width: 24)
                            Picker("表示言語", selection: $store.appLanguage) {
                                Text("日本語").tag(AppLanguage.japanese)
                                Text("English").tag(AppLanguage.english)
                            }
                            .pickerStyle(.menu)
                            .tint(store.theme.interactionColor)
                            Spacer()
                        }
                        .font(.system(size: 15, weight: .medium))
                        .padding(16)
                        .background(store.theme.controlBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(store.theme.controlBorder, lineWidth: 1))

                        sectionTitle("01", "地図のスタイル", "色、線、地図の空気感")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(AppTheme.allCases) { theme in
                                    ThemeCard(
                                        theme: theme,
                                        isSelected: store.theme == theme,
                                        action: { withAnimation(.snappy) { store.theme = theme } }
                                    )
                                }
                            }
                            .padding(.horizontal, 1)
                            .padding(.vertical, 3)
                        }

                        Toggle(isOn: $store.showsPointsOfInterest) {
                            HStack(spacing: 12) {
                                Image(systemName: "mappin.and.ellipse")
                                    .foregroundStyle(store.theme.interactionColor)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("お店・施設を表示")
                                        .font(.system(size: 15, weight: .medium))
                                    Text("Appleマップのお店、駅、施設名を表示します")
                                        .font(.system(size: 12, weight: .regular))
                                        .foregroundStyle(store.theme.foregroundColor.opacity(0.52))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .tint(store.theme.interactionColor)
                        .padding(16)
                        .background(store.theme.controlBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(store.theme.controlBorder, lineWidth: 1))

                        sectionTitle("02", "記録モード", "アプリを閉じたあとの動作")
                        VStack(spacing: 10) {
                            ForEach(RecordingMode.allCases) { mode in
                                RecordingModeCard(
                                    mode: mode,
                                    isSelected: store.recordingMode == mode,
                                    isPending: pendingRecordingMode == mode,
                                    theme: store.theme
                                ) {
                                    selectRecordingMode(mode)
                                }
                            }
                        }

                        if !hasRequiredPermission(for: store.recordingMode, status: store.recorder.authorizationStatus) {
                            Label("選択中のモードに必要な位置情報権限がありません", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 4)
                        }

                        sectionTitle("03", "記録する移動", "速度で残す経路を選別")
                        VStack(spacing: 10) {
                            ForEach(MovementCaptureMode.allCases) { mode in
                                MovementCaptureModeCard(
                                    mode: mode,
                                    isSelected: store.movementCaptureMode == mode,
                                    theme: store.theme
                                ) {
                                    withAnimation(.snappy) { store.setMovementCaptureMode(mode) }
                                }
                            }
                        }

                        Text("GPSが検出した速度を基準に、新しく記録する地点を選別します。上限を超えた区間では経路を自動的に区切り、既存の履歴は変更しません。")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(store.theme.foregroundColor.opacity(0.52))
                            .lineSpacing(3)
                            .padding(.horizontal, 4)

                        sectionTitle("02", "位置情報", "権限と記録データの状態")
                        VStack(spacing: 0) {
                            AuthorizationRow(recorder: store.recorder, theme: store.theme)

                            if store.estimatedTrackCount > 0 {
                                Divider().padding(.leading, 52)
                                Label {
                                    HStack {
                                        Text("推定経路")
                                            .font(.system(size: 15, weight: .medium))
                                        Spacer()
                                        Text("\(store.estimatedTrackCount)区間")
                                            .font(.system(size: 12, weight: .regular))
                                            .foregroundStyle(store.theme.foregroundColor.opacity(0.52))
                                    }
                                } icon: {
                                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                                        .foregroundStyle(.orange)
                                }
                                .padding(16)
                            }
                        }
                        .background(store.theme.controlBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(store.theme.controlBorder, lineWidth: 1))

                        sectionTitle("05", "データとプライバシー", "この端末に保存される情報")
                        VStack(spacing: 0) {
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("端末内に保存")
                                        .font(.system(size: 15, weight: .semibold))
                                    Text("移動履歴はiCloudへ同期せず、この端末だけに保存します。")
                                        .font(.system(size: 12, weight: .regular))
                                        .foregroundStyle(store.theme.foregroundColor.opacity(0.52))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            } icon: {
                                Image(systemName: "iphone.gen3")
                                    .foregroundStyle(store.theme.interactionColor)
                            }
                            .padding(16)

                            Divider().padding(.leading, 52)

                            Button(role: .destructive) { confirmsDeletion = true } label: {
                                Label("すべての記録履歴を削除", systemImage: "trash")
                                    .font(.system(size: 15, weight: .medium))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                            }

                            #if DEBUG
                            Divider().padding(.leading, 52)
                            Button { store.addSampleHistory() } label: {
                                Label("プレビュー用サンプルを追加", systemImage: "sparkles")
                                    .font(.system(size: 15, weight: .medium))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                            }
                            Divider().padding(.leading, 52)
                            Button { restartOnboardingForDebug() } label: {
                                Label("オンボーディングを再表示", systemImage: "arrow.counterclockwise.circle")
                                    .font(.system(size: 15, weight: .medium))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                            }
                            #endif
                        }
                        .background(store.theme.controlBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(store.theme.controlBorder, lineWidth: 1))

                        sectionTitle("06", "アプリについて", "ポリシーとバージョン情報")
                        VStack(spacing: 0) {
                            NavigationLink {
                                PrivacyPolicyView(theme: store.theme)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "hand.raised.square.fill")
                                        .foregroundStyle(store.theme.interactionColor)
                                        .frame(width: 24)
                                    Text("プライバシーポリシー")
                                        .font(.system(size: 15, weight: .medium))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(store.theme.foregroundColor.opacity(0.3))
                                }
                                .padding(16)
                            }
                            .buttonStyle(.plain)

                            Divider().padding(.leading, 52)

                            HStack(spacing: 12) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(store.theme.interactionColor)
                                    .frame(width: 24)
                                Text("バージョン")
                                    .font(.system(size: 15, weight: .medium))
                                Spacer()
                                Text(appVersionText)
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(store.theme.foregroundColor.opacity(0.52))
                            }
                            .padding(16)
                        }
                        .background(store.theme.controlBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(store.theme.controlBorder, lineWidth: 1))

                        settingsNotes
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 36)
                    .foregroundStyle(store.theme.foregroundColor)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 34, height: 34)
                            .background(store.theme.controlBackground, in: Circle())
                            .overlay(Circle().stroke(store.theme.controlBorder, lineWidth: 1))
                    }
                    .accessibilityLabel("閉じる")
                }
            }
        }
        .tint(store.theme.interactionColor)
        .onReceive(store.recorder.$authorizationStatus) { status in
            handleAuthorizationChange(status)
        }
        .alert(LocalizedStringKey(permissionAlertTitle), isPresented: $showsPermissionAlert) {
            if shouldOpenSystemSettings {
                Button("設定を開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            } else {
                Button("続ける") {
                    beginPermissionRequest()
                }
            }
            Button("キャンセル", role: .cancel) {
                pendingRecordingMode = nil
            }
        } message: {
            Text(LocalizedStringKey(permissionAlertMessage))
        }
        .alert("記録履歴を削除しますか？", isPresented: $confirmsDeletion) {
            Button("削除", role: .destructive) { store.deleteAllHistory() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この操作は取り消せません。デザイン設定は残ります。")
        }
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    #if DEBUG
    private func restartOnboardingForDebug() {
        dismiss()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .michiRestartOnboarding, object: nil)
        }
    }
    #endif

    private var settingsHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("設定")
                .font(.system(size: 38, weight: .light))

            HStack(spacing: 8) {
                                    Label(LocalizedStringKey(store.recordingMode.title), systemImage: store.recordingMode.symbol)
                Circle().frame(width: 3, height: 3).opacity(0.35)
                Text(LocalizedStringKey(store.movementCaptureMode.title))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(store.theme.foregroundColor.opacity(0.62))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(store.theme.controlBackground, in: Capsule())
            .overlay(Capsule().stroke(store.theme.controlBorder, lineWidth: 1))
        }
        .padding(.top, 10)
    }

    private func sectionTitle(_ number: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(store.theme.interactionColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 17, weight: .semibold))
                Text(LocalizedStringKey(subtitle))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(store.theme.foregroundColor.opacity(0.46))
            }
            Rectangle()
                .fill(store.theme.controlBorder)
                .frame(height: 1)
        }
        .padding(.horizontal, 2)
    }

    private var settingsNotes: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("道路への補正には、速度に応じてAppleマップの徒歩／自動車経路を利用します。")
            } icon: {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .foregroundStyle(store.theme.interactionColor)
            }
            Label {
                Text("常時記録は終了後も大幅な位置変化で復帰を試み、空白区間を推定経路として補完します。")
            } icon: {
                Image(systemName: "location.fill.viewfinder")
                    .foregroundStyle(store.theme.interactionColor)
            }
        }
        .font(.system(size: 12, weight: .regular))
        .foregroundStyle(store.theme.foregroundColor.opacity(0.55))
        .lineSpacing(3)
        .padding(16)
        .background(store.theme.foregroundColor.opacity(0.035), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func selectRecordingMode(_ mode: RecordingMode) {
        let status = store.recorder.authorizationStatus
        guard !hasRequiredPermission(for: mode, status: status) else {
            pendingRecordingMode = nil
            withAnimation(.snappy) { store.setRecordingMode(mode) }
            return
        }

        pendingRecordingMode = mode
        permissionStatusForAlert = status
        showsPermissionAlert = true
    }

    private func hasRequiredPermission(for mode: RecordingMode, status: CLAuthorizationStatus) -> Bool {
        switch mode {
        case .persistent:
            return status == .authorizedAlways
        case .background:
            return status == .authorizedAlways || status == .authorizedWhenInUse
        case .off:
            return true
        }
    }

    private func beginPermissionRequest() {
        guard pendingRecordingMode != nil else { return }
        let status = store.recorder.authorizationStatus
        permissionStatusForAlert = status

        if status == .denied || status == .restricted { return }
        if status == .notDetermined {
            store.recorder.requestForegroundAuthorization()
        }
    }

    private func handleAuthorizationChange(_ status: CLAuthorizationStatus) {
        guard let mode = pendingRecordingMode else { return }
        permissionStatusForAlert = status

        if hasRequiredPermission(for: mode, status: status) {
            pendingRecordingMode = nil
            withAnimation(.snappy) { store.setRecordingMode(mode) }
        } else if mode == .persistent && status == .authorizedWhenInUse {
            showsPermissionAlert = true
        } else if status == .denied || status == .restricted {
            showsPermissionAlert = true
        }
    }

    private var shouldOpenSystemSettings: Bool {
        permissionStatusForAlert == .denied
            || permissionStatusForAlert == .restricted
            || (pendingRecordingMode == .persistent && permissionStatusForAlert == .authorizedWhenInUse)
    }

    private var permissionAlertTitle: String {
        if pendingRecordingMode == .persistent {
            return "「常に許可」が必要です"
        }
        return "位置情報の許可が必要です"
    }

    private var permissionAlertMessage: String {
        if permissionStatusForAlert == .denied || permissionStatusForAlert == .restricted {
            return "iPhoneの設定でStreet Printの位置情報を許可してください。設定が完了するまで、現在の記録モードを維持します。"
        }
        if pendingRecordingMode == .persistent {
            return "終了後も記録を再開するには、位置情報の「常に許可」が必要です。許可が完了してから常時記録へ切り替えます。"
        }
        return "バックグラウンドまで記録するには、位置情報の許可が必要です。許可が完了してからモードを切り替えます。"
    }
}

private struct PrivacyPolicyView: View {
    let theme: AppTheme

    var body: some View {
        ZStack {
            theme.backgroundColor.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PRIVACY POLICY")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(2)
                            .foregroundStyle(theme.interactionColor)
                        Text("プライバシーポリシー")
                            .font(.system(size: 28, weight: .semibold))
                        Text("最終更新：2026年10月5日")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(theme.foregroundColor.opacity(0.5))
                    }

                    PolicySection(
                        number: "01",
                        title: "取得する情報",
                        text: "Street Printは、移動経路を記録するために位置情報、測位時刻、速度、精度を使用します。徒歩・自転車・車を判定するためにモーション情報も使用します。選択したテーマや記録設定も端末内に保存します。",
                        theme: theme
                    )
                    PolicySection(
                        number: "02",
                        title: "利用目的",
                        text: "取得した情報は、経路の記録、道路への補正、移動手段の判定、Statsの計算、期間別表示、共有画像の作成にのみ利用します。広告目的の追跡には利用しません。",
                        theme: theme
                    )
                    PolicySection(
                        number: "03",
                        title: "保存と外部サービス",
                        text: "移動履歴は基本的にこの端末内へ保存し、Street Print独自のサーバーやアカウントには送信しません。道路への補正や地図表示にはAppleのMapKitを利用するため、経路検索に必要な地点情報がAppleのサービスで処理される場合があります。",
                        theme: theme
                    )
                    PolicySection(
                        number: "04",
                        title: "バックグラウンド記録",
                        text: "許可された記録モードでは、アプリが画面に表示されていない間も位置情報を使用します。記録モードと位置情報権限はいつでも変更できます。",
                        theme: theme
                    )
                    PolicySection(
                        number: "05",
                        title: "共有",
                        text: "共有画像はユーザーが共有ボタンを押したときだけ作成されます。共有先の選択と送信はiOSの共有機能を通じてユーザー自身が行います。Street Printが自動投稿することはありません。",
                        theme: theme
                    )
                    PolicySection(
                        number: "06",
                        title: "削除と管理",
                        text: "設定画面の「すべての記録履歴を削除」から端末内の履歴を削除できます。アプリを削除した場合も、端末内に保存されたStreet Printのデータは削除されます。",
                        theme: theme
                    )
                    PolicySection(
                        number: "07",
                        title: "変更とお問い合わせ",
                        text: "機能やデータの扱いを変更する場合、この画面の内容と最終更新日を更新します。お問い合わせ先は、正式公開時にApp StoreのStreet Print掲載ページへ記載します。",
                        theme: theme
                    )

                    Link(destination: URL(string: "https://www.apple.com/jp/legal/privacy/")!) {
                        HStack {
                            Text("Appleのプライバシーポリシー")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(theme.interactionColor)
                        .padding(16)
                        .background(theme.controlBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(theme.controlBorder, lineWidth: 1))
                    }
                }
                .foregroundStyle(theme.foregroundColor)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("プライバシー")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

private struct PolicySection: View {
    let number: String
    let title: String
    let text: String
    let theme: AppTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Text(number)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.interactionColor)
                Text(LocalizedStringKey(title))
                    .font(.system(size: 16, weight: .semibold))
            }
            Text(LocalizedStringKey(text))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(theme.foregroundColor.opacity(0.68))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}


private struct MovementCaptureModeCard: View {
    let mode: MovementCaptureMode
    let isSelected: Bool
    let theme: AppTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isSelected ? theme.interactionColor.opacity(0.16) : theme.foregroundColor.opacity(0.06))
                        .frame(width: 42, height: 42)
                    Image(systemName: mode.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isSelected ? theme.interactionColor : theme.foregroundColor.opacity(0.55))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(mode.title))
                        .font(.system(size: 15, weight: .semibold))
                    Text(LocalizedStringKey(mode.detail))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(theme.foregroundColor.opacity(0.6))
                }

                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(isSelected ? theme.interactionColor : theme.foregroundColor.opacity(0.24))
            }
            .foregroundStyle(theme.foregroundColor)
            .padding(15)
            .background(theme.controlBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(isSelected ? theme.interactionColor.opacity(0.72) : theme.controlBorder, lineWidth: 1.4)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct RecordingModeCard: View {
    let mode: RecordingMode
    let isSelected: Bool
    let isPending: Bool
    let theme: AppTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isSelected ? theme.interactionColor.opacity(0.16) : theme.foregroundColor.opacity(0.06))
                        .frame(width: 42, height: 42)
                    Image(systemName: mode.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isSelected ? theme.interactionColor : theme.foregroundColor.opacity(0.55))
                }

                VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey(mode.title))
                        .font(.system(size: 15, weight: .semibold))
                        Text(LocalizedStringKey(mode.detail))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(theme.foregroundColor.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
                Image(systemName: isPending ? "ellipsis.circle.fill" : (isSelected ? "checkmark.circle.fill" : "circle"))
                    .font(.system(size: 21))
                    .foregroundStyle((isSelected || isPending) ? theme.interactionColor : theme.foregroundColor.opacity(0.24))
            }
            .foregroundStyle(theme.foregroundColor)
            .padding(15)
            .background(theme.controlBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(isSelected ? theme.interactionColor.opacity(0.72) : theme.controlBorder, lineWidth: 1.4)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct AuthorizationRow: View {
    @ObservedObject var recorder: LocationRecorder
    let theme: AppTheme

    var body: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(theme.interactionColor)
                    .frame(width: 24)
                Text(LocalizedStringKey("位置情報の権限"))
                    .font(.system(size: 15, weight: .medium))
                Spacer()
                    Text(LocalizedStringKey(statusText))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(statusColor)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.foregroundColor.opacity(0.3))
            }
            .padding(16)
        }
        .foregroundStyle(theme.foregroundColor)
    }

    private var statusText: String {
        switch recorder.authorizationStatus {
        case .authorizedAlways: "常に許可"
        case .authorizedWhenInUse: "使用中のみ"
        case .denied: "許可なし"
        case .restricted: "制限中"
        case .notDetermined: "未設定"
        @unknown default: "不明"
        }
    }

    private var statusColor: Color {
        recorder.authorizationStatus == .authorizedAlways ? .green : .orange
    }
}

private struct ThemeCard: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(theme.backgroundColor)

                    VStack {
                        HStack {
                            HStack(spacing: 4) {
                                Circle().fill(theme.backgroundColor).frame(width: 7, height: 7)
                                Circle().fill(theme.routeColor).frame(width: 7, height: 7)
                                Circle().fill(theme.interactionColor).frame(width: 7, height: 7)
                            }
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .black))
                                    .foregroundStyle(theme.selectedControlForeground)
                                    .frame(width: 22, height: 22)
                                    .background(theme.selectedControlBackground, in: Circle())
                            }
                        }
                        Spacer()
                    }
                    .padding(10)

                    MiniRouteShape()
                        .stroke(theme.routeColor, style: StrokeStyle(lineWidth: 2.2 * theme.lineScale, lineCap: .round, lineJoin: .round))
                        .padding(.horizontal, 13)
                        .padding(.top, 22)
                        .padding(.bottom, 10)
                }
                .frame(width: 174, height: 108)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.foregroundColor.opacity(0.1)))

                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(theme.name))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.foregroundColor)
                    Text(LocalizedStringKey(theme.subtitle))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(theme.foregroundColor.opacity(0.62))
                        .lineLimit(1)
                }
            }
            .padding(9)
            .background(
                theme.controlBackground,
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(isSelected ? theme.interactionColor.opacity(0.9) : theme.controlBorder, lineWidth: isSelected ? 1.8 : 1)
            }
            .shadow(color: isSelected ? theme.shadowColor : .clear, radius: 14, y: 6)
        }
        .buttonStyle(.plain)
    }
}

private struct MiniRouteShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY * 0.7))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.28),
            control1: CGPoint(x: rect.width * 0.34, y: rect.height * 0.92),
            control2: CGPoint(x: rect.width * 0.62, y: rect.height * 0.05)
        )
        path.move(to: CGPoint(x: rect.width * 0.16, y: rect.height * 0.2))
        path.addLine(to: CGPoint(x: rect.width * 0.52, y: rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.width * 0.84, y: rect.height * 0.9))
        return path
    }
}
