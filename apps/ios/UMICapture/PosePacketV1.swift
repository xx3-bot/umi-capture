import Foundation
import simd

struct PosePacketV1 {
    static let byteCount = 72

    let transformMatrix: simd_float4x4
    let timestamp: Double

    func toBytes() -> Data {
        let columns = transformMatrix.columns
        let scalars: [Float] = [
            columns.0.x, columns.0.y, columns.0.z, columns.0.w,
            columns.1.x, columns.1.y, columns.1.z, columns.1.w,
            columns.2.x, columns.2.y, columns.2.z, columns.2.w,
            columns.3.x, columns.3.y, columns.3.z, columns.3.w
        ]
        var result = Data(capacity: Self.byteCount)
        for scalar in scalars {
            appendNativeBytes(scalar, to: &result)
        }
        appendNativeBytes(timestamp, to: &result)
        return result
    }

    private func appendNativeBytes<Value>(_ value: Value, to data: inout Data) {
        var copy = value
        withUnsafeBytes(of: &copy) { raw in
            data.append(contentsOf: raw)
        }
    }
}
