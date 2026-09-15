import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english
    case simplifiedChinese

    var id: String {
        rawValue
    }

    var pickerLabel: String {
        switch self {
        case .english:
            return "EN"
        case .simplifiedChinese:
            return "中文"
        }
    }

    func text(_ english: String, _ chinese: String) -> String {
        switch self {
        case .english:
            return english
        case .simplifiedChinese:
            return chinese
        }
    }

    func localizedRuntimeStatus(_ status: String) -> String {
        guard self == .simplifiedChinese else {
            return status
        }

        let exactTranslations: [String: String] = [
            "Waiting for ARKit": "等待 ARKit",
            "Preparation cancelled — app entered background":
                "准备已取消——App 进入后台",
            "Streaming": "正在采集",
            "Preparation cancelled": "准备已取消",
            "Ready — tap Start": "就绪——点击开始",
            "Waiting for normal tracking": "等待正常跟踪",
            "Armed — waiting for Start": "已就绪——等待开始",
            "Ending capture…": "正在结束采集…",
            "Stopped": "已结束",
            "Preparation cancelled — unsupported device orientation":
                "准备已取消——当前设备方向不受支持",
            "Capture interrupted — End to save":
                "采集已中断——点击结束以保存",
            "Return phone to prepared capture angle before Start":
                "请将手机恢复到准备完成时的角度后再开始",
            "Recording — return phone to its prepared angle":
                "正在采集——请将手机恢复到准备完成时的角度",
            "Recording — return phone to its prepared orientation":
                "正在采集——请将手机恢复到准备完成时的方向",
            "Recording — orientation changed; synchronized capture marked partial":
                "正在采集——手机方向已改变，本次同步采集已标记为不完整",
            "Recording — tracking degraded; synchronized capture marked partial":
                "正在采集——跟踪质量下降，本次同步采集已标记为不完整",
            "Preparation restarted — phone orientation changed":
                "手机方向已改变——重新准备中",
            "Preparation restarted — excessive phone tilt":
                "手机倾斜过大——重新准备中",
            "Return phone to original capture orientation":
                "请将手机转回本次采集的初始方向",
            "Hold phone upright before Start":
                "开始前请将手机竖直拿稳",
            "Resource pressure — preserving recoverable files":
                "资源压力过高——正在保留可恢复文件",
            "Resource pressure — safely ending capture":
                "资源压力过高——正在安全结束采集",
            "Capture package timed out — recovery files retained":
                "采集包生成超时——已保留恢复文件",
            "Capture package failed — recovery files retained":
                "采集包生成失败——已保留恢复文件",
            "Background time expired — recovery files retained":
                "后台处理时间已到——已保留恢复文件",
            "Video finalization failed":
                "视频结束处理失败"
        ]
        if let translated = exactTranslations[status] {
            return translated
        }

        if status == "Preparing — waiting for normal tracking" {
            return "准备中——等待正常跟踪"
        }
        if status == "Preparing — evaluating tracking" {
            return "准备中——正在评估跟踪"
        }
        if status.hasPrefix("Preparing — ") {
            return status
                .replacingOccurrences(of: "Preparing", with: "准备中")
                .replacingOccurrences(
                    of: "hold naturally",
                    with: "自然持握"
                )
                .replacingOccurrences(
                    of: "reduce movement",
                    with: "减小移动"
                )
        }
        if status.hasPrefix("Starting in ") {
            let seconds = status.replacingOccurrences(
                of: "Starting in ",
                with: ""
            )
            return "\(seconds) 秒后开始"
        }
        if status.hasSuffix("physical lens unavailable") {
            return status.replacingOccurrences(
                of: "physical lens unavailable",
                with: "物理镜头不可用"
            )
        }
        if status.hasPrefix("ARSession failed: ") {
            return status.replacingOccurrences(
                of: "ARSession failed:",
                with: "ARSession 失败："
            )
        }
        return status
    }

    func localizedThermalState(_ state: String) -> String {
        guard self == .simplifiedChinese else { return state }
        switch state {
        case "Normal": return "温度正常"
        case "Warm": return "设备偏热"
        case "Hot": return "设备较热"
        case "Critical": return "温度危险"
        default: return "温度未知"
        }
    }

    func localizedStorageStatus(_ status: String) -> String {
        guard self == .simplifiedChinese else { return status }
        return status
            .replacingOccurrences(
                of: "Storage availability could not be verified",
                with: "无法验证可用存储空间"
            )
            .replacingOccurrences(
                of: " free · VIO-only duration varies",
                with: " 可用 · 仅 VIO 模式的可录制时长会变化"
            )
            .replacingOccurrences(
                of: " free · about ",
                with: " 可用 · 按当前 RGB 设置约可录制 "
            )
            .replacingOccurrences(
                of: " min at current RGB settings",
                with: " 分钟"
            )
    }

    func localizedCameraDiagnostic(_ diagnostic: String) -> String {
        guard self == .simplifiedChinese else { return diagnostic }
        return diagnostic
            .replacingOccurrences(
                of: "ARKit reports no formats for ",
                with: "ARKit 未报告 "
            )
            .replacingOccurrences(
                of: ". The app will not fall back to another physical lens. All reported formats: ",
                with: " 的可用格式。应用不会回退到其他物理镜头。全部报告格式："
            )
    }

    func localizedFinalizationStage(
        _ stage: CaptureFinalizationStage
    ) -> String {
        guard self == .simplifiedChinese else {
            return stage.rawValue
        }
        switch stage {
        case .idle: return "空闲"
        case .recording: return "采集中"
        case .draining: return "正在结束采集"
        case .finishingWriters: return "正在完成视频"
        case .packaging: return "正在生成采集包"
        case .waitingUploadAuthorization: return "等待上传授权"
        case .uploading: return "正在上传"
        case .completed: return "已完成"
        case .failed: return "失败"
        }
    }

    func localizedPoseDisplay(_ display: String) -> String {
        guard self == .simplifiedChinese else {
            return display
        }
        return display
            .replacingOccurrences(of: "tracking:", with: "跟踪：")
            .replacingOccurrences(of: "normal", with: "正常")
            .replacingOccurrences(of: "not available", with: "不可用")
            .replacingOccurrences(of: "limited", with: "受限")
            .replacingOccurrences(of: "initializing", with: "正在初始化")
            .replacingOccurrences(of: "excessive motion", with: "运动过快")
            .replacingOccurrences(
                of: "insufficient features",
                with: "特征不足"
            )
            .replacingOccurrences(of: "relocalizing", with: "重新定位")
            .replacingOccurrences(of: "unknown", with: "未知")
    }
}
