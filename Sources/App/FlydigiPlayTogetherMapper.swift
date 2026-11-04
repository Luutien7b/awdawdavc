import SwiftUI
import GameController
import CoreBluetooth
import AVFoundation
import AVKit
import UIKit
import Darwin
import ObjectiveC.runtime

// MARK: - 1. Danh Mục Toàn Bộ Các Dòng Tay Cầm Bluetooth Nhà Flydigi

enum FlydigiControllerModel: String, Codable, CaseIterable, Identifiable {
    case autoDetect = "Tự động nhận diện mọi tay cầm Flydigi"
    case apex5 = "Flydigi Apex 5 / Apex 5 EVA"
    case apex4 = "Flydigi Apex 4 / Apex 3"
    case apex2 = "Flydigi Apex 2 / Apex 1 (Có phím C, Z & Bàn xoay)"
    case vader5Pro = "Flydigi Vader 5 Pro / Vader 5S"
    case vader4Pro = "Flydigi Vader 4 Pro / Vader 3 Pro / Vader 2 Pro (Có phím C, Z, M1-M4)"
    case direwolf4 = "Flydigi Direwolf 4 / Direwolf 3"
    case direwolf2 = "Flydigi Direwolf 2 / Direwolf 1"
    case waspSeries = "Flydigi Wasp 2 / Wasp N / Wasp BT (Tay cầm 1 bên)"
    case weeSeries = "Flydigi Wee 2 / Wee 2T / Joyone"
    case flydigiQ1 = "Flydigi Q1 (Bộ chuyển đổi Bluetooth)"

    var id: String { rawValue }

    var pairingGuide: String {
        switch self {
        case .autoDetect:
            return "Hỗ trợ tự động tất cả chế độ Bluetooth của Flydigi: iOS XInput (Xbox Wireless Controller), Switch (Pro Controller), và Bluetooth BLE (Flashplay / DInput)."
        case .apex5, .apex4:
            return "Trên màn hình LCD của Apex 4/5: Vào mục Kết nối -> Chọn chế độ iOS (XInput) hoặc Bluetooth/Flashplay, sau đó ghép đôi trong Cài đặt Bluetooth hoặc quét BLE trực tiếp bên dưới."
        case .apex2:
            return "Bật công tắc nguồn của Apex 2, nhấn giữ nút Pairing 3 giây để vào chế độ Bluetooth BLE (Flashplay) hoặc chế độ iOS."
        case .vader5Pro, .vader4Pro:
            return "Gạt công tắc mặt sau sang biểu tượng Bluetooth (hoặc NS), nhấn giữ tổ hợp [Home + A] hoặc nút Pairing 3 giây cho tới khi đèn nháy nhanh rồi kết nối."
        case .direwolf4, .direwolf2:
            return "Gạt công tắc mặt đáy sang nấc Bluetooth (BT), nhấn giữ [Fn + B] hoặc [Home] 3 giây (đèn xanh dương cho iOS XInput, đèn xanh lá/vàng cho BLE) rồi ghép đôi."
        case .waspSeries, .weeSeries, .flydigiQ1:
            return "Bật nguồn thiết bị Flydigi Wasp / Wee / Q1, mở mục 'Quét Bluetooth BLE Trực tiếp' ngay bên dưới và chạm vào tên thiết bị để kết nối không cần qua Cài đặt máy."
        }
    }
}

// MARK: - 2. No-Inject System Touch & HOGP Bluetooth HID Digitizer Engine

final class NoInjectSystemTouchEngine: NSObject, CBPeripheralManagerDelegate {
    static let shared = NoInjectSystemTouchEngine()

    private var audioPlayer: AVAudioPlayer?
    private var peripheralManager: CBPeripheralManager?
    private var hidInputCharacteristic: CBMutableCharacteristic?
    private(set) var isBackgroundBridgeActive: Bool = false

    private var iokitHandle: UnsafeMutableRawPointer?

    typealias CreateDigitizerEventFn = @convention(c) (
        UnsafeRawPointer?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32,
        Float, Float, Float, Float, Float, UInt32, UInt32, UInt32
    ) -> UnsafeMutableRawPointer?

    typealias CreateFingerEventFn = @convention(c) (
        UnsafeRawPointer?, UInt64, UInt32, UInt32, UInt32,
        Float, Float, Float, Float, Float, UInt32, UInt32, UInt32
    ) -> UnsafeMutableRawPointer?

    typealias AppendEventFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32) -> Void
    typealias SetIntegerValueFn = @convention(c) (UnsafeMutableRawPointer?, UInt32, Int) -> Void
    typealias EnqueueHIDEventMsgSendFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Void

    private var fnCreateDigitizer: CreateDigitizerEventFn?
    private var fnCreateFinger: CreateFingerEventFn?
    private var fnAppendEvent: AppendEventFn?
    private var fnSetInt: SetIntegerValueFn?

    private let hidTouchReportDescriptor: [UInt8] = [
        0x05, 0x0D, 0x09, 0x04, 0xA1, 0x01, 0x09, 0x22, 0xA1, 0x02,
        0x09, 0x42, 0x09, 0x32, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01,
        0x95, 0x02, 0x81, 0x02, 0x95, 0x06, 0x81, 0x03, 0x09, 0x51,
        0x75, 0x08, 0x95, 0x01, 0x81, 0x02, 0x05, 0x01, 0x09, 0x30,
        0x09, 0x31, 0x16, 0x00, 0x00, 0x26, 0xFF, 0x7F, 0x75, 0x10,
        0x95, 0x02, 0x81, 0x02, 0xC0, 0xC0
    ]

    override init() {
        super.init()
        loadSystemTouchSymbols()
    }

    private func loadSystemTouchSymbols() {
        iokitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        guard let h = iokitHandle else { return }

        if let sym1 = dlsym(h, "IOHIDEventCreateDigitizerEvent") {
            fnCreateDigitizer = unsafeBitCast(sym1, to: CreateDigitizerEventFn.self)
        }
        if let sym2 = dlsym(h, "IOHIDEventCreateDigitizerFingerEvent") {
            fnCreateFinger = unsafeBitCast(sym2, to: CreateFingerEventFn.self)
        }
        if let sym3 = dlsym(h, "IOHIDEventAppendEvent") {
            fnAppendEvent = unsafeBitCast(sym3, to: AppendEventFn.self)
        }
        if let sym4 = dlsym(h, "IOHIDEventSetIntegerValue") {
            fnSetInt = unsafeBitCast(sym4, to: SetIntegerValueFn.self)
        }
    }

    func startSafeBackgroundBridge() {
        guard !isBackgroundBridgeActive else { return }
        isBackgroundBridgeActive = true

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let wavData = Self.generateSilentWavData()
            audioPlayer = try AVAudioPlayer(data: wavData)
            audioPlayer?.numberOfLoops = -1
            audioPlayer?.volume = 0.01
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
        } catch {}

        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
        }
    }

    func stopSafeBackgroundBridge() {
        isBackgroundBridgeActive = false
        audioPlayer?.stop()
        peripheralManager?.stopAdvertising()
    }

    func sendSystemTouch(fingerIndex: UInt32, normalizedX: Double, normalizedY: Double, isTouching: Bool, isMoving: Bool) {
        let clampedX = Float(min(max(normalizedX, 0.01), 0.99))
        let clampedY = Float(min(max(normalizedY, 0.01), 0.99))

        if let createDig = fnCreateDigitizer,
           let createFin = fnCreateFinger,
           let appendEv = fnAppendEvent,
           let setInt = fnSetInt {
            let ts = mach_absolute_time()
            let eventMask: UInt32 = isMoving ? 4 : 2
            let rangeBit: UInt32 = isTouching ? 1 : 0
            let touchBit: UInt32 = isTouching ? 1 : 0

            if let parentEvent = createDig(
                nil, ts, 3, 0, 0, eventMask, 0,
                clampedX, clampedY, 0, 0, 0, 0, 0, 0
            ) {
                setInt(parentEvent, 0xb0019, 1)
                if let childFinger = createFin(
                    nil, ts, fingerIndex, fingerIndex + 10, eventMask,
                    clampedX, clampedY, 0, isTouching ? 1.0 : 0.0, 0,
                    rangeBit, touchBit, 0
                ) {
                    appendEv(parentEvent, childFinger, 0)
                }

                let app = UIApplication.shared
                let sel = NSSelectorFromString("_enqueueHIDEvent:")
                if app.responds(to: sel), let cls = object_getClass(app), let imp = class_getMethodImplementation(cls, sel) {
                    let sendFn = unsafeBitCast(imp, to: EnqueueHIDEventMsgSendFn.self)
                    sendFn(app, sel, parentEvent)
                }
            }
        }

        if let pm = peripheralManager, let ch = hidInputCharacteristic, pm.state == .poweredOn {
            let x16 = UInt16(clampedX * 32767.0)
            let y16 = UInt16(clampedY * 32767.0)
            let statusByte: UInt8 = isTouching ? 0x03 : 0x00
            let report: [UInt8] = [
                statusByte,
                UInt8(fingerIndex & 0xFF),
                UInt8(x16 & 0xFF), UInt8((x16 >> 8) & 0xFF),
                UInt8(y16 & 0xFF), UInt8((y16 >> 8) & 0xFF)
            ]
            pm.updateValue(Data(report), for: ch, onSubscribedCentrals: nil)
        }
    }

    private static func generateSilentWavData() -> Data {
        let sampleRate: UInt32 = 8000
        let numSamples: UInt32 = 8000
        let dataSize = numSamples * 2
        let fileSize = 36 + dataSize

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        data.append("WAVEfmt ".data(using: .ascii)!)
        let fmtSize: UInt32 = 16
        let audioFormat: UInt16 = 1
        let numChannels: UInt16 = 1
        let byteRate: UInt32 = sampleRate * 2
        let blockAlign: UInt16 = 2
        let bitsPerSample: UInt16 = 16
        data.append(withUnsafeBytes(of: fmtSize.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: audioFormat.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: numChannels.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        data.append("data".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        data.append(Data(count: Int(dataSize)))
        return data
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { return }

        let hidService = CBMutableService(type: CBUUID(string: "1812"), primary: true)
        let hidInfoChar = CBMutableCharacteristic(
            type: CBUUID(string: "2A4A"),
            properties: [.read],
            value: Data([0x11, 0x01, 0x00, 0x02]),
            permissions: [.readable]
        )
        let protoChar = CBMutableCharacteristic(
            type: CBUUID(string: "2A4E"),
            properties: [.read, .writeWithoutResponse],
            value: Data([0x01]),
            permissions: [.readable, .writeable]
        )
        let reportMapChar = CBMutableCharacteristic(
            type: CBUUID(string: "2A4B"),
            properties: [.read],
            value: Data(hidTouchReportDescriptor),
            permissions: [.readable]
        )
        let reportChar = CBMutableCharacteristic(
            type: CBUUID(string: "2A4D"),
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )

        hidService.characteristics = [hidInfoChar, protoChar, reportMapChar, reportChar]
        hidInputCharacteristic = reportChar
        peripheral.add(hidService)
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: "Flydigi Panda Touch",
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "1812")]
        ])
    }
}

// MARK: - 3. Connection Transport Mode & Models

enum ConnectionTransport: String, Codable, CaseIterable {
    case none = "Chưa kết nối"
    case bluetoothXInput = "Bluetooth iOS (XInput / MFi)"
    case bluetoothSwitch = "Bluetooth Switch Mode (NS Pro Controller)"
    case bluetoothBLE = "Bluetooth BLE (Flashplay / DInput Mọi Dòng Flydigi)"
    case wiredUSB = "Cắm dây trực tiếp (USB-C / OTG)"
    case dongle24G = "Đầu thu 2.4GHz USB Dongle"
}

struct DiscoveredBLEDevice: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    var name: String
    var detectedSeries: String
    var rssi: Int
    var isFlydigi: Bool
}

struct KeyMappingItem: Identifiable, Codable {
    var id: String
    var boundKey: String
    var label: String
    var actionName: String
    var normalizedX: Double
    var normalizedY: Double
    var radius: Double
    var isJoystick: Bool
}

struct ControllerProfile: Codable {
    var profileName: String
    var targetGameBundleID: String
    var selectedFlydigiModel: String
    var swapSwitchABXY: Bool            // Đảo A<->B và X<->Y nếu tay cầm Flydigi đang ở gạt NS (Switch)
    var globalOpacity: Double

    var leftInnerDeadzone: Double
    var leftOuterDeadzone: Double
    var leftResponseCurve: Double
    var leftDragRadius: Double
    var leftCenterOffsetX: Double
    var leftCenterOffsetY: Double

    var rightInnerDeadzone: Double
    var rightOuterDeadzone: Double
    var rightResponseCurve: Double
    var rightSensitivityX: Double
    var rightSensitivityY: Double
    var invertRightY: Bool
    var rightCenterOffsetX: Double
    var rightCenterOffsetY: Double

    var triggerDeadzone: Double
    var enableTurboRT: Bool
    var turboCPS: Double

    var preferredTransport: String
    var mappings: [KeyMappingItem]

    static func defaultPlayTogetherProfile() -> ControllerProfile {
        return ControllerProfile(
            profileName: "Universal Flydigi Bluetooth - Play Together VNG",
            targetGameBundleID: "com.vng.playtogether",
            selectedFlydigiModel: FlydigiControllerModel.autoDetect.rawValue,
            swapSwitchABXY: false,
            globalOpacity: 0.65,
            leftInnerDeadzone: 0.10,
            leftOuterDeadzone: 0.94,
            leftResponseCurve: 1.00,
            leftDragRadius: 78.0,
            leftCenterOffsetX: 0.0,
            leftCenterOffsetY: 0.0,
            rightInnerDeadzone: 0.12,
            rightOuterDeadzone: 0.95,
            rightResponseCurve: 1.15,
            rightSensitivityX: 1.50,
            rightSensitivityY: 1.25,
            invertRightY: false,
            rightCenterOffsetX: 0.0,
            rightCenterOffsetY: 0.0,
            triggerDeadzone: 0.18,
            enableTurboRT: false,
            turboCPS: 12.0,
            preferredTransport: "AUTO",
            mappings: [
                KeyMappingItem(id: "L_STICK", boundKey: "L_STICK", label: "L-Stick", actionName: "Di chuyển 360°", normalizedX: 0.16, normalizedY: 0.72, radius: 78.0, isJoystick: true),
                KeyMappingItem(id: "R_STICK", boundKey: "R_STICK", label: "R-Stick", actionName: "Xoay Camera", normalizedX: 0.62, normalizedY: 0.45, radius: 64.0, isJoystick: true),
                KeyMappingItem(id: "NODE_A", boundKey: "BTN_A", label: "A", actionName: "Nhảy (Jump)", normalizedX: 0.88, normalizedY: 0.78, radius: 30.0, isJoystick: false),
                KeyMappingItem(id: "NODE_B", boundKey: "BTN_B", label: "B", actionName: "Câu cá / Tương tác", normalizedX: 0.78, normalizedY: 0.82, radius: 32.0, isJoystick: false),
                KeyMappingItem(id: "NODE_X", boundKey: "BTN_X", label: "X", actionName: "Dùng công cụ", normalizedX: 0.82, normalizedY: 0.62, radius: 28.0, isJoystick: false),
                KeyMappingItem(id: "NODE_Y", boundKey: "BTN_Y", label: "Y", actionName: "Mở Balo", normalizedX: 0.93, normalizedY: 0.48, radius: 26.0, isJoystick: false),
                KeyMappingItem(id: "NODE_RT", boundKey: "BTN_RT", label: "RT", actionName: "Giật cá nhanh", normalizedX: 0.78, normalizedY: 0.82, radius: 24.0, isJoystick: false),
                KeyMappingItem(id: "NODE_LT", boundKey: "BTN_LT", label: "LT", actionName: "Gọi Xe / Ván trượt", normalizedX: 0.72, normalizedY: 0.68, radius: 26.0, isJoystick: false),
                KeyMappingItem(id: "NODE_LB", boundKey: "BTN_LB", label: "LB", actionName: "Bản đồ (Map)", normalizedX: 0.10, normalizedY: 0.18, radius: 24.0, isJoystick: false),
                KeyMappingItem(id: "NODE_RB", boundKey: "BTN_RB", label: "RB", actionName: "Đổi vật phẩm", normalizedX: 0.86, normalizedY: 0.48, radius: 24.0, isJoystick: false),
                KeyMappingItem(id: "NODE_UP", boundKey: "DPAD_UP", label: "↑", actionName: "Điện thoại", normalizedX: 0.93, normalizedY: 0.28, radius: 24.0, isJoystick: false)
            ]
        )
    }
}

// MARK: - 4. Universal Flydigi Bluetooth Driver (Apex 1-6, Vader 2-5, Direwolf 1-4, Wasp, Wee, Joyone, Q1)

final class FlydigiGamepadManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var isConnected: Bool = false
    @Published var controllerName: String = "Kết nối Tay cầm Flydigi"
    @Published var detectedModelName: String = "Tự động nhận diện mọi dòng Flydigi"
    @Published var activeTransport: ConnectionTransport = .none
    @Published var batteryLevel: Float = -1.0

    @Published var rawLeftStick: CGPoint = .zero
    @Published var rawRightStick: CGPoint = .zero
    @Published var leftStickVector: CGPoint = .zero
    @Published var rightStickVector: CGPoint = .zero
    @Published var leftTriggerValue: Double = 0.0
    @Published var rightTriggerValue: Double = 0.0
    @Published var activeButtons: Set<String> = []
    @Published var profile: ControllerProfile

    @Published var selectedNodeIDForRebind: String? = nil
    @Published var isSafeBackgroundModeRunning: Bool = false
    @Published var customGameScreenshot: UIImage? = nil
    @Published var statusBannerText: String = "🐼 Hỗ trợ mọi tay cầm Bluetooth Flydigi (Apex, Vader, Direwolf, Wasp, Wee, Q1)!"

    @Published var simCharPos: CGPoint = CGPoint(x: 420, y: 210)
    @Published var simIsJumping: Bool = false
    @Published var simLastActionText: String = "Đứng yên"
    private var simTimer: Timer?
    private var leftStickWasActive: Bool = false
    private var rightStickWasActive: Bool = false
    private var currentRightSwipeNX: Double = 0.62
    private var currentRightSwipeNY: Double = 0.45

    @Published var bleStateText: String = "Đang khởi tạo Bluetooth..."
    @Published var isScanningBLE: Bool = false
    @Published var showAllBLEDevices: Bool = false
    @Published var discoveredDevices: [DiscoveredBLEDevice] = []
    private var blePressedSet: Set<String> = []

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private let storageKey = "Flydigi_UniversalBT_Profile_v7"

    // Tất cả UUID dịch vụ Bluetooth GATT trên mọi thế hệ tay cầm Flydigi
    private let allFlydigiServiceUUIDs: [CBUUID] = [
        CBUUID(string: "1812"), // Standard BLE HID Over GATT (XInput / DInput BLE)
        CBUUID(string: "180F"), // Battery Service
        CBUUID(string: "FFE0"), // Flydigi Flashplay v1 (Apex 1/2, Wasp, Wee 2)
        CBUUID(string: "FFF0"), // Flydigi Flashplay v2 (Vader 2/3, Direwolf 1/2, Apex 3)
        CBUUID(string: "FD00"), // Flydigi Next-Gen High-Speed BLE (Apex 4/5/6, Vader 4/5 Pro, Direwolf 3/4)
        CBUUID(string: "AE00"), // Flydigi Smart BLE Service
        CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E") // Nordic UART BLE (Flydigi Q1 / Wasp N)
    ]

    override init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(ControllerProfile.self, from: data) {
            self.profile = saved
        } else {
            self.profile = ControllerProfile.defaultPlayTogetherProfile()
        }
        super.init()

        if #available(iOS 14.5, *) {
            GCController.shouldMonitorBackgroundEvents = true
        }
        centralManager = CBCentralManager(delegate: self, queue: .main)
        setupAllHardwareObservers()
        start60FPSEngineLoop()
    }

    // Nhận diện tên dòng tay cầm Flydigi từ tên quảng bá Bluetooth
    static func classifyFlydigiSeries(from name: String) -> (isFlydigi: Bool, seriesLabel: String) {
        let low = name.lowercased()
        if low.contains("apex 5") || low.contains("apex5") { return (true, "Flydigi Apex 5 Series") }
        if low.contains("apex 6") || low.contains("apex6") { return (true, "Flydigi Apex 6 Series") }
        if low.contains("apex 4") || low.contains("apex4") { return (true, "Flydigi Apex 4 Series") }
        if low.contains("apex 3") || low.contains("apex3") { return (true, "Flydigi Apex 3 Series") }
        if low.contains("apex 2") || low.contains("apex2") || low.contains("apex") { return (true, "Flydigi Apex Series") }
        if low.contains("vader 5") || low.contains("vader5") { return (true, "Flydigi Vader 5 Pro / 5S") }
        if low.contains("vader 4") || low.contains("vader4") { return (true, "Flydigi Vader 4 Pro") }
        if low.contains("vader 3") || low.contains("vader3") { return (true, "Flydigi Vader 3 Pro") }
        if low.contains("vader") { return (true, "Flydigi Vader Series") }
        if low.contains("direwolf 4") || low.contains("direwolf4") { return (true, "Flydigi Direwolf 4") }
        if low.contains("direwolf 3") || low.contains("direwolf3") { return (true, "Flydigi Direwolf 3") }
        if low.contains("direwolf") { return (true, "Flydigi Direwolf Series") }
        if low.contains("wasp") { return (true, "Flydigi Wasp Series") }
        if low.contains("wee") { return (true, "Flydigi Wee Series") }
        if low.contains("joyone") { return (true, "Flydigi Joyone") }
        if low.contains("q1") || low.contains("feizhi") || low.contains("flydigi") || low.contains("fdg") {
            return (true, "Flydigi Bluetooth Device")
        }
        if low.contains("xbox") || low.contains("wireless controller") || low.contains("dualshock") || low.contains("dualsense") {
            return (true, "Chế độ Bluetooth iOS XInput / MFi")
        }
        if low.contains("pro controller") || low.contains("switch") {
            return (true, "Chế độ Bluetooth Switch (NS Mode)")
        }
        return (false, "Thiết bị Bluetooth")
    }

    func toggleSafeBackgroundBridgeAndLaunchGame() {
        if isSafeBackgroundModeRunning {
            NoInjectSystemTouchEngine.shared.stopSafeBackgroundBridge()
            isSafeBackgroundModeRunning = false
            statusBannerText = "Đã tắt chế độ chạy nền."
        } else {
            NoInjectSystemTouchEngine.shared.startSafeBackgroundBridge()
            isSafeBackgroundModeRunning = true
            statusBannerText = "🛡️ ĐANG CHẠY NỀN 60FPS! Hãy mở Play Together VNG bản gốc trên App Store để chơi."
        }
    }

    private func start60FPSEngineLoop() {
        simTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let dx = self.leftStickVector.x
            let dy = self.leftStickVector.y

            if abs(dx) > 0.01 || abs(dy) > 0.01 {
                self.simCharPos.x = min(max(self.simCharPos.x + dx * 4.2, 80), 760)
                self.simCharPos.y = min(max(self.simCharPos.y + dy * 4.2, 70), 330)
                if !self.simIsJumping {
                    self.simLastActionText = "Đang chạy 360° (\(Int(hypot(dx, dy) * 100))%)"
                }

                if let lNode = self.profile.mappings.first(where: { $0.id == "L_STICK" }) {
                    if !self.leftStickWasActive {
                        self.leftStickWasActive = true
                        NoInjectSystemTouchEngine.shared.sendSystemTouch(
                            fingerIndex: 1,
                            normalizedX: lNode.normalizedX,
                            normalizedY: lNode.normalizedY,
                            isTouching: true,
                            isMoving: false
                        )
                    } else {
                        let targetNX = lNode.normalizedX + Double(dx) * (lNode.radius / 844.0)
                        let targetNY = lNode.normalizedY + Double(dy) * (lNode.radius / 390.0)
                        NoInjectSystemTouchEngine.shared.sendSystemTouch(
                            fingerIndex: 1,
                            normalizedX: targetNX,
                            normalizedY: targetNY,
                            isTouching: true,
                            isMoving: true
                        )
                    }
                }
            } else {
                if self.leftStickWasActive {
                    self.leftStickWasActive = false
                    if let lNode = self.profile.mappings.first(where: { $0.id == "L_STICK" }) {
                        NoInjectSystemTouchEngine.shared.sendSystemTouch(
                            fingerIndex: 1,
                            normalizedX: lNode.normalizedX,
                            normalizedY: lNode.normalizedY,
                            isTouching: false,
                            isMoving: false
                        )
                    }
                }
                if !self.simIsJumping && self.activeButtons.isEmpty {
                    self.simLastActionText = "Đứng yên"
                }
            }

            let rx = self.rightStickVector.x
            let ry = self.rightStickVector.y
            if abs(rx) > 0.02 || abs(ry) > 0.02 {
                if let rNode = self.profile.mappings.first(where: { $0.id == "R_STICK" }) {
                    if !self.rightStickWasActive {
                        self.rightStickWasActive = true
                        self.currentRightSwipeNX = rNode.normalizedX
                        self.currentRightSwipeNY = rNode.normalizedY
                        NoInjectSystemTouchEngine.shared.sendSystemTouch(
                            fingerIndex: 2,
                            normalizedX: self.currentRightSwipeNX,
                            normalizedY: self.currentRightSwipeNY,
                            isTouching: true,
                            isMoving: false
                        )
                    } else {
                        self.currentRightSwipeNX += Double(rx) * 0.008
                        self.currentRightSwipeNY += Double(ry) * 0.008
                        if abs(self.currentRightSwipeNX - rNode.normalizedX) > 0.18 || abs(self.currentRightSwipeNY - rNode.normalizedY) > 0.18 {
                            self.currentRightSwipeNX = rNode.normalizedX
                            self.currentRightSwipeNY = rNode.normalizedY
                        }
                        NoInjectSystemTouchEngine.shared.sendSystemTouch(
                            fingerIndex: 2,
                            normalizedX: self.currentRightSwipeNX,
                            normalizedY: self.currentRightSwipeNY,
                            isTouching: true,
                            isMoving: true
                        )
                    }
                }
            } else if self.rightStickWasActive {
                self.rightStickWasActive = false
                NoInjectSystemTouchEngine.shared.sendSystemTouch(
                    fingerIndex: 2,
                    normalizedX: self.currentRightSwipeNX,
                    normalizedY: self.currentRightSwipeNY,
                    isTouching: false,
                    isMoving: false
                )
            }
        }
    }

    func handleControllerButtonEvent(keyCode: String, shortLabel: String, isPressed: Bool) {
        if isPressed, let waitingID = selectedNodeIDForRebind {
            if let idx = profile.mappings.firstIndex(where: { $0.id == waitingID }) {
                profile.mappings[idx].boundKey = keyCode
                profile.mappings[idx].label = shortLabel
                selectedNodeIDForRebind = nil
                saveProfile()
                statusBannerText = "✅ Đã gán phím [\(shortLabel)] vào nút [\(profile.mappings[idx].actionName)]!"
            }
            return
        }

        if isPressed {
            activeButtons.insert(keyCode)
        } else {
            activeButtons.remove(keyCode)
        }

        for (index, item) in profile.mappings.enumerated() where !item.isJoystick && item.boundKey == keyCode {
            if isPressed {
                if item.actionName.lowercased().contains("nhảy") || item.id.contains("NODE_A") {
                    triggerSimulatedJump()
                } else {
                    simLastActionText = "Kích hoạt: \(item.actionName) [\(shortLabel)]"
                }
            }
            NoInjectSystemTouchEngine.shared.sendSystemTouch(
                fingerIndex: UInt32(index + 3),
                normalizedX: item.normalizedX,
                normalizedY: item.normalizedY,
                isTouching: isPressed,
                isMoving: false
            )
        }
    }

    private func triggerSimulatedJump() {
        guard !simIsJumping else { return }
        simIsJumping = true
        simLastActionText = "⬆️ NHẢY (JUMP)!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak self] in
            self?.simIsJumping = false
        }
    }

    func addNewCustomButton() {
        let customNum = max(profile.mappings.count - 1, 1)
        let newID = "CUSTOM_\(UUID().uuidString.prefix(5))"
        let newItem = KeyMappingItem(
            id: newID,
            boundKey: "BTN_A",
            label: "?",
            actionName: "Nút tùy chỉnh #\(customNum)",
            normalizedX: 0.50,
            normalizedY: 0.55,
            radius: 27.0,
            isJoystick: false
        )
        profile.mappings.append(newItem)
        selectedNodeIDForRebind = newID
        saveProfile()
        statusBannerText = "👉 Đã tạo nút mới! Hãy BẤM 1 PHÍM BẤT KỲ trên tay cầm Flydigi (kể cả C, Z, M1-M4) để gán."
    }

    func deleteButton(id: String) {
        profile.mappings.removeAll { $0.id == id && !$0.isJoystick }
        if selectedNodeIDForRebind == id { selectedNodeIDForRebind = nil }
        saveProfile()
        statusBannerText = "Đã xóa nút khỏi màn hình."
    }

    func applyDeadzoneAndCurve(rawX: Double, rawY: Double, isLeftStick: Bool) -> CGPoint {
        let calX = rawX - (isLeftStick ? profile.leftCenterOffsetX : profile.rightCenterOffsetX)
        let calY = rawY - (isLeftStick ? profile.leftCenterOffsetY : profile.rightCenterOffsetY)

        let innerDZ = isLeftStick ? profile.leftInnerDeadzone : profile.rightInnerDeadzone
        let outerDZ = max(isLeftStick ? profile.leftOuterDeadzone : profile.rightOuterDeadzone, innerDZ + 0.05)
        let curve = isLeftStick ? profile.leftResponseCurve : profile.rightResponseCurve

        let mag = sqrt(calX * calX + calY * calY)
        guard mag > innerDZ else { return .zero }

        let normalizedMag = min((mag - innerDZ) / (outerDZ - innerDZ), 1.0)
        let curvedMag = pow(normalizedMag, curve)
        let dirX = calX / mag
        let dirY = calY / mag

        if isLeftStick {
            return CGPoint(x: dirX * curvedMag, y: dirY * curvedMag)
        } else {
            let finalY = profile.invertRightY ? -dirY : dirY
            return CGPoint(
                x: max(min(dirX * curvedMag * profile.rightSensitivityX, 1.0), -1.0),
                y: max(min(finalY * curvedMag * profile.rightSensitivityY, 1.0), -1.0)
            )
        }
    }

    func calibrateStickCenterNow() {
        profile.leftCenterOffsetX = Double(rawLeftStick.x)
        profile.leftCenterOffsetY = Double(rawLeftStick.y)
        profile.rightCenterOffsetX = Double(rawRightStick.x)
        profile.rightCenterOffsetY = Double(rawRightStick.y)
        leftStickVector = .zero
        rightStickVector = .zero
        saveProfile()
    }

    func resetZeroCalibration() {
        profile.leftCenterOffsetX = 0.0
        profile.leftCenterOffsetY = 0.0
        profile.rightCenterOffsetX = 0.0
        profile.rightCenterOffsetY = 0.0
        saveProfile()
    }

    func saveProfile() {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    func resetProfile() {
        profile = ControllerProfile.defaultPlayTogetherProfile()
        selectedNodeIDForRebind = nil
        saveProfile()
        statusBannerText = "Đã khôi phục sơ đồ nút chuẩn cho Play Together VNG."
    }

    // MARK: - 5. Nhận Diện Mọi Tay Cầm Bluetooth Flydigi Qua GCController (iOS XInput, Switch NS, MFi)

    private func setupAllHardwareObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.refreshSystemControllers() }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.refreshSystemControllers() }
        nc.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in self?.bindUSBKeyboardOrDongle() }
        nc.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] _ in self?.bindUSBMouseOrDongle() }

        GCController.startWirelessControllerDiscovery {}
        refreshSystemControllers()
        bindUSBKeyboardOrDongle()
        bindUSBMouseOrDongle()
    }

    func triggerSystemWirelessDiscovery() {
        GCController.startWirelessControllerDiscovery {}
        refreshSystemControllers()
        startBLEScan()
    }

    func refreshSystemControllers() {
        if let controller = GCController.controllers().first {
            isConnected = true
            let rawName = controller.vendorName ?? "Flydigi Bluetooth Controller"
            let category = controller.productCategory.lowercased()
            let classification = Self.classifyFlydigiSeries(from: rawName + " " + category)
            detectedModelName = classification.seriesLabel

            if rawName.lowercased().contains("2.4") || rawName.lowercased().contains("dongle") || rawName.lowercased().contains("receiver") {
                activeTransport = .dongle24G
            } else if controller.isAttachedToDevice || category.contains("wired") || rawName.lowercased().contains("usb") {
                activeTransport = .wiredUSB
            } else if rawName.lowercased().contains("pro controller") || category.contains("switch") {
                activeTransport = .bluetoothSwitch
            } else {
                activeTransport = .bluetoothXInput
            }

            controllerName = rawName
            if let battery = controller.battery { batteryLevel = battery.batteryLevel }
            bindGCControllerInput(controller)
            return
        }

        if let ble = connectedPeripheral, ble.state == .connected {
            isConnected = true
            activeTransport = .bluetoothBLE
            controllerName = ble.name ?? "Flydigi BLE Controller"
            return
        }

        isConnected = false
        activeTransport = .none
        controllerName = "Kết nối Tay cầm Flydigi"
        batteryLevel = -1.0
        rawLeftStick = .zero
        rawRightStick = .zero
        leftStickVector = .zero
        rightStickVector = .zero
        activeButtons.removeAll()
    }

    private func bindGCControllerInput(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }

        gamepad.leftThumbstick.valueChangedHandler = { [weak self] (_: GCControllerDirectionPad, x: Float, y: Float) in
            guard let self = self else { return }
            DispatchQueue.main.async {
                let lx = Double(x)
                let ly = Double(-y)
                self.rawLeftStick = CGPoint(x: lx, y: ly)
                self.leftStickVector = self.applyDeadzoneAndCurve(rawX: lx, rawY: ly, isLeftStick: true)
            }
        }
        gamepad.rightThumbstick.valueChangedHandler = { [weak self] (_: GCControllerDirectionPad, x: Float, y: Float) in
            guard let self = self else { return }
            DispatchQueue.main.async {
                let rx = Double(x)
                let ry = Double(-y)
                self.rawRightStick = CGPoint(x: rx, y: ry)
                self.rightStickVector = self.applyDeadzoneAndCurve(rawX: rx, rawY: ry, isLeftStick: false)
            }
        }

        // Hỗ trợ tự động đảo nút A<->B, X<->Y nếu tay cầm Flydigi đang gạt sang chế độ Switch (NS) và bật tùy chọn đảo
        gamepad.buttonA.pressedChangedHandler = { [weak self] (_: GCControllerButtonInput, _: Float, pressed: Bool) in
            guard let self = self else { return }
            let code = self.profile.swapSwitchABXY ? "BTN_B" : "BTN_A"
            let lbl  = self.profile.swapSwitchABXY ? "B" : "A"
            DispatchQueue.main.async { self.handleControllerButtonEvent(keyCode: code, shortLabel: lbl, isPressed: pressed) }
        }
        gamepad.buttonB.pressedChangedHandler = { [weak self] (_: GCControllerButtonInput, _: Float, pressed: Bool) in
            guard let self = self else { return }
            let code = self.profile.swapSwitchABXY ? "BTN_A" : "BTN_B"
            let lbl  = self.profile.swapSwitchABXY ? "A" : "B"
            DispatchQueue.main.async { self.handleControllerButtonEvent(keyCode: code, shortLabel: lbl, isPressed: pressed) }
        }
        gamepad.buttonX.pressedChangedHandler = { [weak self] (_: GCControllerButtonInput, _: Float, pressed: Bool) in
            guard let self = self else { return }
            let code = self.profile.swapSwitchABXY ? "BTN_Y" : "BTN_X"
            let lbl  = self.profile.swapSwitchABXY ? "Y" : "X"
            DispatchQueue.main.async { self.handleControllerButtonEvent(keyCode: code, shortLabel: lbl, isPressed: pressed) }
        }
        gamepad.buttonY.pressedChangedHandler = { [weak self] (_: GCControllerButtonInput, _: Float, pressed: Bool) in
            guard let self = self else { return }
            let code = self.profile.swapSwitchABXY ? "BTN_X" : "BTN_Y"
            let lbl  = self.profile.swapSwitchABXY ? "X" : "Y"
            DispatchQueue.main.async { self.handleControllerButtonEvent(keyCode: code, shortLabel: lbl, isPressed: pressed) }
        }
        gamepad.leftShoulder.pressedChangedHandler = { [weak self] (_: GCControllerButtonInput, _: Float, pressed: Bool) in
            DispatchQueue.main.async { self?.handleControllerButtonEvent(keyCode: "BTN_LB", shortLabel: "LB", isPressed: pressed) }
        }
        gamepad.rightShoulder.pressedChangedHandler = { [weak self] (_: GCControllerButtonInput, _: Float, pressed: Bool) in
            DispatchQueue.main.async { self?.handleControllerButtonEvent(keyCode: "BTN_RB", shortLabel: "RB", isPressed: pressed) }
        }
        gamepad.leftTrigger.valueChangedHandler = { [weak self] (_: GCControllerButtonInput, val: Float, pressed: Bool) in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.leftTriggerValue = Double(val)
                let active = Double(val) >= self.profile.triggerDeadzone || pressed
                self.handleControllerButtonEvent(keyCode: "BTN_LT", shortLabel: "LT", isPressed: active)
            }
        }
        gamepad.rightTrigger.valueChangedHandler = { [weak self] (_: GCControllerButtonInput, val: Float, pressed: Bool) in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.rightTriggerValue = Double(val)
                let active = Double(val) >= self.profile.triggerDeadzone || pressed
                self.handleControllerButtonEvent(keyCode: "BTN_RT", shortLabel: "RT", isPressed: active)
            }
        }
        if let l3 = gamepad.leftThumbstickButton {
            l3.pressedChangedHandler = { [weak self] (_: GCControllerButtonInput, _: Float, pressed: Bool) in
                DispatchQueue.main.async { self?.handleControllerButtonEvent(keyCode: "BTN_L3", shortLabel: "L3", isPressed: pressed) }
            }
        }
        if let r3 = gamepad.rightThumbstickButton {
            r3.pressedChangedHandler = { [weak self] (_: GCControllerButtonInput, _: Float, pressed: Bool) in
                DispatchQueue.main.async { self?.handleControllerButtonEvent(keyCode: "BTN_R3", shortLabel: "R3", isPressed: pressed) }
            }
        }
        gamepad.dpad.up.pressedChangedHandler = { [weak self] (_: GCControllerButtonInput, _: Float, pressed: Bool) in
            DispatchQueue.main.async { self?.handleControllerButtonEvent(keyCode: "DPAD_UP", shortLabel: "↑", isPressed: pressed) }
        }
        gamepad.dpad.down.pressedChangedHandler = { [weak self] (_: GCControllerButtonInput, _: Float, pressed: Bool) in
            DispatchQueue.main.async { self?.handleControllerButtonEvent(keyCode: "DPAD_DOWN", shortLabel: "↓", isPressed: pressed) }
        }
        gamepad.dpad.left.pressedChangedHandler = { [weak self] (_: GCControllerButtonInput, _: Float, pressed: Bool) in
            DispatchQueue.main.async { self?.handleControllerButtonEvent(keyCode: "DPAD_LEFT", shortLabel: "←", isPressed: pressed) }
        }
        gamepad.dpad.right.pressedChangedHandler = { [weak self] (_: GCControllerButtonInput, _: Float, pressed: Bool) in
            DispatchQueue.main.async { self?.handleControllerButtonEvent(keyCode: "DPAD_RIGHT", shortLabel: "→", isPressed: pressed) }
        }
    }

    private func bindUSBKeyboardOrDongle() {
        guard let keyboard = GCKeyboard.coalesced?.keyboardInput else { return }
        if !isConnected {
            isConnected = true
            activeTransport = .dongle24G
            controllerName = "Flydigi Q1 / 2.4GHz HID"
        }
        keyboard.keyChangedHandler = { [weak self] (_: GCKeyboardInput, _: GCControllerButtonInput, keyCode: GCKeyCode, pressed: Bool) in
            guard let self = self else { return }
            DispatchQueue.main.async {
                switch keyCode {
                case .keyW:
                    self.rawLeftStick.y = pressed ? -1.0 : 0.0
                    self.leftStickVector = self.applyDeadzoneAndCurve(rawX: self.rawLeftStick.x, rawY: self.rawLeftStick.y, isLeftStick: true)
                case .keyS:
                    self.rawLeftStick.y = pressed ? 1.0 : 0.0
                    self.leftStickVector = self.applyDeadzoneAndCurve(rawX: self.rawLeftStick.x, rawY: self.rawLeftStick.y, isLeftStick: true)
                case .keyA:
                    self.rawLeftStick.x = pressed ? -1.0 : 0.0
                    self.leftStickVector = self.applyDeadzoneAndCurve(rawX: self.rawLeftStick.x, rawY: self.rawLeftStick.y, isLeftStick: true)
                case .keyD:
                    self.rawLeftStick.x = pressed ? 1.0 : 0.0
                    self.leftStickVector = self.applyDeadzoneAndCurve(rawX: self.rawLeftStick.x, rawY: self.rawLeftStick.y, isLeftStick: true)
                case .spacebar:
                    self.handleControllerButtonEvent(keyCode: "BTN_A", shortLabel: "A", isPressed: pressed)
                case .keyE, .returnOrEnter:
                    self.handleControllerButtonEvent(keyCode: "BTN_B", shortLabel: "B", isPressed: pressed)
                default: break
                }
            }
        }
    }

    private func bindUSBMouseOrDongle() {
        guard let mouse = GCMouse.current?.mouseInput else { return }
        mouse.mouseMovedHandler = { [weak self] (_: GCMouseInput, deltaX: Float, deltaY: Float) in
            guard let self = self else { return }
            DispatchQueue.main.async {
                let clampedX = max(min(Double(deltaX) / 15.0, 1.0), -1.0)
                let clampedY = max(min(Double(-deltaY) / 15.0, 1.0), -1.0)
                self.rawRightStick = CGPoint(x: clampedX, y: clampedY)
                self.rightStickVector = self.applyDeadzoneAndCurve(rawX: clampedX, rawY: clampedY, isLeftStick: false)
            }
        }
    }

    // MARK: - 6. CoreBluetooth BLE Direct Scanner & Universal Flydigi Packet Decoder (Apex, Vader, Direwolf, Wasp, Wee, Q1)

    func startBLEScan() {
        guard centralManager.state == .poweredOn else { return }
        discoveredDevices.removeAll()
        isScanningBLE = true
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])

        // Lấy luôn mọi tay cầm Flydigi đang kết nối ngầm qua các UUID dịch vụ của Flydigi
        let connectedHIDs = centralManager.retrieveConnectedPeripherals(withServices: allFlydigiServiceUUIDs)
        for p in connectedHIDs { addOrUpdateDiscoveredPeripheral(p, advData: [:], rssi: -45) }
    }

    func stopBLEScan() {
        centralManager.stopScan()
        isScanningBLE = false
    }

    func connectToBLEDevice(_ device: DiscoveredBLEDevice) {
        stopBLEScan()
        connectedPeripheral = device.peripheral
        connectedPeripheral?.delegate = self
        centralManager.connect(device.peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    private func addOrUpdateDiscoveredPeripheral(_ peripheral: CBPeripheral, advData: [String: Any], rssi: Int) {
        let advName = (advData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let rawName = (peripheral.name ?? advName).trimmingCharacters(in: .whitespacesAndNewlines)
        let info = Self.classifyFlydigiSeries(from: rawName)

        if !showAllBLEDevices && rawName.isEmpty { return }
        let displayName = rawName.isEmpty ? "Thiết bị BLE (\(peripheral.identifier.uuidString.prefix(6)))" : rawName

        if let idx = discoveredDevices.firstIndex(where: { $0.id == peripheral.identifier }) {
            discoveredDevices[idx].name = displayName
            discoveredDevices[idx].detectedSeries = info.seriesLabel
            discoveredDevices[idx].rssi = rssi
            discoveredDevices[idx].isFlydigi = info.isFlydigi
        } else {
            discoveredDevices.append(
                DiscoveredBLEDevice(
                    id: peripheral.identifier,
                    peripheral: peripheral,
                    name: displayName,
                    detectedSeries: info.seriesLabel,
                    rssi: rssi,
                    isFlydigi: info.isFlydigi
                )
            )
            discoveredDevices.sort { ($0.isFlydigi ? 0 : 1) < ($1.isFlydigi ? 0 : 1) }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            bleStateText = "Bluetooth Sẵn sàng (Hỗ trợ mọi dòng Flydigi)"
            startBLEScan()
        } else {
            bleStateText = "Hãy bật Bluetooth trên máy"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        addOrUpdateDiscoveredPeripheral(peripheral, advData: advertisementData, rssi: RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        activeTransport = .bluetoothBLE
        let name = peripheral.name ?? "Flydigi BLE Controller"
        controllerName = name
        detectedModelName = Self.classifyFlydigiSeries(from: name).seriesLabel
        statusBannerText = "✅ Đã kết nối Bluetooth BLE: \(name) (\(detectedModelName))"
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if connectedPeripheral?.identifier == peripheral.identifier { connectedPeripheral = nil }
        blePressedSet.removeAll()
        refreshSystemControllers()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for ch in chars {
            if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: ch)
            }
            if ch.properties.contains(.read) {
                peripheral.readValue(for: ch)
            }
        }
    }

    // Giải mã đa giao thức cho tất cả các dòng tay cầm Bluetooth nhà Flydigi (Flashplay v1/v2, Next-Gen Apex/Vader/Direwolf, Wasp/Wee 1-hand, và BLE HID)
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        let bytes = [UInt8](data)

        if characteristic.uuid == CBUUID(string: "2A19"), let first = bytes.first {
            batteryLevel = Float(min(Int(first), 100)) / 100.0
            return
        }

        guard bytes.count >= 5 else { return }

        // Tự động nhận diện Header của từng đời tay cầm Flydigi:
        // - 0xFE / 0xFD / 0xA1 / 0x01: Gói Flashplay / Flydigi Custom GATT (Apex 1-6, Vader 2-5, Direwolf 1-4)
        // - Không có header: Gói HID chuẩn hoặc Wasp / Wee 2T
        let hasHeader = (bytes[0] == 0xFE || bytes[0] == 0xFD || bytes[0] == 0xA1 || bytes[0] == 0x01) && bytes.count >= 7
        let offset = hasHeader ? 1 : 0

        let rawLX = max(min((Double(bytes[offset]) - 128.0) / 127.0, 1.0), -1.0)
        let rawLY = max(min((Double(bytes[offset + 1]) - 128.0) / 127.0, 1.0), -1.0)

        var rawRX = 0.0
        var rawRY = 0.0
        if bytes.count > offset + 3 {
            rawRX = max(min((Double(bytes[offset + 2]) - 128.0) / 127.0, 1.0), -1.0)
            rawRY = max(min((Double(bytes[offset + 3]) - 128.0) / 127.0, 1.0), -1.0)
        }

        rawLeftStick = CGPoint(x: rawLX, y: rawLY)
        rawRightStick = CGPoint(x: rawRX, y: rawRY)
        leftStickVector = applyDeadzoneAndCurve(rawX: rawLX, rawY: rawLY, isLeftStick: true)
        rightStickVector = applyDeadzoneAndCurve(rawX: rawRX, rawY: rawRY, isLeftStick: false)

        let btn1 = bytes.count > (offset + 4) ? bytes[offset + 4] : 0
        let btn2 = bytes.count > (offset + 5) ? bytes[offset + 5] : 0
        let btn3 = bytes.count > (offset + 6) ? bytes[offset + 6] : 0

        // Đọc đầy đủ các nút của mọi dòng Flydigi: A, B, X, Y, LB, RB, LT, RT, C, Z (Vader/Apex), và 4 nút lưng M1, M2, M3, M4
        let keyStates: [(String, String, Bool)] = [
            ("BTN_A",  "A",  (btn1 & 0x01) != 0),
            ("BTN_B",  "B",  (btn1 & 0x02) != 0),
            ("BTN_X",  "X",  (btn1 & 0x04) != 0 || (btn1 & 0x08) != 0),
            ("BTN_Y",  "Y",  (btn1 & 0x10) != 0),
            ("BTN_C",  "C",  (btn1 & 0x20) != 0 || (btn3 & 0x10) != 0),
            ("BTN_LB", "LB", (btn1 & 0x40) != 0),
            ("BTN_RB", "RB", (btn1 & 0x80) != 0),
            ("BTN_LT", "LT", (btn2 & 0x01) != 0),
            ("BTN_RT", "RT", (btn2 & 0x02) != 0),
            ("BTN_Z",  "Z",  (btn2 & 0x04) != 0 || (btn3 & 0x20) != 0),
            ("BTN_M1", "M1", (btn2 & 0x10) != 0 || (btn3 & 0x01) != 0),
            ("BTN_M2", "M2", (btn2 & 0x20) != 0 || (btn3 & 0x02) != 0),
            ("BTN_M3", "M3", (btn2 & 0x40) != 0 || (btn3 & 0x04) != 0),
            ("BTN_M4", "M4", (btn2 & 0x80) != 0 || (btn3 & 0x08) != 0)
        ]

        for (code, label, isNowDown) in keyStates {
            let wasDown = blePressedSet.contains(code)
            if isNowDown && !wasDown {
                blePressedSet.insert(code)
                handleControllerButtonEvent(keyCode: code, shortLabel: label, isPressed: true)
            } else if !isNowDown && wasDown {
                blePressedSet.remove(code)
                handleControllerButtonEvent(keyCode: code, shortLabel: label, isPressed: false)
            }
        }
    }
}

// MARK: - 7. Image Picker

struct GameScreenshotPicker: UIViewControllerRepresentable {
    @Binding var selectedImage: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .photoLibrary
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: GameScreenshotPicker
        init(_ parent: GameScreenshotPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.selectedImage = img
            }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - 8. Main User Interface

@main
struct FlydigiPlayTogetherApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var manager = FlydigiGamepadManager()
    @State private var showConnectionHub = false
    @State private var showDeadzoneStudio = false
    @State private var showPhotoPicker = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let bgImg = manager.customGameScreenshot {
                    Image(uiImage: bgImg)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .ignoresSafeArea()
                } else {
                    LinearGradient(
                        colors: [Color(red: 0.09, green: 0.20, blue: 0.32), Color(red: 0.05, green: 0.11, blue: 0.19)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()

                    SimulatedPlayTogetherArena(manager: manager)
                }

                VStack(spacing: 5) {
                    pandaTopToolbar
                    Text(manager.statusBannerText)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(manager.isSafeBackgroundModeRunning ? .green : .yellow)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.75))
                        .cornerRadius(10)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .zIndex(15)

                ForEach($manager.profile.mappings) { $item in
                    PandaCustomizableNodeView(
                        item: $item,
                        canvasSize: geo.size,
                        isPressed: manager.activeButtons.contains(item.boundKey),
                        isWaitingRebind: manager.selectedNodeIDForRebind == item.id,
                        globalOpacity: manager.profile.globalOpacity,
                        stickVector: item.id == "L_STICK" ? manager.leftStickVector : (item.id == "R_STICK" ? manager.rightStickVector : .zero),
                        innerDeadzoneRatio: item.id == "L_STICK" ? manager.profile.leftInnerDeadzone : manager.profile.rightInnerDeadzone,
                        onSelectForRebind: {
                            if manager.selectedNodeIDForRebind == item.id {
                                manager.selectedNodeIDForRebind = nil
                                manager.statusBannerText = "Đã hủy chọn đổi phím."
                            } else {
                                manager.selectedNodeIDForRebind = item.id
                                manager.statusBannerText = "👉 Đang chọn [\(item.actionName)]: Hãy BẤM 1 PHÍM TRÊN TAY CẦM FLYDIGI để gán!"
                            }
                        },
                        onDelete: {
                            manager.deleteButton(id: item.id)
                        },
                        onDragEnded: {
                            manager.saveProfile()
                        }
                    )
                }
            }
        }
        .sheet(isPresented: $showConnectionHub) {
            ConnectionHubSheetView(manager: manager)
        }
        .sheet(isPresented: $showDeadzoneStudio) {
            DeadzoneStudioSheetView(manager: manager)
        }
        .sheet(isPresented: $showPhotoPicker) {
            GameScreenshotPicker(selectedImage: $manager.customGameScreenshot)
        }
    }

    private var pandaTopToolbar: some View {
        HStack(spacing: 6) {
            Button {
                showConnectionHub = true
            } label: {
                HStack(spacing: 5) {
                    Text("🐼")
                    Circle()
                        .fill(manager.isConnected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(manager.controllerName)
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.78))
                .cornerRadius(14)
            }

            Button {
                showPhotoPicker = true
            } label: {
                Label("Ảnh Game", systemImage: "photo.on.rectangle")
                    .font(.caption.bold())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.teal)
                    .foregroundColor(.black)
                    .cornerRadius(14)
            }

            Button {
                manager.addNewCustomButton()
            } label: {
                Label("Thêm Nút", systemImage: "plus.circle.fill")
                    .font(.caption.bold())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.green)
                    .foregroundColor(.black)
                    .cornerRadius(14)
            }

            HStack(spacing: 4) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.caption2)
                    .foregroundColor(.cyan)
                Text("\(Int(manager.profile.globalOpacity * 100))%")
                    .font(.caption2.bold().monospacedDigit())
                    .foregroundColor(.cyan)
                    .frame(width: 32)
                Slider(value: $manager.profile.globalOpacity, in: 0.0...1.0, step: 0.05) { _ in
                    manager.saveProfile()
                }
                .frame(width: 80)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.75))
            .cornerRadius(14)

            Button {
                showDeadzoneStudio = true
            } label: {
                Label("Deadzone", systemImage: "dial.high.fill")
                    .font(.caption.bold())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.purple)
                    .foregroundColor(.white)
                    .cornerRadius(14)
            }

            Button {
                manager.toggleSafeBackgroundBridgeAndLaunchGame()
            } label: {
                Label(
                    manager.isSafeBackgroundModeRunning ? "Đang Chạy Nền" : "Bật Chạy Nền (An Toàn)",
                    systemImage: manager.isSafeBackgroundModeRunning ? "checkmark.shield.fill" : "shield.lefthalf.filled"
                )
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(manager.isSafeBackgroundModeRunning ? Color.green : Color.orange)
                .foregroundColor(.black)
                .cornerRadius(14)
            }
        }
    }
}

struct SimulatedPlayTogetherArena: View {
    @ObservedObject var manager: FlydigiGamepadManager

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1.5)
                .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.03)))
                .padding(.horizontal, 40)
                .padding(.vertical, 55)

            VStack(spacing: 4) {
                Text(manager.simLastActionText)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.yellow)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.65))
                    .cornerRadius(8)

                ZStack {
                    Ellipse()
                        .fill(Color.black.opacity(0.4))
                        .frame(width: 36, height: 14)
                        .offset(y: 22)

                    Circle()
                        .fill(manager.simIsJumping ? Color.green : Color.cyan)
                        .frame(width: 38, height: 38)
                        .overlay(
                            Image(systemName: manager.simIsJumping ? "figure.jumprope" : "figure.walk")
                                .font(.title3.bold())
                                .foregroundColor(.black)
                        )
                        .offset(y: manager.simIsJumping ? -34 : 0)
                        .animation(.easeOut(duration: 0.18), value: manager.simIsJumping)
                }
            }
            .position(manager.simCharPos)
        }
    }
}

struct PandaCustomizableNodeView: View {
    @Binding var item: KeyMappingItem
    let canvasSize: CGSize
    let isPressed: Bool
    let isWaitingRebind: Bool
    let globalOpacity: Double
    let stickVector: CGPoint
    let innerDeadzoneRatio: Double
    let onSelectForRebind: () -> Void
    let onDelete: () -> Void
    let onDragEnded: () -> Void

    var body: some View {
        let posX = item.normalizedX * max(canvasSize.width, 1)
        let posY = item.normalizedY * max(canvasSize.height, 1)

        ZStack {
            if item.isJoystick {
                Circle()
                    .strokeBorder(Color.cyan, lineWidth: 2.2)
                    .background(Circle().fill(Color.cyan.opacity(0.15)))
                    .frame(width: item.radius * 2, height: item.radius * 2)

                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                    .foregroundColor(.red)
                    .frame(
                        width: item.radius * 2 * CGFloat(innerDeadzoneRatio),
                        height: item.radius * 2 * CGFloat(innerDeadzoneRatio)
                    )

                Circle()
                    .fill(Color.cyan)
                    .frame(width: 26, height: 26)
                    .offset(
                        x: stickVector.x * (item.radius - 13),
                        y: stickVector.y * (item.radius - 13)
                    )

                VStack(spacing: 1) {
                    Text(item.label).font(.caption.bold()).foregroundColor(.white)
                    Text(item.actionName).font(.system(size: 9)).foregroundColor(.cyan)
                }
            } else {
                ZStack(alignment: .topTrailing) {
                    VStack(spacing: 2) {
                        ZStack {
                            Circle()
                                .fill(isWaitingRebind ? Color.orange : (isPressed ? Color.green : Color.black.opacity(0.75)))
                                .frame(width: item.radius * 2, height: item.radius * 2)
                                .overlay(
                                    Circle()
                                        .stroke(isWaitingRebind ? Color.yellow : (isPressed ? Color.white : Color.green), lineWidth: 2)
                                )
                            Text(isWaitingRebind ? "Bấm..." : item.label)
                                .font(.system(size: 13, weight: .heavy))
                                .foregroundColor(.white)
                        }
                        Text(item.actionName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .background(Color.black.opacity(0.55))
                            .cornerRadius(4)
                    }
                    .onTapGesture { onSelectForRebind() }

                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.red)
                            .background(Circle().fill(Color.white))
                    }
                    .offset(x: 6, y: -6)
                }
            }
        }
        .opacity(isWaitingRebind ? 1.0 : globalOpacity)
        .position(x: posX, y: posY)
        .gesture(
            DragGesture()
                .onChanged { value in
                    let clampedX = min(max(value.location.x / max(canvasSize.width, 1), 0.04), 0.96)
                    let clampedY = min(max(value.location.y / max(canvasSize.height, 1), 0.06), 0.94)
                    item.normalizedX = clampedX
                    item.normalizedY = clampedY
                }
                .onEnded { _ in onDragEnded() }
        )
    }
}

struct DeadzoneStudioSheetView: View {
    @ObservedObject var manager: FlydigiGamepadManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("1. Kiểm tra trực tiếp Cần Analog (Live Radar)")) {
                    VStack(spacing: 12) {
                        HStack(spacing: 24) {
                            AnalogStickRadarView(
                                title: "Cần Trái (L-Stick)",
                                rawPoint: manager.rawLeftStick,
                                processedPoint: manager.leftStickVector,
                                innerDeadzone: manager.profile.leftInnerDeadzone,
                                outerDeadzone: manager.profile.leftOuterDeadzone
                            )
                            AnalogStickRadarView(
                                title: "Cần Phải (R-Stick)",
                                rawPoint: manager.rawRightStick,
                                processedPoint: manager.rightStickVector,
                                innerDeadzone: manager.profile.rightInnerDeadzone,
                                outerDeadzone: manager.profile.rightOuterDeadzone
                            )
                        }
                        .frame(maxWidth: .infinity)

                        HStack(spacing: 12) {
                            Button {
                                manager.calibrateStickCenterNow()
                            } label: {
                                Label("⚖️ Cân tâm chống trôi", systemImage: "scope").font(.caption.bold())
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.teal)

                            Button("Xóa lệch tâm") {
                                manager.resetZeroCalibration()
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }
                    }
                }

                Section(header: Text("2. Độ mờ / Trong suốt nút (0% -> 100%)")) {
                    VStack(alignment: .leading) {
                        Text("Độ hiển thị nút: \(Int(manager.profile.globalOpacity * 100))% (0% = Trong suốt hoàn toàn)")
                        Slider(value: $manager.profile.globalOpacity, in: 0.0...1.0, step: 0.05) { _ in
                            manager.saveProfile()
                        }
                    }
                }

                Section(header: Text("3. Deadzone Cần Trái & Cần Phải")) {
                    VStack(alignment: .leading) {
                        Text("Vùng chết tâm Cần Trái (Inner Deadzone): \(Int(manager.profile.leftInnerDeadzone * 100))%")
                        Slider(value: $manager.profile.leftInnerDeadzone, in: 0.00...0.40, step: 0.01) { _ in
                            manager.saveProfile()
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Ngưỡng tốc độ tối đa (Outer Deadzone): \(Int(manager.profile.leftOuterDeadzone * 100))%")
                        Slider(value: $manager.profile.leftOuterDeadzone, in: 0.60...1.00, step: 0.01) { _ in
                            manager.saveProfile()
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Tốc độ xoay Camera Ngang (Trục X): \(String(format: "%.2f", manager.profile.rightSensitivityX))x")
                        Slider(value: $manager.profile.rightSensitivityX, in: 0.30...4.00, step: 0.05) { _ in
                            manager.saveProfile()
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Tốc độ xoay Camera Dọc (Trục Y): \(String(format: "%.2f", manager.profile.rightSensitivityY))x")
                        Slider(value: $manager.profile.rightSensitivityY, in: 0.30...4.00, step: 0.05) { _ in
                            manager.saveProfile()
                        }
                    }
                }

                Section {
                    Button("Khôi phục toàn bộ cài đặt gốc", role: .destructive) {
                        manager.resetProfile()
                    }
                }
            }
            .navigationTitle("Deadzone & Độ trong suốt")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu & Đóng") {
                        manager.saveProfile()
                        dismiss()
                    }
                }
            }
        }
    }
}

struct AnalogStickRadarView: View {
    let title: String
    let rawPoint: CGPoint
    let processedPoint: CGPoint
    let innerDeadzone: Double
    let outerDeadzone: Double
    private let radarSize: CGFloat = 108.0

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.caption.bold())
            ZStack {
                Circle().fill(Color.black.opacity(0.75)).frame(width: radarSize, height: radarSize)
                Circle().strokeBorder(Color.green.opacity(0.65), lineWidth: 1.5)
                    .frame(width: radarSize * CGFloat(outerDeadzone), height: radarSize * CGFloat(outerDeadzone))
                Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .foregroundColor(.red)
                    .frame(width: radarSize * CGFloat(innerDeadzone), height: radarSize * CGFloat(innerDeadzone))
                Circle().fill(processedPoint == .zero ? Color.red : Color.cyan)
                    .frame(width: 12, height: 12)
                    .offset(x: processedPoint.x * (radarSize / 2 - 6), y: processedPoint.y * (radarSize / 2 - 6))
            }
            Text(String(format: "Out: %.2f, %.2f", processedPoint.x, processedPoint.y))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.cyan)
        }
    }
}

// MARK: - 9. Trung Tâm Kết Nối Tất Cả Dòng Tay Cầm Bluetooth Flydigi

struct ConnectionHubSheetView: View {
    @ObservedObject var manager: FlydigiGamepadManager
    @Environment(\.dismiss) private var dismiss

    var selectedModelEnum: FlydigiControllerModel {
        FlydigiControllerModel(rawValue: manager.profile.selectedFlydigiModel) ?? .autoDetect
    }

    var body: some View {
        NavigationView {
            List {
                // Trạng thái hiện tại
                Section(header: Text("Trạng thái tay cầm Flydigi")) {
                    HStack {
                        Image(systemName: manager.isConnected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                            .foregroundColor(manager.isConnected ? .green : .orange)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(manager.controllerName).font(.headline)
                            Text("Dòng máy: \(manager.detectedModelName)")
                                .font(.caption.bold())
                                .foregroundColor(.cyan)
                            Text("Giao thức: \(manager.activeTransport.rawValue)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Chọn dòng tay cầm Flydigi đang dùng
                Section(header: Text("Chọn dòng tay cầm Flydigi của bạn")) {
                    Picker("Dòng tay cầm Flydigi", selection: $manager.profile.selectedFlydigiModel) {
                        ForEach(FlydigiControllerModel.allCases) { model in
                            Text(model.rawValue).tag(model.rawValue)
                        }
                    }
                    .onChange(of: manager.profile.selectedFlydigiModel) { _ in
                        manager.saveProfile()
                    }

                    Text(selectedModelEnum.pairingGuide)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Đảo vị trí nút A↔B & X↔Y (Dùng khi gạt sang nấc Switch NS)", isOn: $manager.profile.swapSwitchABXY)
                        .font(.caption)
                        .onChange(of: manager.profile.swapSwitchABXY) { _ in
                            manager.saveProfile()
                        }
                }

                // 1. Quét Bluetooth BLE cho mọi tay cầm Flydigi
                Section(header: Text("1. Quét Bluetooth BLE Trực tiếp (Apex, Vader, Direwolf, Wasp, Wee, Q1)")) {
                    HStack {
                        Text(manager.bleStateText).font(.subheadline)
                        Spacer()
                        Button(manager.isScanningBLE ? "Đang quét..." : "Quét Bluetooth") {
                            manager.startBLEScan()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Toggle("Hiện tất cả thiết bị Bluetooth xung quanh", isOn: $manager.showAllBLEDevices)
                        .font(.caption)
                        .onChange(of: manager.showAllBLEDevices) { _ in manager.startBLEScan() }

                    ForEach(manager.discoveredDevices) { dev in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(dev.name).font(.subheadline.bold())
                                    if dev.isFlydigi {
                                        Text("Flydigi")
                                            .font(.system(size: 10, weight: .bold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.cyan.opacity(0.25))
                                            .cornerRadius(6)
                                    }
                                }
                                Text("\(dev.detectedSeries) • RSSI: \(dev.rssi) dBm")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Kết nối") { manager.connectToBLEDevice(dev) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }

                // 2. Kết nối qua Bluetooth iOS (XInput / Switch NS) & Cáp USB / 2.4G
                Section(header: Text("2. Bluetooth iOS (XInput / Switch NS) & Cáp USB / 2.4G")) {
                    HStack {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label("Mở Cài đặt Bluetooth iOS", systemImage: "gear")
                        }
                        Spacer()
                        Button("Làm mới") {
                            manager.triggerSystemWirelessDiscovery()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .navigationTitle("Tất cả Tay cầm Flydigi")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { dismiss() }
                }
            }
        }
    }
}
