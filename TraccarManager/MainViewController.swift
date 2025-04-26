//
// Copyright 2016 - 2022 Anton Tananaev (anton@traccar.org)
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import UIKit
import WebKit

class MainViewController: UIViewController, WKUIDelegate {

    static let eventLogin = Notification.Name("eventLogin")
    static let eventToken = Notification.Name("eventToken")
    static let eventEvent = Notification.Name("eventEvent")
    static let keyToken = "keyToken"
    static let keyEventId = "keyEventId"

    var webView: WKWebView!
    var initialized = false
    var pendingEventId: String? = nil
    var loadingSpinner: UIActivityIndicatorView?

    override func viewDidLoad() {
        super.viewDidLoad()

        let userDefaults = UserDefaults.standard

        let statusFrame = UIApplication.shared.statusBarFrame
        var viewFrame = view.frame
        viewFrame.origin.y = statusFrame.size.height
        viewFrame.size.height -= statusFrame.size.height

        let userContentController = WKUserContentController()
        userContentController.add(self, name: "appInterface")

        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.userContentController = userContentController

        var processPool: WKProcessPool
        if let encodedPool = userDefaults.value(forKey: "pool") as? Data,
           let decodedPool = try? NSKeyedUnarchiver.unarchivedObject(ofClass: WKProcessPool.self, from: encodedPool) {
            processPool = decodedPool
        } else {
            processPool = WKProcessPool()
            let encodedPool = try? NSKeyedArchiver.archivedData(withRootObject: processPool, requiringSecureCoding: true)
            userDefaults.set(encodedPool, forKey: "pool")
        }
        webConfiguration.processPool = processPool

        let group = DispatchGroup()
        if let encodedCookies = userDefaults.value(forKey: "cookies") as? Data,
           let cookies = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, HTTPCookie.self], from: encodedCookies) as? [HTTPCookie] {
            if #available(iOS 11.0, *) {
                cookies.forEach { cookie in
                    group.enter()
                    webConfiguration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                        group.leave()
                    }
                }
            }
        }

        self.webView = WKWebView(frame: viewFrame, configuration: webConfiguration)
        self.webView.uiDelegate = self
        self.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        view.addSubview(self.webView)

        group.notify(queue: DispatchQueue.main) {
            self.initialized = true
            self.loadPage()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(onTerminate(_:)), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onReceive(_:)), name: MainViewController.eventToken, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onEvent(_:)), name: MainViewController.eventEvent, object: nil)
    }

    private func loadPage() {
        if let urlString = UserDefaults.standard.object(forKey: "url") as? String {
            var urlComponents = URLComponents(string: urlString)
            if let eventId = pendingEventId {
                urlComponents?.queryItems = [URLQueryItem(name: "eventId", value: eventId)]
                pendingEventId = nil
            }
            if let url = urlComponents?.url {
                self.webView.load(URLRequest(url: url))
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NotificationCenter.default.removeObserver(self, name: MainViewController.eventEvent, object: nil)
        NotificationCenter.default.removeObserver(self, name: MainViewController.eventToken, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
    }

    @objc func onTerminate(_ notification: Notification) {
        if #available(iOS 11.0, *) {
            self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let encodedCookies = try? NSKeyedArchiver.archivedData(withRootObject: cookies, requiringSecureCoding: true)
                UserDefaults.standard.set(encodedCookies, forKey: "cookies")
            }
        }
    }

    @objc func onReceive(_ notification: Notification) {
        if let token = notification.userInfo?[MainViewController.keyToken] {
            let code = "updateNotificationToken && updateNotificationToken('\(token)')"
            webView.evaluateJavaScript(code, completionHandler: nil)
        }
    }

    @objc func onEvent(_ notification: Notification) {
        if let eventId = notification.userInfo?[MainViewController.keyEventId] as? String {
            pendingEventId = eventId
            if initialized {
                loadPage()
            }
        }
    }

}

extension MainViewController : WKScriptMessageHandler {

    func createFullPdf(of fileName: String, webView: WKWebView, completion: @escaping (URL?) -> Void) {
        let printFormatter = webView.viewPrintFormatter()
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(printFormatter, startingAtPageAt: 0)

        let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8) // A4 size in points
        let printable = page.insetBy(dx: 20, dy: 20) // Small margin if you want

        renderer.setValue(page, forKey: "paperRect")
        renderer.setValue(printable, forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, nil)

        for i in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }

        UIGraphicsEndPDFContext()

        let tempUrl = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: tempUrl)
            completion(tempUrl)
        } catch {
            print("Failed to save PDF: \(error)")
            completion(nil)
        }
    }


    func showLoadingSpinner() {
        if #available(iOS 13.0, *) {
            loadingSpinner = UIActivityIndicatorView(style: .large)
        }
        if let spinner = loadingSpinner {
            spinner.center = view.center
            spinner.startAnimating()
            view.addSubview(spinner)
        }
    }

    func hideLoadingSpinner() {
        loadingSpinner?.stopAnimating()
        loadingSpinner?.removeFromSuperview()
        loadingSpinner = nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? String {
            if body.starts(with: "print") {
                if body.count > 6 {
                    showLoadingSpinner()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        let fileName = String(body[body.index(body.startIndex, offsetBy: 6)...])
                        self.createFullPdf(of: fileName, webView: self.webView) { url in
                            if let url = url {
                                let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                                self.present(activityVC, animated: true)
                            }
                            self.hideLoadingSpinner()
                        }
                    }
                }
            } else if body.starts(with: "login") {
                if body.count > 6 {
                    let token = String(body[body.index(body.startIndex, offsetBy: 6)...])
                    SecurityManager.shared.saveToken(token)
                }
                NotificationCenter.default.post(name: MainViewController.eventLogin, object: nil)
            } else if body.starts(with: "authentication") {
                if let token = SecurityManager.shared.readToken() {
                    let code = "handleLoginToken && handleLoginToken('\(token)')"
                    webView.evaluateJavaScript(code, completionHandler: nil)
                }
            } else if body.starts(with: "logout") {
                SecurityManager.shared.deleteToken()
            } else if body.starts(with: "server") {
                let urlString = String(body[body.index(body.startIndex, offsetBy: 7)...])
                UserDefaults.standard.set(urlString, forKey: "url")
                if let url = URL(string: urlString) {
                    self.webView.load(URLRequest(url: url))
                }
            }
        }
    }

}
