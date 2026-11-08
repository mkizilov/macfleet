import Foundation
import Testing
@testable import MacFleetKit

private func setPermissions(_ mode: Int, at path: String) throws {
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
}

private func mode(of path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

@Suite("Protected files")
struct ProtectedFileTests {
    @Test func aWrittenFileIsOwnerOnlyAndReadsBack() throws {
        let directory = try HeadlessScratch.make()
        defer { HeadlessScratch.remove(directory) }
        let path = directory.appendingPathComponent("secret.bin").path
        try ProtectedFile.write(Data("value".utf8), to: path)
        #expect(try mode(of: path) == 0o600)
        #expect(try ProtectedFile.read(path) == Data("value".utf8))
    }

    @Test func aFileAnyoneElseCanReadIsRefused() throws {
        let directory = try HeadlessScratch.make()
        defer { HeadlessScratch.remove(directory) }
        let path = directory.appendingPathComponent("open.bin").path
        try ProtectedFile.write(Data("value".utf8), to: path)
        try setPermissions(0o644, at: path)
        #expect(throws: AgentSecretError.accessibleToOthers(path: path, mode: 0o644)) {
            try ProtectedFile.read(path)
        }
        #expect(throws: AgentSecretError.self) {
            try ProtectedFile.requireOwnerOnly(path)
        }
    }

    @Test func aGroupReadableFileIsRefusedToo() throws {
        let directory = try HeadlessScratch.make()
        defer { HeadlessScratch.remove(directory) }
        let path = directory.appendingPathComponent("group.bin").path
        try ProtectedFile.write(Data("value".utf8), to: path)
        try setPermissions(0o640, at: path)
        #expect(throws: AgentSecretError.self) {
            try ProtectedFile.read(path)
        }
        try setPermissions(0o600, at: path)
        #expect(try ProtectedFile.read(path) == Data("value".utf8))
    }

    @Test func aWriteReplacesTheFileWithoutLeavingTemporaryFiles() throws {
        let directory = try HeadlessScratch.make()
        defer { HeadlessScratch.remove(directory) }
        let path = directory.appendingPathComponent("replace.bin").path
        try ProtectedFile.write(Data("first".utf8), to: path)
        try ProtectedFile.write(Data("second".utf8), to: path)
        #expect(try ProtectedFile.read(path) == Data("second".utf8))
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(entries == ["replace.bin"])
    }

    @Test func aSymbolicLinkIsRefusedEvenWhenItsTargetIsOwnerOnly() throws {
        let directory = try HeadlessScratch.make()
        defer { HeadlessScratch.remove(directory) }
        let target = directory.appendingPathComponent("target.bin").path
        let link = directory.appendingPathComponent("link.bin").path
        try ProtectedFile.write(Data("value".utf8), to: target)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        #expect(throws: AgentSecretError.self) {
            try ProtectedFile.read(link)
        }
        #expect(try ProtectedFile.read(target) == Data("value".utf8))
    }

    @Test func aMissingFileIsAnUnreadableError() throws {
        let directory = try HeadlessScratch.make()
        defer { HeadlessScratch.remove(directory) }
        #expect(throws: AgentSecretError.self) {
            try ProtectedFile.read(directory.appendingPathComponent("absent").path)
        }
    }
}

@Suite("Secret stores")
struct SecretStoreTests {
    @Test func aFileStoreKeepsEachSecretUnderItsAccount() throws {
        let directory = try HeadlessScratch.make()
        defer { HeadlessScratch.remove(directory) }
        let store = ProtectedFileSecretStore(path: directory.appendingPathComponent("secrets.json").path)
        #expect(try store.secret(for: AgentSecretAccount.client("laptop-1")) == nil)

        try store.setSecret(Data([1, 2, 3]), for: AgentSecretAccount.client("laptop-1"))
        try store.setSecret(Data([4, 5]), for: AgentSecretAccount.identityPassphrase)
        #expect(try store.secret(for: AgentSecretAccount.client("laptop-1")) == Data([1, 2, 3]))
        #expect(try store.secret(for: AgentSecretAccount.identityPassphrase) == Data([4, 5]))

        try store.removeSecret(for: AgentSecretAccount.client("laptop-1"))
        #expect(try store.secret(for: AgentSecretAccount.client("laptop-1")) == nil)
        #expect(try store.secret(for: AgentSecretAccount.identityPassphrase) == Data([4, 5]))
    }

    @Test func aFileStoreThatAnyoneCanReadIsNotUsed() throws {
        let directory = try HeadlessScratch.make()
        defer { HeadlessScratch.remove(directory) }
        let path = directory.appendingPathComponent("secrets.json").path
        let store = ProtectedFileSecretStore(path: path)
        try store.setSecret(Data([9]), for: "account")
        try setPermissions(0o644, at: path)
        #expect(throws: AgentSecretError.self) {
            try store.secret(for: "account")
        }
    }

    @Test func aDamagedFileStoreIsReportedNotTreatedAsEmpty() throws {
        let directory = try HeadlessScratch.make()
        defer { HeadlessScratch.remove(directory) }
        let path = directory.appendingPathComponent("secrets.json").path
        try ProtectedFile.write(Data("not json".utf8), to: path)
        #expect(throws: AgentSecretError.corruptStore(path: path)) {
            try ProtectedFileSecretStore(path: path).secret(for: "account")
        }
    }

    @Test func theMemoryStoreRoundTrips() throws {
        let store = MemoryAgentSecretStore()
        try store.setSecret(Data([7]), for: "account")
        #expect(try store.secret(for: "account") == Data([7]))
        try store.removeSecret(for: "account")
        #expect(try store.secret(for: "account") == nil)
    }
}
