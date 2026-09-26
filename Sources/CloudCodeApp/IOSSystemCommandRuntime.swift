import CloudCodeCore

// Compatibility name retained so older local call sites fail neither source discovery nor XcodeGen
// generation while the concrete implementation lives in IOSSystemRuntime.swift.
@available(*, deprecated, renamed: "IOSSystemRuntime")
public typealias IOSSystemCommandRuntime = IOSSystemRuntime
