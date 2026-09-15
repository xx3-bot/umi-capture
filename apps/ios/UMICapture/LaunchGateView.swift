import SwiftUI

struct LaunchGateView: View {
    @AppStorage("UMICapture.sourceProvenanceAcknowledged")
    private var sourceProvenanceAcknowledged = false
    @AppStorage("UMICapture.tutorialCompleted")
    private var tutorialCompleted = false
    @AppStorage("UMICapture.language")
    private var language: AppLanguage = .simplifiedChinese

    var body: some View {
        Group {
            if !sourceProvenanceAcknowledged {
                SourceProvenanceView(language: language) {
                    sourceProvenanceAcknowledged = true
                }
            } else if !tutorialCompleted {
                UMICaptureTutorialView(language: language) {
                    tutorialCompleted = true
                }
            } else {
                ContentView()
            }
        }
    }
}

struct SourceProvenanceView: View {
    let language: AppLanguage
    let onContinue: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(.blue)
                        Text(
                            language.text(
                                "Software source and attribution",
                                "软件来源与署名"
                            )
                        )
                        .font(.largeTitle.bold())
                        Text(
                            language.text(
                                "Please review this information before using UMI Capture.",
                                "使用 UMI Capture 前，请先阅读以下来源说明。"
                            )
                        )
                        .font(.body)
                        .foregroundStyle(.secondary)
                    }

                    SoftwareProvenanceDetails(language: language)

                    Button(action: onContinue) {
                        Text(
                            language.text(
                                "I understand — continue",
                                "已了解并继续"
                            )
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(
                        "umi_capture.launch.provenance-continue"
                    )
                }
                .padding(24)
            }
            .navigationTitle("UMI Capture")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct UMICaptureTutorialView: View {
    let language: AppLanguage
    let onFinish: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(language.text("Quick start", "快速上手"))
                        .font(.largeTitle.bold())

                    tutorialStep(
                        number: 1,
                        title: language.text(
                            "Allow required access",
                            "允许必要权限"
                        ),
                        detail: language.text(
                            "Allow Camera access for ARKit capture and Local Network access to discover and connect to UMI Capture Receiver. UMI Capture cannot capture or transfer data without them.",
                            "请允许“相机”权限以进行 ARKit 采集，并允许“本地网络”权限以发现和连接 UMI Capture Receiver；缺少权限时无法完成采集或传输。"
                        ),
                        systemImage: "checkmark.shield"
                    )

                    tutorialStep(
                        number: 2,
                        title: language.text(
                            "Connect the Mac receiver",
                            "连接 Mac 接收端"
                        ),
                        detail: language.text(
                            "Open UMI Capture Receiver first. Keep the Mac and iPhone on the same Wi-Fi, then select the discovered receiver from the menu.",
                            "先打开 UMI Capture Receiver，确保 Mac 与 iPhone 连接同一 Wi-Fi，再从菜单中选择发现的接收端。"
                        ),
                        systemImage: "desktopcomputer"
                    )

                    tutorialStep(
                        number: 3,
                        title: language.text(
                            "Keep the default RGB setup",
                            "保留默认 RGB 设置"
                        ),
                        detail: language.text(
                            "The default RGB streams are the supported handoff configuration. Extra enabled streams increase storage use and shorten the estimated recording time shown on the capture screen.",
                            "默认 RGB 数据流是本交接版本支持的配置。启用更多数据流会增加存储占用，并缩短采集界面显示的估算可录制时长。"
                        ),
                        systemImage: "camera.fill"
                    )

                    tutorialStep(
                        number: 4,
                        title: language.text(
                            "Check storage, then use Start and End",
                            "检查存储后使用开始与结束"
                        ),
                        detail: language.text(
                            "Before capture, read the remaining-space and estimated-duration feedback. For one-phone capture, tap Start once and End once; each capture is one continuous interval.",
                            "采集前请查看剩余空间和估算可录制时长。单机采集时只点击一次“开始”和一次“结束”，每次采集都是一个连续区间。"
                        ),
                        systemImage: "internaldrive"
                    )

                    tutorialStep(
                        number: 5,
                        title: language.text(
                            "Configure two-device capture",
                            "配置双机采集"
                        ),
                        detail: language.text(
                            "Tap the synchronization status bar above Start. Assign exactly one phone as Handheld UMI and the other as Chest EGO, then prepare both devices.",
                            "点击“开始”上方的同步状态条，将两台手机分别设为 Handheld UMI 与 Chest EGO，再准备双机采集。"
                        ),
                        systemImage: "iphone.gen3.radiowaves.left.and.right"
                    )

                    tutorialStep(
                        number: 6,
                        title: language.text(
                            "Interpret the output correctly",
                            "正确理解输出"
                        ),
                        detail: language.text(
                            "Two-device capture synchronizes time and collection boundaries. Each phone still exports an independent local ARKit coordinate system.",
                            "双机采集同步时间与采集边界，但每台手机仍导出彼此独立的本地 ARKit 坐标系。"
                        ),
                        systemImage: "move.3d"
                    )

                    tutorialStep(
                        number: 7,
                        title: language.text(
                            "Export or delete local captures",
                            "导出或删除本地采集"
                        ),
                        detail: language.text(
                            "Ending a capture creates a ZIP in the app's local capture library and opens the iOS share sheet for export. Use Recent Captures to export it again or delete local data after verifying the transfer.",
                            "结束采集后，应用会在本地采集库生成 ZIP，并打开 iOS 分享界面供导出。可在“最近采集”中再次导出，传输验证完成后再删除本地数据。"
                        ),
                        systemImage: "archivebox"
                    )

                    Button(action: onFinish) {
                        Text(language.text("Open UMI Capture", "进入 UMI Capture"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(
                        "umi_capture.launch.tutorial-finish"
                    )
                }
                .padding(24)
            }
            .navigationTitle(language.text("Tutorial", "使用教程"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func tutorialStep(
        number: Int,
        title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.14))
                    .frame(width: 48, height: 48)
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("\(number). \(title)")
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct UMICaptureAboutView: View {
    let language: AppLanguage

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(SoftwareProvenance.productName)
                            .font(.largeTitle.bold())
                        Text(versionText)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    SoftwareProvenanceDetails(language: language)
                }
                .padding(24)
            }
            .navigationTitle(language.text("About", "关于"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("umi_capture.capture.about")
    }

    private var versionText: String {
        let provenance = SoftwareProvenance.current()
        return language.text(
            "Version \(provenance.marketingVersion) (\(provenance.buildNumber))",
            "版本 \(provenance.marketingVersion)（\(provenance.buildNumber)）"
        )
    }
}

private struct SoftwareProvenanceDetails: View {
    let language: AppLanguage
    private let provenance = SoftwareProvenance.current()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                language.text(
                    SoftwareProvenance.aboutDescription,
                    "UMI Capture 是一个独立实现的 ARKit 采集与处理工具，"
                        + "其设计受到既有开源机器人学习界面的启发。"
                )
            )
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            provenanceRow(
                title: language.text("Developer", "开发者"),
                value: provenance.developer
            )
            provenanceRow(
                title: language.text("Inspired by", "相关工作启发"),
                value: provenance.acknowledgements.joined(separator: ", ")
            )
            provenanceRow(
                title: language.text("Feedback", "反馈邮箱"),
                value: SoftwareProvenance.feedbackAddress
            )
        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func provenanceRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
