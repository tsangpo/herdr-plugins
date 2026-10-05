import Foundation
import Testing
@testable import ImeKeeper

@Test func directForegroundEditorDoesNotRequireAParentLookup() {
    let processes = [ForegroundProcess(name: "nvim", argv0: nil, pid: 123)]
    #expect(editorIsForeground(pid: 123, processes: processes, identity: { _ in nil }))
}

@Test func embeddedNeovimCoreMatchesItsForegroundTUIParent() {
    let processes = [ForegroundProcess(name: nil, argv0: "/opt/homebrew/bin/nvim", pid: 123)]
    let matched = editorIsForeground(pid: 124, processes: processes, identity: { pid in
        #expect(pid == 124)
        return LocalProcessIdentity(parentPID: 123, executableName: "nvim")
    })
    #expect(matched)
}

@Test func unrelatedBackgroundOrNonNeovimProcessesDoNotMatch() {
    let processes = [ForegroundProcess(name: "nvim", argv0: nil, pid: 123)]
    #expect(!editorIsForeground(pid: 124, processes: processes, identity: { _ in
        LocalProcessIdentity(parentPID: 999, executableName: "nvim")
    }))
    #expect(!editorIsForeground(pid: 124, processes: processes, identity: { _ in
        LocalProcessIdentity(parentPID: 123, executableName: "sh")
    }))
    #expect(!editorIsForeground(pid: 124, processes: [ForegroundProcess(name: "zsh", argv0: nil, pid: 123)], identity: { _ in
        LocalProcessIdentity(parentPID: 123, executableName: "nvim")
    }))
    #expect(!editorIsForeground(pid: 124, processes: processes, identity: { _ in nil }))
    #expect(!editorIsForeground(pid: 124, processes: [], identity: { _ in
        LocalProcessIdentity(parentPID: 123, executableName: "nvim")
    }))
}

@Test func processIdentityReadsCurrentProcessFromKernel() {
    let identity = localProcessIdentity(pid: ProcessInfo.processInfo.processIdentifier)
    #expect(identity != nil)
    #expect((identity?.parentPID ?? 0) > 0)
    #expect(identity?.executableName.isEmpty == false)
    #expect(localProcessIdentity(pid: -1) == nil)
}
