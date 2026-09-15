import Foundation
import WebKit
import StripeTerminal

/// Stripe Terminal adapter for the POS WebView shell.
/// It receives only a PaymentIntent client secret and a scoped Terminal
/// location; platform secrets and wallet signing material never enter native.
final class StripeTerminalPosBridge: NSObject, ConnectionTokenProvider, DiscoveryDelegate, TapToPayReaderDelegate, MobileReaderDelegate {
    private static let sharedBridge = StripeTerminalPosBridge(webView: nil)

    static func initializeAtLaunch() {
        Terminal.setTokenProvider(sharedBridge)
    }

    static func shared() -> StripeTerminalPosBridge {
        sharedBridge
    }

    private weak var webView: WKWebView?
    private var requestId = ""
    private var paymentIntentId = ""
    private var cardAddress = ""
    private var locationId = ""
    private var clientSecret = ""
    private var buyerEoa = ""
    private var amountFiat6 = ""
    private var currency = ""
    private var kind = "topup"
    private var businessIdempotencyKey = ""
    private var posAdmin = ""
    private var authorizationSignature = ""
    private var authorizationDeadline = 0
    private var authorizationNonce = ""
    private var readerMode = "auto"

    init(webView: WKWebView?) {
        self.webView = webView
        super.init()
    }

    func attach(webView: WKWebView) {
        self.webView = webView
    }

    func start(_ body: [String: Any]) {
        requestId = body["requestId"] as? String ?? ""
        paymentIntentId = body["paymentIntentId"] as? String ?? ""
        cardAddress = body["cardAddress"] as? String ?? ""
        locationId = body["locationId"] as? String ?? ""
        clientSecret = body["clientSecret"] as? String ?? ""
        buyerEoa = body["buyerEoa"] as? String ?? ""
        amountFiat6 = body["amountFiat6"] as? String ?? ""
        currency = body["currency"] as? String ?? ""
        kind = body["kind"] as? String ?? "topup"
        businessIdempotencyKey = body["businessIdempotencyKey"] as? String ?? ""
        posAdmin = body["posAdmin"] as? String ?? ""
        authorizationSignature = body["authorizationSignature"] as? String ?? ""
        if let deadline = body["authorizationDeadline"] as? NSNumber {
            authorizationDeadline = deadline.intValue
        } else if let deadline = body["authorizationDeadline"] as? String {
            authorizationDeadline = Int(deadline) ?? 0
        } else {
            authorizationDeadline = 0
        }
        authorizationNonce = body["authorizationNonce"] as? String ?? ""
        guard !requestId.isEmpty, !clientSecret.isEmpty, !locationId.isEmpty,
              !buyerEoa.isEmpty, !amountFiat6.isEmpty, !currency.isEmpty,
              !businessIdempotencyKey.isEmpty,
              !posAdmin.isEmpty, !authorizationSignature.isEmpty,
              authorizationDeadline > 0, !authorizationNonce.isEmpty else {
            fail(code: "invalid_request", message: "Stripe Terminal payment request is incomplete.")
            return
        }
        readerMode = body["readerMode"] as? String ?? "auto"
        if readerMode == "external_reader" {
            discoverExternalReader()
        } else {
            discoverTapToPay()
        }
    }

    func cancel() {
        fail(code: "cancelled", message: "Physical card payment was cancelled.")
    }

    // MARK: SCPConnectionTokenProvider

    func fetchConnectionToken(_ completion: @escaping ConnectionTokenCompletionBlock) {
        var request = URLRequest(url: URL(string: "https://beamio.app/api/merchantCardStripe/connectionToken")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "cardAddress": cardAddress,
            "buyerEoa": buyerEoa,
            "amountFiat6": amountFiat6,
            "currency": currency,
            "kind": kind,
            "businessIdempotencyKey": businessIdempotencyKey,
            "posAdmin": posAdmin,
            "authorizationSignature": authorizationSignature,
            "authorizationDeadline": authorizationDeadline,
            "authorizationNonce": authorizationNonce,
        ])
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(nil, error)
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let secret = json["secret"] as? String,
                  (response as? HTTPURLResponse)?.statusCode ?? 500 < 300
            else {
                completion(nil, NSError(domain: "BeamioStripeTerminal", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Connection token request failed.",
                ]))
                return
            }
            completion(secret, nil)
        }.resume()
    }

    // MARK: Discovery / connection

    private func discoverTapToPay() {
        do {
            let configuration = try TapToPayDiscoveryConfigurationBuilder().build()
            Terminal.shared.discoverReaders(configuration, delegate: self) { [weak self] error in
                if let error {
                    self?.fail(code: "reader_unavailable", message: error.localizedDescription)
                }
            }
        } catch {
            fail(code: "reader_unavailable", message: error.localizedDescription)
        }
    }

    private func discoverExternalReader() {
        do {
            let configuration = try BluetoothScanDiscoveryConfigurationBuilder().build()
            Terminal.shared.discoverReaders(configuration, delegate: self) { [weak self] error in
                if let error {
                    self?.fail(code: "reader_unavailable", message: error.localizedDescription)
                }
            }
        } catch {
            fail(code: "reader_unavailable", message: error.localizedDescription)
        }
    }

    func terminal(_ terminal: Terminal, didUpdateDiscoveredReaders readers: [Reader]) {
        guard let reader = readers.first else { return }
        do {
            let configuration: ConnectionConfiguration
            if readerMode == "external_reader" {
                configuration = try BluetoothConnectionConfigurationBuilder(delegate: self, locationId: locationId).build()
            } else {
                configuration = try TapToPayConnectionConfigurationBuilder(delegate: self, locationId: locationId).build()
            }
            Terminal.shared.connectReader(reader, connectionConfig: configuration) { [weak self] _, error in
                if let error {
                    self?.fail(code: "reader_unavailable", message: error.localizedDescription)
                } else {
                    self?.processPayment()
                }
            }
        } catch {
            fail(code: "reader_unavailable", message: error.localizedDescription)
        }
    }

    private func processPayment() {
        Terminal.shared.retrievePaymentIntent(clientSecret: clientSecret) { [weak self] intent, error in
            if let error {
                self?.fail(code: "payment_intent_unavailable", message: error.localizedDescription)
                return
            }
            guard let intent else {
                self?.fail(code: "payment_intent_unavailable", message: "Stripe PaymentIntent was unavailable.")
                return
            }
            Terminal.shared.collectPaymentMethod(intent) { [weak self] collected, error in
                if let error {
                    self?.fail(code: "payment_failed", message: error.localizedDescription)
                    return
                }
                guard let collected else {
                    self?.fail(code: "payment_failed", message: "Stripe did not collect a payment method.")
                    return
                }
                Terminal.shared.confirmPaymentIntent(collected) { result, confirmError in
                    if let confirmError {
                        self?.fail(code: "payment_failed", message: confirmError.localizedDescription)
                    } else {
                        self?.succeed(status: result.map { String($0.status.rawValue) } ?? "succeeded")
                    }
                }
            }
        }
    }

    // MARK: Reader delegates

    func tapToPayReader(_ reader: Reader, didRequestReaderInput inputOptions: ReaderInputOptions) {}
    func tapToPayReader(_ reader: Reader, didRequestReaderDisplayMessage displayMessage: ReaderDisplayMessage) {}
    func tapToPayReader(_ reader: Reader, didStartInstallingUpdate update: ReaderSoftwareUpdate, cancelable: Cancelable?) {}
    func tapToPayReader(_ reader: Reader, didReportReaderSoftwareUpdateProgress progress: Float) {}
    func tapToPayReader(_ reader: Reader, didFinishInstallingUpdate update: ReaderSoftwareUpdate?, error: Error?) {}
    func reader(_ reader: Reader, didRequestReaderInput inputOptions: ReaderInputOptions) {}
    func reader(_ reader: Reader, didRequestReaderDisplayMessage displayMessage: ReaderDisplayMessage) {}
    func reader(_ reader: Reader, didStartInstallingUpdate update: ReaderSoftwareUpdate, cancelable: Cancelable?) {}
    func reader(_ reader: Reader, didReportReaderSoftwareUpdateProgress progress: Float) {}
    func reader(_ reader: Reader, didReportAvailableUpdate update: ReaderSoftwareUpdate) {}
    func reader(_ reader: Reader, didFinishInstallingUpdate update: ReaderSoftwareUpdate?, error: Error?) {}

    private func succeed(status: String) {
        emit([
            "action": "stripePhysicalPaymentResult",
            "requestId": requestId,
            "paymentIntentId": paymentIntentId,
            "paymentStatus": status,
            "ok": true,
        ])
    }

    private func fail(code: String, message: String) {
        emit([
            "action": "stripePhysicalPaymentResult",
            "requestId": requestId,
            "paymentIntentId": paymentIntentId,
            "errorCode": code,
            "error": message,
            "ok": false,
        ])
    }

    private func emit(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return }
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(
                "window.dispatchEvent(new CustomEvent('cashtreesios',{detail:\(json)}));",
                completionHandler: nil,
            )
        }
    }
}
