import Foundation
import Testing
@testable import ControlModules

@MainActor struct AgentStatusTests {
    @Test func aSessionGoesThroughWorkApprovalAndDone() {
        let status = AgentStatus()
        status.record(.prompt, service: .claude, session: "a", at: 0)
        #expect(status.light(for: .claude, at: 1) == .cruise)
        status.record(.approval, service: .claude, session: "a", at: 2)
        #expect(status.light(for: .claude, at: 3) == .summon(quiet: false))
        // Looking at the app while it asks: the quiet version.
        status.setFrontmost(.claude)
        #expect(status.light(for: .claude, at: 3) == .summon(quiet: true))
        status.setFrontmost(nil)
        status.record(.resumed, service: .claude, session: "a", at: 4)
        #expect(status.light(for: .claude, at: 5) == .cruise)
        status.record(.done, service: .claude, session: "a", at: 10)
        #expect(status.light(for: .claude, at: 10.5) == .close(since: 10))
        #expect(status.light(for: .claude, at: 60) == .hold)
        // A duplicate end from the session log changes nothing.
        status.record(.done, service: .claude, session: "a", at: 11)
        #expect(status.light(for: .claude, at: 60) == .hold)
        // Looking at it clears the reminder.
        status.setFrontmost(.claude)
        #expect(status.light(for: .claude, at: 61) == .idle)
        #expect(status.isIdle(at: 61))
    }

    @Test func finishingWhileYouLookLeavesNoReminder() {
        let status = AgentStatus()
        status.setFrontmost(.codex)
        status.record(.prompt, service: .codex, session: "x", at: 0)
        status.record(.done, service: .codex, session: "x", at: 5)
        #expect(status.light(for: .codex, at: 5.5) == .close(since: 5))
        #expect(status.light(for: .codex, at: 30) == .idle)
        status.prune(at: 30)
        #expect(status.sessions.isEmpty)
    }

    @Test func failuresInterruptsAndQuitting() {
        let status = AgentStatus()
        status.record(.prompt, service: .codex, session: "x", at: 0)
        status.record(.failed, service: .codex, session: "x", at: 1)
        #expect(status.light(for: .codex, at: 1.2) == .fail(since: 1))
        #expect(status.light(for: .codex, at: 20) == .fault)
        // Stopping it yourself: straight back to idle.
        status.record(.prompt, service: .claude, session: "a", at: 2)
        status.record(.interrupted, service: .claude, session: "a", at: 3)
        #expect(status.light(for: .claude, at: 4) == .idle)
        // An app that quits takes its sessions with it.
        status.record(.prompt, service: .claude, session: "b", at: 5)
        status.appQuit(.claude)
        #expect(status.light(for: .claude, at: 6) == .idle)
        // A long quiet task stays working: no timeout.
        status.record(.prompt, service: .claude, session: "c", at: 7)
        #expect(status.light(for: .claude, at: 7 + 3600) == .cruise)
    }

    @Test func anIdleNoticeEndsUnfinishedWorkButNotReminders() {
        let status = AgentStatus()
        // Interrupted: no stop came, so it still shows working until Claude says it is idle.
        status.record(.prompt, service: .claude, session: "a", at: 0)
        status.record(.idle, service: .claude, session: "a", at: 60)
        #expect(status.light(for: .claude, at: 61) == .idle)
        // Finished normally: the idle notice that follows leaves the reminder alone.
        status.record(.prompt, service: .claude, session: "b", at: 100)
        status.record(.done, service: .claude, session: "b", at: 110)
        status.record(.idle, service: .claude, session: "b", at: 170)
        #expect(status.light(for: .claude, at: 171) == .hold)
        // A declined request: Claude says nothing until it is idle; that ends the summon.
        status.record(.approval, service: .claude, session: "c", at: 200)
        status.record(.idle, service: .claude, session: "c", at: 260)
        #expect(status.light(for: .claude, at: 261) == .hold)  // b's reminder is all that is left
    }

    @Test func consoleStopEndsClaudesLatestTurn() {
        let status = AgentStatus()
        status.record(.prompt, service: .claude, session: "old", at: 0)
        status.record(.approval, service: .claude, session: "front", at: 10)
        #expect(status.latestActiveSession(of: .claude) == "front")
        status.record(.interrupted, service: .claude, session: "front", at: 11)
        #expect(status.light(for: .claude, at: 12) == .cruise)  // the older session still works
    }

    @Test func theMostUrgentSessionSpeaksForTheApp() {
        let status = AgentStatus()
        status.record(.prompt, service: .claude, session: "a", at: 0)
        status.record(.done, service: .claude, session: "b", at: 0)
        status.record(.approval, service: .claude, session: "c", at: 0)
        #expect(status.light(for: .claude, at: 30) == .summon(quiet: false))
        status.record(.resumed, service: .claude, session: "c", at: 31)
        #expect(status.light(for: .claude, at: 32) == .hold)
        #expect(AgentStatus.Light.summon(quiet: true).tier > AgentStatus.Light.fail(since: 0).tier)
        #expect(AgentStatus.Light.hold.tier == AgentStatus.Light.fault.tier)
    }
}

@MainActor struct AgentSourcesTests {
    @Test func hookEventsMapOntoTheStrip() {
        #expect(AgentMonitor.event(for: "UserPromptSubmit", kind: nil, service: .claude) == .prompt)
        #expect(AgentMonitor.event(for: "PermissionRequest", kind: nil, service: .codex) == .approval)
        #expect(AgentMonitor.event(for: "Notification", kind: "permission_prompt", service: .claude) == .approval)
        #expect(AgentMonitor.event(for: "PostToolUse", kind: nil, service: .claude) == .resumed)
        #expect(AgentMonitor.event(for: "Stop", kind: nil, service: .codex) == .done)
        #expect(AgentMonitor.event(for: "StopFailure", kind: nil, service: .claude) == .failed)
        #expect(AgentMonitor.event(for: "Interrupt", kind: nil, service: .codex) == .interrupted)
        #expect(AgentMonitor.event(for: "SessionEnd", kind: nil, service: .claude) == .ended)
        #expect(AgentMonitor.event(for: "PreCompact", kind: nil, service: .claude) == nil)
        // A tool call asking for permissions (Codex's network access) waits on you; others don't.
        #expect(AgentMonitor.event(for: "PreToolUse", kind: nil, tool: "request_permissions", service: .codex) == .approval)
        #expect(AgentMonitor.event(for: "PreToolUse", kind: nil, tool: "Bash", service: .codex) == nil)
        #expect(AgentMonitor.event(for: "Notification", kind: "idle_prompt", service: .claude) == .idle)
    }
}
