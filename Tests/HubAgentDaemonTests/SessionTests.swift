import Foundation
import HubAgentShared
import Testing

@testable import HubAgentDaemon

@Suite struct SessionLifecycle {
    @Test func startsAShellInTheWorkingDirectory() throws {
        let harness = DaemonHarness()
        let (sessionId, client) = try #require(harness.createAttachedSession())
        harness.type("basename \"$(pwd)\"\n", into: sessionId, as: client)
        let folder = (harness.directory as NSString).lastPathComponent
        #expect(harness.eventually { client.text.contains("\n" + folder) })
        let listed = harness.sync { harness.manager.listSessions() }
        #expect(listed.map(\.id) == [sessionId])
        #expect(listed.first?.state == .running)
        #expect((listed.first?.processId ?? 0) > 0)
    }

    @Test func refusesAMissingWorkingDirectory() {
        let harness = DaemonHarness()
        let request = CreateSessionRequest(
            requestId: 9, workingDirectory: harness.directory + "/missing", size: DaemonHarness.size)
        let result = harness.sync { harness.manager.createSession(request) }
        #expect(throws: FailureReply.self) { try result.get() }
        if case .failure(let failure) = result {
            #expect(failure.code == .workingDirectoryNotFound)
            #expect(failure.requestId == 9)
        }
        #expect(harness.sync { harness.manager.listSessions() }.isEmpty)
    }

    @Test func refusesAnInvalidSize() {
        let harness = DaemonHarness()
        let request = CreateSessionRequest(
            requestId: 1, workingDirectory: harness.directory, size: TerminalSize(columns: 0, rows: 24))
        let result = harness.sync { harness.manager.createSession(request) }
        if case .failure(let failure) = result {
            #expect(failure.code == .invalidSize)
        } else {
            Issue.record("created")
        }
    }

    @Test func keepsTheLabelItWasGiven() throws {
        let harness = DaemonHarness()
        let label = ["projectId": "p1", "tabId": "t1", "title": "Terminal 1"]
        let session = try #require(harness.createSession(label: label))
        #expect(session.label == label)
        #expect(harness.sync { harness.manager.listSessions() }.first?.label == label)
    }

    @Test func reportsTheExitCodeAndKeepsTheSessionUntilAcknowledged() throws {
        let harness = DaemonHarness()
        let (sessionId, client) = try #require(harness.createAttachedSession())
        harness.type("exit 3\n", into: sessionId, as: client)
        #expect(harness.eventually { client.exitCodes == [3] })

        let listed = harness.sync { harness.manager.listSessions() }
        #expect(listed.first?.state == .exited)
        #expect(listed.first?.exitCode == 3)

        let later = harness.attach(sessionId)
        #expect(harness.sync { later.exitCodes } == [3])

        harness.sync { harness.manager.acknowledgeExit(sessionId: sessionId) }
        #expect(harness.sync { harness.manager.listSessions() }.isEmpty)
    }

    @Test func terminatesAnOrdinaryShell() throws {
        let harness = DaemonHarness()
        let (sessionId, client) = try #require(harness.createAttachedSession())
        harness.sync { _ = harness.manager.terminate(sessionId: sessionId) }
        #expect(harness.eventually { client.exitCodes.count == 1 })
    }

    @Test func killsAShellThatIgnoresTheHangup() throws {
        var configuration = SessionConfiguration()
        configuration.forceKillDelay = 0.3
        let harness = DaemonHarness(configuration: configuration)
        let (sessionId, client) = try #require(harness.createAttachedSession())
        harness.type("trap '' HUP; echo armed\n", into: sessionId, as: client)
        #expect(harness.eventually { client.text.contains("armed") })
        harness.sync { _ = harness.manager.terminate(sessionId: sessionId) }
        #expect(harness.eventually { client.exitCodes == [nil] })
    }

    @Test func reportsUnknownSessions() {
        let harness = DaemonHarness()
        let unknown = UUID()
        let client = RecordingClient()
        let failure = harness.sync {
            harness.manager.attach(sessionId: unknown, size: DaemonHarness.size, client: client)
        }
        #expect(failure?.code == .sessionNotFound)
        #expect(harness.sync { harness.manager.terminate(sessionId: unknown) }?.code == .sessionNotFound)
    }
}

@Suite struct SessionAttachment {
    @Test func restoresTheScreenForAClientThatAttachesLater() throws {
        let harness = DaemonHarness()
        let (sessionId, first) = try #require(harness.createAttachedSession())
        harness.type("printf '\\033[32mgreen\\033[0m\\n'; seq 1 60\n", into: sessionId, as: first)
        #expect(harness.eventually { first.text.contains("60") })

        let second = harness.attach(sessionId)
        #expect(harness.eventually { second.dump?.differences(from: harness.daemonDump()) == [] })
        #expect(harness.sync { second.dump?.historyLines ?? 0 } > 30)
    }

    @Test func keepsReadingWhileNoClientIsAttached() throws {
        let harness = DaemonHarness()
        let (sessionId, first) = try #require(harness.createAttachedSession())
        harness.type("sleep 0.4; echo produced-while-detached\n", into: sessionId, as: first)
        harness.sync { harness.manager.disconnect(first) }
        #expect(harness.eventually { harness.daemonDump().visibleText.contains("\nproduced-while-detached") })

        let second = harness.attach(sessionId)
        #expect(harness.sync { second.text }.contains("\nproduced-while-detached"))
        #expect(harness.sync { first.text }.contains("\nproduced-while-detached") == false)
    }

    @Test func aSecondClientTakesTheSessionOver() throws {
        let harness = DaemonHarness()
        let (sessionId, first) = try #require(harness.createAttachedSession())
        let second = harness.attach(sessionId)
        #expect(harness.sync { first.detachReasons } == [.takenOver])

        harness.type("echo from-first\n", into: sessionId, as: first)
        harness.type("echo from-second\n", into: sessionId, as: second)
        #expect(harness.eventually { second.text.contains("\nfrom-second") })
        #expect(harness.sync { second.text }.contains("from-first") == false)
    }

    @Test func detachStopsTheOutput() throws {
        let harness = DaemonHarness()
        let (sessionId, client) = try #require(harness.createAttachedSession())
        harness.sync { harness.manager.detach(sessionId: sessionId, client: client) }
        #expect(harness.sync { client.detachReasons } == [.requested])
        let before = harness.sync { client.messages.count }
        harness.sync {
            harness.manager.write(sessionId: sessionId, bytes: Array("echo ignored\n".utf8), client: client)
        }
        Thread.sleep(forTimeInterval: 0.3)
        #expect(harness.sync { client.messages.count } == before)
    }

    @Test func answersProgramQueriesWithNoClientAttached() throws {
        let harness = DaemonHarness()
        let (sessionId, client) = try #require(harness.createAttachedSession())
        let query = "sleep 0.4; printf '\\033[6n'; IFS= read -rs -t 3 -d R reply; echo \"cursor=${reply#*[}.\"\n"
        harness.type(query, into: sessionId, as: client)
        harness.sync { harness.manager.disconnect(client) }
        #expect(harness.eventually { harness.daemonDump().visibleText.contains("\ncursor=") })
        let answer = harness.daemonDump().visibleText
        #expect(answer.contains("\ncursor=.") == false, "the program got no reply")
        #expect(answer.range(of: #"\ncursor=\d+;\d+\."#, options: .regularExpression) != nil)
    }
}

@Suite struct SessionResizing {
    @Test func resizesTheTerminal() throws {
        let harness = DaemonHarness()
        let (sessionId, client) = try #require(harness.createAttachedSession())
        let wide = TerminalSize(columns: 132, rows: 43)
        harness.sync {
            client.resizeEmulator(wide)
            _ = harness.manager.resize(sessionId: sessionId, size: wide, client: client)
        }
        harness.type("stty size\n", into: sessionId, as: client)
        #expect(harness.eventually { client.text.contains("\n43 132") })
        #expect(harness.sync { harness.manager.listSessions() }.first?.columns == 132)
    }

    @Test func sendsAFreshScreenAfterAResizeSoBothSidesAgree() throws {
        var configuration = SessionConfiguration()
        configuration.resizeRefreshDelay = 0.2
        let harness = DaemonHarness(configuration: configuration)
        let (sessionId, client) = try #require(harness.createAttachedSession())
        let long = String(repeating: "wrap me ", count: 12)
        harness.type(
            "i=0; while [ $i -lt 400 ]; do echo \"$i \(long)\"; i=$((i+1)); done; echo finished\n", into: sessionId,
            as: client)

        // Resize while output is flowing: the two emulators lay it out differently.
        let narrow = TerminalSize(columns: 50, rows: 15)
        harness.sync {
            client.resizeEmulator(narrow)
            _ = harness.manager.resize(sessionId: sessionId, size: narrow, client: client)
        }
        #expect(harness.eventually { client.screenCount >= 2 }, "no fresh screen after the resize")
        #expect(harness.eventually { harness.daemonDump().visibleText.contains("\nfinished") })
        #expect(harness.eventually { client.dump?.differences(from: harness.daemonDump()) == [] })
    }

    @Test func refusesAnInvalidSize() throws {
        let harness = DaemonHarness()
        let (sessionId, client) = try #require(harness.createAttachedSession())
        let failure = harness.sync {
            harness.manager.resize(sessionId: sessionId, size: TerminalSize(columns: 5000, rows: 24), client: client)
        }
        #expect(failure?.code == .invalidSize)
    }

    @Test func boundsTheHistory() throws {
        var configuration = SessionConfiguration()
        configuration.historyLines = 50
        let harness = DaemonHarness(configuration: configuration)
        let (sessionId, client) = try #require(harness.createAttachedSession(historyLines: 50))
        harness.type("seq 1 500\n", into: sessionId, as: client)
        #expect(harness.eventually { harness.daemonDump().visibleText.contains("\n500") })
        #expect(harness.daemonDump().historyLines == 50)
    }
}

@Suite struct ShellLaunching {
    @Test func buildsALoginShellWithItsOwnEnvironment() {
        let launcher = LoginShellLauncher(daemonEnvironment: ["TMPDIR": "/tmp/x/", "SECRET_TOKEN": "nope"])
        let launch = launcher.launch(workingDirectory: "/tmp")
        #expect(launch.processName?.hasPrefix("-") == true)
        #expect(launch.executable.hasPrefix("/"))
        #expect(launch.workingDirectory == "/tmp")
        #expect(launch.environment.contains("TERM=xterm-256color"))
        #expect(launch.environment.contains("TMPDIR=/tmp/x/"))
        #expect(launch.environment.contains { $0.hasPrefix("HOME=/") })
        #expect(launch.environment.contains { $0.hasPrefix("SECRET_TOKEN") } == false)
    }
}
