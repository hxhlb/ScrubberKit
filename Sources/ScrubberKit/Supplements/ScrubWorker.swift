//
//  ScrubWorker.swift
//  AppleQuery
//
//  Created by QAQ on 2023/8/23.
//

import WebKit

private let accessControlSourceCode = ###"""
[
  {
    "trigger": {
      "url-filter": ".*",
      "resource-type": ["style-sheet"]
    },
    "action": {
      "type": "block"
    }
  },
  {
    "trigger": {
      "url-filter": ".*",
      "resource-type": ["font"]
    },
    "action": {
      "type": "block"
    }
  },
  {
    "trigger": {
      "url-filter": ".*",
      "resource-type": ["image"]
    },
    "action": {
      "type": "block"
    }
  },
  {
    "trigger": {
      "url-filter": ".*",
      "resource-type": ["media"]
    },
    "action": {
      "type": "block"
    }
  }
]
"""###
private var accessControlRule: WKContentRuleList?

class ScrubWorker: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let web = WebView()
    private let baseUrl: URL

    struct ScrubResult {
        let url: URL
        let document: String
        let markdownDocument: String
    }

    private var completion: ((ScrubResult) -> Void)?

    init(baseUrl: URL, softTimeout: TimeInterval = 15, completion: @escaping (ScrubResult) -> Void) {
        self.baseUrl = baseUrl
        self.completion = completion

        super.init()

        web.uiDelegate = self
        web.navigationDelegate = self
        let request = URLRequest(
            url: baseUrl,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: softTimeout
        )
        web.load(request)

        scheduleContentReporter(delay: softTimeout)
    }

    deinit {
        performCompletion()
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        web.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight)") { _, _ in
        }
        scheduleContentReporter(delay: 3) // in case of another navigation fired by js
    }

    var navigationLimit = 4

    func webView(
        _: WKWebView,
        decidePolicyFor _: WKNavigationAction,
        preferences _: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        guard navigationLimit > 0 else {
            decisionHandler(.cancel, .init())
            scheduleContentReporter(delay: 0)
            return
        }
        navigationLimit -= 1
        scheduleContentReporter(delay: 5)
        decisionHandler(.allow, .init())
    }

    func cancel() {
        if Thread.isMainThread {
            performCompletion()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.performCompletion()
            }
        }
    }

    func scheduleContentReporter(delay: Double) {
        assert(Thread.isMainThread)
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(performCompletion),
            object: nil
        )
        perform(#selector(performCompletion), with: nil, afterDelay: delay)
    }

    @objc
    private func performCompletion() {
        guard let completion else { return }
        self.completion = nil
        
        let web = web
        
        web.evaluateJavaScript("document.documentElement.outerHTML") { data, _ in
            web.captureMarkdownContent { markdown in
                completion(.init(
                    url: self.web.url ?? self.baseUrl,
                    document: data as? String ?? "",
                    markdownDocument: markdown
                ))
            }
        }
    }
}

private extension ScrubWorker {
    class WebView: WKWebView {
        init() {
            let config = WKWebViewConfiguration()
            #if os(iOS)
                config.allowsInlineMediaPlayback = false
                config.allowsPictureInPictureMediaPlayback = false
                config.dataDetectorTypes = []
            #endif
            config.allowsAirPlayForMediaPlayback = false
            config.mediaTypesRequiringUserActionForPlayback = .all
            config.applicationNameForUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
            config.websiteDataStore = .nonPersistent()
            if #available(iOS 17.0, macOS 14.0, *) {
                config.allowsInlinePredictions = false
            }
            if let accessControlRule {
                config.userContentController.add(accessControlRule)
            } else {
                assertionFailure("accessControlRule is nil, please call setup at boot")
            }
            Turndown.setupScripts.forEach { script in
                config.userContentController.addUserScript(script)
            }
            super.init(
                frame: .init(x: 0, y: 0, width: 800, height: 3200),
                configuration: config
            )
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError()
        }
    }
}

extension ScrubWorker {
    static func compileAccessRules() {
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "PlainTextAccessControlRule",
            encodedContentRuleList: accessControlSourceCode
        ) { list, _ in
            accessControlRule = list
        }
    }
}
