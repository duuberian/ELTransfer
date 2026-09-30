import Foundation
import MultipeerConnectivity

/// A transport fallback for Wi-Fi networks that block client-to-client traffic.
/// Apple's peer-to-peer link can still carry packets over Bluetooth/AWDL when the
/// router will not forward unicast UDP between two Macs.
final class MultipeerLink: NSObject {
    /// Kept separate from the UDP service name so one Mac never connects to itself.
    private let peer = MCPeerID(displayName: LocalPeer.serviceName)
    private lazy var session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var connected: Set<MCPeerID> = []
    var onPacket: ((PointerPacket) -> Void)?

    func start() {
        guard advertiser == nil, browser == nil else { return }

        // The actual Bonjour service type is `_eltransfer._tcp`; Multipeer omits the
        // leading underscore in its API.
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
        guard let data = try? JSONEncoder().encode(packet), !connected.isEmpty else { return }
        // Unreliable mode keeps pointer updates moving without building a backlog.
        try? session.send(data, toPeers: Array(connected), with: .unreliable)
    }
}

extension MultipeerLink: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard peerID.displayName != LocalPeer.serviceName else { return }
        // Only one side initiates, so the same two Macs cannot invite each other twice.
        guard peerID.displayName < LocalPeer.serviceName else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        connected.remove(peerID)
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("Multipeer browsing failed: \(error.localizedDescription)")
    }
}

extension MultipeerLink: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // The sender and receiver on the same Mac share one transport, but a peer
        // should never be its own display name.
        invitationHandler(peerID.displayName != LocalPeer.serviceName, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("Multipeer advertising failed: \(error.localizedDescription)")
    }
}

extension MultipeerLink: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch state {
            case .connected:
                connected.insert(peerID)
            case .notConnected, .connecting:
                connected.remove(peerID)
            @unknown default:
                break
            }
        }
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
