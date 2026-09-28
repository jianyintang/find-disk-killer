import Foundation
import Darwin

// Equivalent stored fields to AgentStorageCleanupArtifact, MutableNode and MutableFamily.
enum Category: String, CaseIterable, Hashable { case conversation, toolResult, subagent, fileHistory, attachment, snapshot, task, workflow, other }
enum Provider: String { case codex, claude, openCode }
struct Artifact: Equatable {
    let path: String; let allocatedBytes: UInt64; let device: UInt64; let inode: UInt64
    let logicalBytes: Int64; let blocks: Int64; let modifiedSeconds: Int64; let modifiedNanoseconds: Int64; let category: Category?
}
struct Node: Equatable {
    let id: String; let nativeID: String; let parentNativeID: String?; let depth: Int; let title: String; let updatedAt: Date
    var allocatedBytes: UInt64 = 0; var databaseAttributedBytes: UInt64 = 0; var artifactCount: Int = 0; var path: String?
    var cleanupArtifacts: [Artifact] = []
}
struct Family: Equatable {
    let id: String; let provider: Provider; let sourceID: String; let nativeThreadID: String; let title: String; let project: String; let projectPath: String?
    var updatedAt: Date; let isArchived: Bool; let mainNodeID: String; var path: String?; var nodes: [String: Node]
    var familyOtherAllocatedBytes: UInt64 = 0; var artifactCount: Int = 0; var composition: [Category: UInt64] = [:]; var cleanupArtifacts: [Artifact] = []
}
struct Mutation { let familyID: String; let nodeID: String; let artifact: Artifact }
struct Identity: Hashable { let device: UInt64; let inode: UInt64 }
enum Risk: Int { case rebuildableCache = 1, sharedOrExpensive, environmentOrRuntime, protectedUserData }
struct RichClaim { let sourceID: String; let rootID: String; let rootPath: String; let simulatorObjectIdentifier: String?; let category: String; let risk: Risk; let isProtected: Bool; let modifiedAt: Date }
struct RichEntry { let identity: Identity; let allocatedBytes: UInt64; let logicalBytes: UInt64; let volumeID: String?; var claims: [RichClaim] }
struct ClaimMetadata { let sourceID: String; let rootID: String; let rootPath: String; let simulatorObjectIdentifier: String?; let category: String; let risk: Risk; let isProtected: Bool }
// Exact date retained per entry; only invariant strings/semantics are interned. Identity remains in dictionary key.
struct CompactEntry { let allocatedBytes: UInt64; let logicalBytes: UInt64; let modifiedAt: Date; let claimID: UInt32; let volumeID: UInt32 }
let clock = ContinuousClock()
func elapsed(_ start: ContinuousClock.Instant) -> Double { let d = start.duration(to: clock.now); return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
extension UInt64 { func addingClamped(_ other: UInt64) -> UInt64 { let x = addingReportingOverflow(other); return x.overflow ? .max : x.partialValue } }
struct Checksum {
    var value: UInt64 = 14695981039346656037
    mutating func add(_ x: UInt64) { value = (value ^ x) &* 1099511628211 }
    mutating func add(_ s: String) { for b in s.utf8 { add(UInt64(b)) }; add(0xff) }
}
func maxRSS() -> Int64 { var r = rusage(); getrusage(RUSAGE_SELF, &r); return Int64(r.ru_maxrss) }
func emit(_ data: [String: Any]) { let encoded = try! JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]); print(String(decoding: encoded, as: UTF8.self)) }

func mutationFixture(count: Int, skewed: Bool) -> ([String: Family], [Mutation]) {
    let fCount = skewed ? 8 : 32, nCount = skewed ? 8 : 4
    let date = Date(timeIntervalSince1970: 1700000000)
    var families: [String: Family] = [:]
    for f in 0..<fCount {
        let fid = "family-\(f)"
        var nodes: [String: Node] = [:]
        for n in 0..<nCount {
            let nid = "node-\(n)"
            nodes[nid] = Node(id: nid, nativeID: "native-\(f)-\(n)", parentNativeID: n == 0 ? nil : "native-\(f)-0", depth: n == 0 ? 0 : 1, title: "Thread \(f)/\(n)", updatedAt: date)
        }
        families[fid] = Family(id: fid, provider: .codex, sourceID: "codex-home", nativeThreadID: "native-\(f)-0", title: "Family \(f)", project: "Project \(f)", projectPath: "/fixture/project/\(f)", updatedAt: date, isArchived: false, mainNodeID: "node-0", nodes: nodes)
    }
    let operations: [Mutation] = (0..<count).map { i in
        let slot = skewed && i % 10 != 0 ? 0 : (skewed ? i / 10 : i) % (fCount * nCount)
        let f = slot % fCount, n = slot / fCount
        let bytes = UInt64(i % 16 + 1) * 4096
        return Mutation(familyID: "family-\(f)", nodeID: "node-\(n)", artifact: Artifact(path: "/fixture/project/\(f)/session/node-\(n)/artifact-\(i).jsonl", allocatedBytes: bytes, device: 1, inode: UInt64(i + 1), logicalBytes: Int64(bytes - 31), blocks: Int64(bytes / 512), modifiedSeconds: 1700000000 + Int64(i), modifiedNanoseconds: Int64(i % 1000000000), category: Category.allCases[i % Category.allCases.count]))
    }
    return (families, operations)
}
@inline(never) func applyCopied(_ op: Mutation, to families: inout [String: Family]) {
    guard var family = families[op.familyID], var node = family.nodes[op.nodeID] else { fatalError() }
    node.allocatedBytes = node.allocatedBytes.addingClamped(op.artifact.allocatedBytes)
    node.artifactCount += 1
    node.path = node.path ?? op.artifact.path
    node.cleanupArtifacts.append(op.artifact)
    family.nodes[op.nodeID] = node
    family.artifactCount += 1
    family.composition[op.artifact.category!, default: 0] = family.composition[op.artifact.category!, default: 0].addingClamped(op.artifact.allocatedBytes)
    families[op.familyID] = family
}
@inline(never) func applyInPlace(_ op: Mutation, to families: inout [String: Family]) {
    guard families[op.familyID]?.nodes[op.nodeID] != nil else { fatalError() }
    families[op.familyID]!.nodes[op.nodeID]!.allocatedBytes = families[op.familyID]!.nodes[op.nodeID]!.allocatedBytes.addingClamped(op.artifact.allocatedBytes)
    families[op.familyID]!.nodes[op.nodeID]!.artifactCount += 1
    families[op.familyID]!.nodes[op.nodeID]!.path = families[op.familyID]!.nodes[op.nodeID]!.path ?? op.artifact.path
    families[op.familyID]!.nodes[op.nodeID]!.cleanupArtifacts.append(op.artifact)
    families[op.familyID]!.artifactCount += 1
    families[op.familyID]!.composition[op.artifact.category!, default: 0] = families[op.familyID]!.composition[op.artifact.category!, default: 0].addingClamped(op.artifact.allocatedBytes)
}
@inline(__always) func mutateNode(_ node: inout Node, artifact: Artifact) {
    node.allocatedBytes = node.allocatedBytes.addingClamped(artifact.allocatedBytes)
    node.artifactCount += 1
    node.path = node.path ?? artifact.path
    node.cleanupArtifacts.append(artifact)
}
@inline(__always) func mutateFamily(_ family: inout Family, op: Mutation) {
    guard family.nodes[op.nodeID] != nil else { fatalError() }
    mutateNode(&family.nodes[op.nodeID]!, artifact: op.artifact)
    family.artifactCount += 1
    family.composition[op.artifact.category!, default: 0] = family.composition[op.artifact.category!, default: 0].addingClamped(op.artifact.allocatedBytes)
}
@inline(never) func applyScoped(_ op: Mutation, to families: inout [String: Family]) {
    guard families[op.familyID] != nil else { fatalError() }
    mutateFamily(&families[op.familyID]!, op: op)
}
func checksum(_ families: [String: Family]) -> String {
    var c = Checksum()
    for fid in families.keys.sorted() {
        let f = families[fid]!; c.add(fid); c.add(UInt64(f.artifactCount))
        for category in Category.allCases { c.add(f.composition[category, default: 0]) }
        for nid in f.nodes.keys.sorted() {
            let node = f.nodes[nid]!; c.add(nid); c.add(node.allocatedBytes); c.add(UInt64(node.artifactCount)); c.add(node.path ?? "")
            for a in node.cleanupArtifacts {
                c.add(a.path); c.add(a.allocatedBytes); c.add(a.device); c.add(a.inode); c.add(UInt64(a.logicalBytes)); c.add(UInt64(a.blocks)); c.add(UInt64(a.modifiedSeconds)); c.add(UInt64(a.modifiedNanoseconds)); c.add(a.category?.rawValue ?? "")
            }
        }
    }
    return String(c.value, radix: 16)
}
func runMutation(mode: String, count: Int, skewed: Bool) {
    var (families, operations) = mutationFixture(count: count, skewed: skewed)
    let start = clock.now
    if mode == "copied" { for op in operations { applyCopied(op, to: &families) } }
    else if mode == "inplace" { for op in operations { applyInPlace(op, to: &families) } }
    else { for op in operations { applyScoped(op, to: &families) } }
    let duration = elapsed(start)
    emit(["kind":"mutation", "mode":mode, "count":count, "distribution":skewed ? "skewed_8x8_90pct_hot" : "balanced_32x4", "build_ms":duration, "checksum":checksum(families), "maxrss_bytes":maxRSS(), "artifact_stride":MemoryLayout<Artifact>.stride, "node_stride":MemoryLayout<Node>.stride, "family_stride":MemoryLayout<Family>.stride])
}
func verifyMutation(count: Int, skewed: Bool) {
    let (fixture, ops) = mutationFixture(count: count, skewed: skewed)
    var a = fixture, b = fixture, c = fixture
    for op in ops { applyCopied(op, to: &a) }
    for op in ops { applyInPlace(op, to: &b) }
    for op in ops { applyScoped(op, to: &c) }
    precondition(a == b && a == c, "Full structure mismatch")
    emit(["kind":"verify", "count":count, "skewed":skewed, "equal":a == b && a == c, "checksum":checksum(a)])
}

func ledgerMetadata() -> ([ClaimMetadata], [String]) {
    let metadata = (0..<128).map { i in
        ClaimMetadata(sourceID: "source-\(i % 24)", rootID: "source-\(i % 24).root-\(i)", rootPath: "/Volumes/Fixture/Users/person/Library/Application Support/Root-\(i)", simulatorObjectIdentifier: i % 13 == 0 ? "simulator-object-\(i)" : nil, category: "category-\(i % 8)", risk: Risk(rawValue: i % 4 + 1)!, isProtected: i % 4 == 3)
    }
    return (metadata, (0..<4).map { "fixture-volume-\($0)" })
}
func addLedgerChecksum(c: inout Checksum, identity: Identity, bytes: UInt64, logical: UInt64, date: Date, metadata: ClaimMetadata, volume: String) {
    c.add(identity.device); c.add(identity.inode); c.add(bytes); c.add(logical); c.add(date.timeIntervalSinceReferenceDate.bitPattern)
    c.add(metadata.sourceID); c.add(metadata.rootID); c.add(metadata.rootPath); c.add(metadata.simulatorObjectIdentifier ?? ""); c.add(metadata.category); c.add(UInt64(metadata.risk.rawValue)); c.add(metadata.isProtected ? 1 : 0); c.add(volume)
}
func runLedger(mode: String, count: Int) {
    let (metadata, volumes) = ledgerMetadata()
    var resultChecksum = "", capacity = 0
    let beforeRSS = maxRSS()
    var buildMS = 0.0, checksumMS = 0.0
    if mode == "rich" {
        var ledger: [Identity: RichEntry] = [:]
        let start = clock.now
        ledger.reserveCapacity(count)
        for i in 0..<count {
            let root = metadata[i % metadata.count], volume = volumes[i % volumes.count]
            let identity = Identity(device: UInt64(i % 4 + 1), inode: UInt64(i + 1))
            let bytes = UInt64(i % 64 + 1) * 4096
            let claim = RichClaim(sourceID: root.sourceID, rootID: root.rootID, rootPath: root.rootPath, simulatorObjectIdentifier: root.simulatorObjectIdentifier, category: root.category, risk: root.risk, isProtected: root.isProtected, modifiedAt: Date(timeIntervalSince1970: 1700000000 + Double(i)))
            ledger[identity] = RichEntry(identity: identity, allocatedBytes: bytes, logicalBytes: bytes - 31, volumeID: volume, claims: [claim])
        }
        buildMS = elapsed(start); capacity = ledger.capacity
        let checking = clock.now
        var c = Checksum()
        // Canonical identity order; lookup cost is measured separately from construction.
        for i in 0..<count {
            let identity = Identity(device: UInt64(i % 4 + 1), inode: UInt64(i + 1)); let entry = ledger[identity]!; precondition(entry.claims.count == 1)
            let claim = entry.claims[0]
            addLedgerChecksum(c: &c, identity: entry.identity, bytes: entry.allocatedBytes, logical: entry.logicalBytes, date: claim.modifiedAt, metadata: ClaimMetadata(sourceID: claim.sourceID, rootID: claim.rootID, rootPath: claim.rootPath, simulatorObjectIdentifier: claim.simulatorObjectIdentifier, category: claim.category, risk: claim.risk, isProtected: claim.isProtected), volume: entry.volumeID!)
        }
        checksumMS = elapsed(checking); resultChecksum = String(c.value, radix: 16)
        withExtendedLifetime(ledger) { emit(["kind":"ledger", "mode":mode, "count":count, "capacity":capacity, "build_ms":buildMS, "checksum_ms":checksumMS, "checksum":resultChecksum, "baseline_rss_bytes":beforeRSS, "maxrss_bytes":maxRSS(), "identity_stride":MemoryLayout<Identity>.stride, "entry_stride":MemoryLayout<RichEntry>.stride, "claim_stride":MemoryLayout<RichClaim>.stride]) }
    } else {
        var ledger: [Identity: CompactEntry] = [:]
        let start = clock.now
        ledger.reserveCapacity(count)
        for i in 0..<count {
            let identity = Identity(device: UInt64(i % 4 + 1), inode: UInt64(i + 1)), bytes = UInt64(i % 64 + 1) * 4096
            ledger[identity] = CompactEntry(allocatedBytes: bytes, logicalBytes: bytes - 31, modifiedAt: Date(timeIntervalSince1970: 1700000000 + Double(i)), claimID: UInt32(i % metadata.count), volumeID: UInt32(i % volumes.count))
        }
        buildMS = elapsed(start); capacity = ledger.capacity
        let checking = clock.now
        var c = Checksum()
        for i in 0..<count {
            let identity = Identity(device: UInt64(i % 4 + 1), inode: UInt64(i + 1)), entry = ledger[identity]!
            addLedgerChecksum(c: &c, identity: identity, bytes: entry.allocatedBytes, logical: entry.logicalBytes, date: entry.modifiedAt, metadata: metadata[Int(entry.claimID)], volume: volumes[Int(entry.volumeID)])
        }
        checksumMS = elapsed(checking); resultChecksum = String(c.value, radix: 16)
        withExtendedLifetime(ledger) { emit(["kind":"ledger", "mode":mode, "count":count, "capacity":capacity, "build_ms":buildMS, "checksum_ms":checksumMS, "checksum":resultChecksum, "baseline_rss_bytes":beforeRSS, "maxrss_bytes":maxRSS(), "identity_stride":MemoryLayout<Identity>.stride, "entry_stride":MemoryLayout<CompactEntry>.stride, "metadata_count":metadata.count]) }
    }
}
let args = CommandLine.arguments
func usage() -> Never {
    fputs("Usage: benchmark mutation copied|inplace|scoped COUNT balanced|skewed\n       benchmark verify both COUNT balanced|skewed\n       benchmark ledger rich|compact COUNT\n", stderr)
    exit(2)
}
guard args.count >= 4, let count = Int(args[3]), count > 0 else { usage() }
switch args[1] {
case "mutation", "verify":
    guard args.count == 5, ["balanced", "skewed"].contains(args[4]),
          (args[1] == "verify" ? args[2] == "both" : ["copied", "inplace", "scoped"].contains(args[2]))
    else { usage() }
    if args[1] == "verify" { verifyMutation(count: count, skewed: args[4] == "skewed") }
    else { runMutation(mode: args[2], count: count, skewed: args[4] == "skewed") }
case "ledger":
    guard args.count == 4, ["rich", "compact"].contains(args[2]) else { usage() }
    runLedger(mode: args[2], count: count)
default: usage()
}
