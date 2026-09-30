import Foundation
import MultipeerConnectivity

/// A fallback transport for Wi-Fi networks that block client-to-client traffic.
/// Apple's peer-to-peer link can still carry packets over Bluetooth/AWDL when the
/// router will not forward unicast UDP between two Macs.
final class MultipeerLink: NSObject {
    /// Unique per launch, so a Mac cannot discover or connect to itself.
    private let peer = MCPeerID(displayName: LocalPeer.serviceName)
    private lazy var session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    var onPacket: ((PointerPacket) -> Void)?

    func start() {
        guard advertiser == nil, browser == nil else { return }

        // The Bonjour service name is `_eltransfer._tcp`; Multipeer's API omits the
        // leading underscore. Assign the delegate before either service starts.
        session.delegate = self

        let advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: nil, serviceType: "eltransfer")
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser

        let browser = MCNearbyServiceBrowser(peer: peer, serviceType: "eltransfer")
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    func send(packet: PointerPacket) {
        guard let data = try? JSONEncoder().encode(packet), !session.connectedPeers.isEmpty else { return }
        // Reliable mode is intentional: the fallback runs at a low packet rate and
        // must not silently drop the click counter that triggers the remote click.
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }
}

extension MultipeerLink: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard peerID.displayName != LocalPeer.serviceName else { return }
        // Only one side initiates, so the same two Macs cannot invite each other twice.
        guard peerID.displayName < LocalPeer.serviceName else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("Multipeer browsing failed: \(error.localizedDescription)")
    }
}

extension MultipeerLink: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(peerID.displayName != LocalPeer.serviceName, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("Multipeer advertising failed: \(error.localizedDescription)")
    }
}

extension MultipeerLink: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        // MCSession.connectedPeers is authoritative, so no separate peer list is kept.
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let packet = try? JSONDecoder().decode(PointerPacket.self, from: data),
              packet.senderID != LocalPeer.id else { return }
        onPacket?(packet)
    }

    // Pointer packets are datagrams, so streams and resources are unused.
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: (any Error)?) {}
}
