import AVFoundation
import AudioToolbox
import Foundation

/// One shared effect on a post-fader send: each source feeds `mixer` on its own bus, `node` returns 100% wet.
/// With no node (e.g. plugin not installed) nothing is attached and every call is a no-op.
final class SendBus {
    let node: AVAudioUnit?
    private let mixer = AVAudioMixerNode()
    private var levels: [Float]

    init(node: AVAudioUnit?, count: Int) {
        self.node = node
        levels = [Float](repeating: 0, count: count)
    }

    func install(on output: MotorOutput, to target: AVAudioNode, format: AVAudioFormat) {
        guard let node else { return }
        output.attach(mixer)
        output.attach(node)
        output.connect(mixer, to: node, format: format)
        output.connect(node, to: target, format: format)
    }

    func rewire(on output: MotorOutput, to target: AVAudioNode, format: AVAudioFormat) {
        guard let node else { return }
        output.reconnect(mixer, to: node, format: format)
        output.reconnect(node, to: target, format: format)
    }

    func points(_ index: Int) -> [AVAudioConnectionPoint] {
        node == nil ? [] : [AVAudioConnectionPoint(node: mixer, bus: index)]
    }

    func setLevel(_ index: Int, _ value: Double, source: AVAudioNode?) {
        guard levels.indices.contains(index) else { return }
        levels[index] = Float(min(1, max(0, value)))
        apply(index, source: source)
    }

    /// Re-applies the level after the source was (re)connected.
    func apply(_ index: Int, source: AVAudioNode?) {
        guard node != nil, levels.indices.contains(index), let mixing = source as? AVAudioMixing else { return }
        mixing.destination(forMixer: mixer, bus: index)?.volume = levels[index]
    }
}

/// Valhalla Supermassive: the system install if present, else the copy in the app's PlugIns folder.
/// Personal build only: the plugin is free but not redistributable.
enum Supermassive {
    private static let bundled: AudioComponentDescription? = registerBundled()

    /// Blocks: call while building the graph. A system install runs out of process; the bundled copy can only run in process.
    static func makeNode() -> AVAudioUnit? {
        let effects = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0,
            componentManufacturer: 0,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let installed = AVAudioUnitComponentManager.shared().components(matching: effects)
            .first(where: { $0.name.localizedCaseInsensitiveContains("Supermassive") })
        let description: AudioComponentDescription
        let options: AudioComponentInstantiationOptions
        if let installed {
            description = installed.audioComponentDescription
            options = .loadOutOfProcess
        } else if let bundled {
            description = bundled
            options = .loadInProcess
        } else {
            return nil
        }
        let semaphore = DispatchSemaphore(value: 0)
        var created: AVAudioUnit?
        AVAudioUnit.instantiate(with: description, options: options) { unit, _ in
            created = unit
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 5) == .success, let created else { return nil }
        forceWet(created)
        return created
    }

    /// A send must stay 100% wet whatever the plugin's own Mix says.
    static func forceWet(_ node: AVAudioUnit) {
        if let mix = node.auAudioUnit.parameterTree?.allParameters.first(where: { $0.displayName.lowercased() == "mix" }) {
            mix.value = mix.maxValue
        }
    }

    static func restore(_ node: AVAudioUnit, from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        node.auAudioUnit.fullState = state
        forceWet(node)
    }

    static func save(_ node: AVAudioUnit, to url: URL) {
        forceWet(node)
        guard let state = node.auAudioUnit.fullState,
              let data = try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Registers the AUv2 factory of `Contents/PlugIns/*Supermassive*.component` for this process only.
    private static func registerBundled() -> AudioComponentDescription? {
        guard let folder = Bundle.main.builtInPlugInsURL,
              let url = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "component" && $0.lastPathComponent.localizedCaseInsensitiveContains("Supermassive") }),
              let bundle = CFBundleCreate(nil, url as CFURL),
              let entry = (CFBundleGetInfoDictionary(bundle) as? [String: Any])?["AudioComponents"] as? [[String: Any]],
              let info = entry.first,
              let type = (info["type"] as? String).flatMap(fourCC),
              let subType = (info["subtype"] as? String).flatMap(fourCC),
              let manufacturer = (info["manufacturer"] as? String).flatMap(fourCC),
              let factoryName = info["factoryFunction"] as? String,
              CFBundleLoadExecutable(bundle),
              let pointer = CFBundleGetFunctionPointerForName(bundle, factoryName as CFString) else { return nil }
        var description = AudioComponentDescription(
            componentType: type,
            componentSubType: subType,
            componentManufacturer: manufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let factory = unsafeBitCast(pointer, to: AudioComponentFactoryFunction.self)
        let name = info["name"] as? String ?? "Valhalla Supermassive"
        let version = (info["version"] as? NSNumber)?.uint32Value ?? 1
        AudioComponentRegister(&description, name as CFString, version, factory)
        return description
    }

    private static func fourCC(_ text: String) -> OSType? {
        let bytes = Array(text.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(0) { $0 << 8 | OSType($1) }
    }
}
