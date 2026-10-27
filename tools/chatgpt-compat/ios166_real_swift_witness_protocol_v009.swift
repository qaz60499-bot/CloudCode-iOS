public protocol IPAWitnessMarker {}
extension Int: IPAWitnessMarker {}
@inline(never) public func ipaWitnessAnchor(_ x: Int) -> some IPAWitnessMarker { x }
