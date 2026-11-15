//
//  BeamioHostPolicyTests.swift
//  CashTrees_iOSTests
//

import Testing
@testable import softPOS

struct BeamioHostPolicyTests {
    private let legacyAndConsumerPaths = ["/", "/app", "/app/", "/app/?beamiocard=x", "/app-download", "/api/sun", "/sun", "/pos-foo"]

    @Test func consumerPagesAreCancelledOnOldAndNewHosts() {
        for host in BeamioHostPolicy.consumerHosts {
            for path in ["/", "/app", "/app/", "/app-download", "/api/sun"] {
                #expect(BeamioHostPolicy.decide(host: host, path: path) == .cancel, "\(host)\(path)")
            }
        }
    }

    @Test func posPathsOnConsumerHostsAreMappedLocally() {
        for host in BeamioHostPolicy.consumerHosts {
            #expect(BeamioHostPolicy.decide(host: host, path: "/pos") == .mapLocal)
            #expect(BeamioHostPolicy.decide(host: host, path: "/pos/") == .mapLocal)
            #expect(BeamioHostPolicy.decide(host: host, path: "/pos/home") == .mapLocal)
        }
    }

    @Test func legacyPosHostIsMappedLocallyAndUnmappedPathsAreCancelled() {
        #expect(BeamioHostPolicy.decide(host: "pos.beamio.app", path: "/") == .mapLocal)
        #expect(BeamioHostPolicy.decide(host: "pos.beamio.app", path: "/home") == .mapLocal)
        #expect(BeamioHostPolicy.decide(host: "pos.beamio.app", path: "/api/getOracle") == .cancel)
        #expect(BeamioHostPolicy.decide(host: "pos.beamio.app", path: "/og/x") == .cancel)
    }

    @Test func newPosHostIsMappedLocally() {
        #expect(BeamioHostPolicy.decide(host: "pos.beamio.ca", path: "/") == .mapLocal)
        #expect(BeamioHostPolicy.decide(host: "pos.beamio.ca", path: "/api/getOracle") == .pass)
    }

    @Test func oldDomainNeverBecomesARemoteTarget() {
        for host in BeamioHostPolicy.legacyHosts.union(BeamioHostPolicy.consumerHosts) {
            for path in legacyAndConsumerPaths {
                let decision = BeamioHostPolicy.decide(host: host, path: path)
                if let target = BeamioHostPolicy.remoteHost(for: decision, host: host) {
                    #expect(!BeamioHostPolicy.legacyHosts.contains(target), "\(host)\(path) must not become a remote target")
                }
            }
        }
    }

    @Test func unrelatedHostsPassThroughUnchanged() {
        #expect(BeamioHostPolicy.decide(host: "example.com", path: "/") == .pass)
        #expect(BeamioHostPolicy.remoteHost(for: .pass, host: "example.com") == "example.com")
        #expect(BeamioHostPolicy.remoteHost(for: .cancel, host: "beamio.app") == nil)
        #expect(BeamioHostPolicy.remoteHost(for: .mapLocal, host: "beamio.ca") == nil)
    }
}
