import Cocoa
import WebKit
import UniformTypeIdentifiers
import Network

// ==========================================
// 0. PROXY MANAGER
// ==========================================
struct ProxyConfigData: Codable {
    var isEnabled: Bool = false
    var host: String = "127.0.0.1"
    var port: Int = 8080
}

class ProxyManager {
    static let shared = ProxyManager()
    private(set) var config: ProxyConfigData

    private init() {
        if let data = UserDefaults.standard.data(forKey: "SBProxySettings"),
           let saved = try? JSONDecoder().decode(ProxyConfigData.self, from: data) {
            self.config = saved
        } else {
            self.config = ProxyConfigData()
        }
    }

    func save(config: ProxyConfigData) {
        self.config = config
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "SBProxySettings")
        }
    }

    func apply(to dataStore: WKWebsiteDataStore) {
        if #available(macOS 14.0, *) {
            if config.isEnabled {
                let proxyEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(config.host), port: NWEndpoint.Port(integerLiteral: UInt16(config.port)))
                let proxyConfig = ProxyConfiguration(httpCONNECTProxy: proxyEndpoint)
                dataStore.proxyConfigurations = [proxyConfig]
            } else {
                dataStore.proxyConfigurations = []
            }
        }
    }

    func getURLSession() -> URLSession {
        let sessionConfig = URLSessionConfiguration.default
        if config.isEnabled {
            sessionConfig.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable: true,
                kCFNetworkProxiesHTTPProxy: config.host,
                kCFNetworkProxiesHTTPPort: config.port,
                kCFNetworkProxiesHTTPSEnable: true,
                kCFNetworkProxiesHTTPSProxy: config.host,
                kCFNetworkProxiesHTTPSPort: config.port,
            ]
        }
        return URLSession(configuration: sessionConfig)
    }
}

// ==========================================
// HELPERS & CONSTANTS
// ==========================================
private func formatBytes(_ n: Int64) -> String {
    guard n > 0 else { return "" }
    return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

private let safariUA =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
    "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
    "Version/26.0 Safari/605.1.15"

private let discordUA =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
    "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
    "Version/17.4 Safari/605.1.15"

// Centralized Notification for reloading scripts across all tabs
extension Notification.Name {
    static let reloadBrowserScripts = Notification.Name("reloadBrowserScripts")
    static let proxySettingsChanged = Notification.Name("proxySettingsChanged")
}

// ==========================================
// FLIPPED CONTAINER
// ==========================================
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// ==========================================
// PILL WRAPPER & PROGRESS BAR
// ==========================================
private final class PillWrapperView: NSView {
    var progress: Double = 0.0 { didSet { updateProgress() } }
    var showProgress: Bool = false { didSet { updateProgress() } }

    private let progressLayer = CALayer()
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true 
        progressLayer.anchorPoint = CGPoint(x: 0, y: 0)
        progressLayer.opacity = 0
        layer?.addSublayer(progressLayer)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        progressLayer.backgroundColor = NSColor.controlAccentColor.cgColor
    }

    override func layout() {
        super.layout()
        updateProgress()
    }

    private func updateProgress() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        
        let targetWidth = bounds.width * CGFloat(progress)
        progressLayer.bounds = CGRect(x: 0, y: 0, width: targetWidth, height: 3)
        progressLayer.position = CGPoint(x: 0, y: 0)
        progressLayer.opacity = (showProgress && progress > 0) ? 1.0 : 0.0
        
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        if let urlField = subviews.first as? NSTextField, urlField.isEditable {
            window?.makeFirstResponder(urlField)
        }
    }
}

// ==========================================
// TOOLBAR BUTTON
// ==========================================
final class ToolbarButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovered  = false
    private var isPressed  = false

    convenience init(symbol: String, size: CGFloat = 15, weight: NSFont.Weight = .regular,
                     tooltip: String? = nil, target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?.withSymbolConfiguration(cfg)
        self.target = target; self.action = action
        bezelStyle = .inline; isBordered = false; imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        if let tip = tooltip { toolTip = tip }
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isPressed || isHovered {
            let alpha: CGFloat = isPressed ? 0.22 : 0.13
            NSColor.labelColor.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited (with event: NSEvent) { isHovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        isPressed = true; needsDisplay = true
        super.mouseDown(with: event)
        isPressed = false; needsDisplay = true
    }

    override var isEnabled: Bool {
        didSet { contentTintColor = isEnabled ? .secondaryLabelColor : .tertiaryLabelColor }
    }
}

// ==========================================
// 1. DOWNLOAD ITEM
// ==========================================
final class DownloadItem: NSObject {
    weak var download: WKDownload?
    private(set) var filename = "Preparing…"
    private(set) var destinationURL: URL?
    var partURL: URL?

    let rowView: NSView
    let progressBar: NSProgressIndicator

    private let iconView: NSImageView
    private let nameLabel: NSTextField
    private let sizeLabel: NSTextField
    private let finderBtn: NSButton
    private let cancelBtn: NSButton

    private var kvo: NSKeyValueObservation?
    private var speedSampleBytes: Int64 = 0
    private var speedSampleTime: Date = Date()
    private var currentSpeed: Int64 = 0

    init(download: WKDownload) {
        self.download = download

        // 1. ICON
        iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
        iconView.contentTintColor = .tertiaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        // 2. LABELS & PROGRESS BAR
        nameLabel = NSTextField(labelWithString: "Preparing…")
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.alignment = .left
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        sizeLabel = NSTextField(labelWithString: "")
        sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.lineBreakMode = .byTruncatingTail
        sizeLabel.alignment = .left
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false

        progressBar = NSProgressIndicator()
        progressBar.style = .bar
        progressBar.controlSize = .small
        progressBar.isIndeterminate = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.startAnimation(nil)

        // 3. BUTTONS
        let sym = NSImage.SymbolConfiguration(pointSize: 13, weight: .light)
        
        finderBtn = NSButton()
        finderBtn.bezelStyle = .inline; finderBtn.isBordered = false
        finderBtn.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Show")?.withSymbolConfiguration(sym)
        finderBtn.isEnabled = false
        finderBtn.contentTintColor = .tertiaryLabelColor
        finderBtn.translatesAutoresizingMaskIntoConstraints = false
        
        cancelBtn = NSButton()
        cancelBtn.bezelStyle = .inline; cancelBtn.isBordered = false
        cancelBtn.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Cancel")?.withSymbolConfiguration(sym)
        cancelBtn.contentTintColor = .secondaryLabelColor
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false

        // 4. MASTER ROW (Absolute Cage)
        let mainRow = NSView()
        mainRow.translatesAutoresizingMaskIntoConstraints = false
        
        mainRow.addSubview(iconView)
        mainRow.addSubview(nameLabel)
        mainRow.addSubview(sizeLabel)
        mainRow.addSubview(progressBar)
        mainRow.addSubview(finderBtn)
        mainRow.addSubview(cancelBtn)

        NSLayoutConstraint.activate([
            // BOLT ICON TO LEFT EDGE
            iconView.leadingAnchor.constraint(equalTo: mainRow.leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: mainRow.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),

            // BOLT CANCEL BUTTON TO RIGHT EDGE
            cancelBtn.trailingAnchor.constraint(equalTo: mainRow.trailingAnchor, constant: -12),
            cancelBtn.centerYAnchor.constraint(equalTo: mainRow.centerYAnchor),
            cancelBtn.widthAnchor.constraint(equalToConstant: 24),
            cancelBtn.heightAnchor.constraint(equalToConstant: 24),

            // BOLT FINDER BUTTON DIRECTLY LEFT OF CANCEL BUTTON
            finderBtn.trailingAnchor.constraint(equalTo: cancelBtn.leadingAnchor, constant: -4),
            finderBtn.centerYAnchor.constraint(equalTo: mainRow.centerYAnchor),
            finderBtn.widthAnchor.constraint(equalToConstant: 24),
            finderBtn.heightAnchor.constraint(equalToConstant: 24),

            // TRAP TEXT & BAR IN THE MIDDLE (Icon on left, Finder Btn on right)
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(equalTo: finderBtn.leadingAnchor, constant: -10),
            nameLabel.topAnchor.constraint(equalTo: mainRow.topAnchor, constant: 12),

            sizeLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            sizeLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            sizeLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),

            progressBar.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            progressBar.topAnchor.constraint(equalTo: sizeLabel.bottomAnchor, constant: 4),
            progressBar.bottomAnchor.constraint(equalTo: mainRow.bottomAnchor, constant: -12)
        ])

        rowView = mainRow
        super.init()

        finderBtn.target = self; finderBtn.action = #selector(showInFinder)
        cancelBtn.target = self; cancelBtn.action = #selector(cancelOrClear)

        kvo = download.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] prog, _ in
            DispatchQueue.main.async { self?.refreshProgress(prog) }
        }
    }

    private func refreshProgress(_ prog: Progress) {
        let done = prog.completedUnitCount; let total = prog.totalUnitCount
        guard done >= 0 else { return }

        let now = Date()
        let dt = now.timeIntervalSince(speedSampleTime)
        if dt >= 0.5 {
            let delta = done - speedSampleBytes
            if delta >= 0 {
                let raw = Int64(Double(delta) / max(dt, 0.001))
                currentSpeed = currentSpeed == 0 ? raw : Int64(0.4 * Double(raw) + 0.6 * Double(currentSpeed))
            }
            speedSampleBytes = done; speedSampleTime = now
        }

        if total > 0 {
            progressBar.stopAnimation(nil)
            progressBar.isIndeterminate = false
            progressBar.doubleValue = prog.fractionCompleted * 100
            let pct = Int(prog.fractionCompleted * 100)
            let speedStr = currentSpeed > 0 ? " — \(formatBytes(currentSpeed))/s" : ""
            sizeLabel.stringValue = "\(pct)%  \(formatBytes(done)) / \(formatBytes(total))\(speedStr)"
        } else if done > 0 {
            let speedStr = currentSpeed > 0 ? "  \(formatBytes(currentSpeed))/s" : ""
            sizeLabel.stringValue = "\(formatBytes(done))\(speedStr)"
        }
    }

    func setFilename(_ name: String) {
        filename = name
        nameLabel.stringValue = name
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty {
            if #available(macOS 12.0, *) {
                iconView.image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
            } else {
                iconView.image = NSWorkspace.shared.icon(forFileType: ext)
            }
        }
    }

    func markComplete(at url: URL) {
        destinationURL = url; kvo = nil; currentSpeed = 0
        progressBar.stopAnimation(nil); progressBar.isHidden = true
        iconView.image = NSWorkspace.shared.icon(forFile: url.path)
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            sizeLabel.stringValue = formatBytes(Int64(size))
        }
        progressBar.isHidden = true
        finderBtn.isEnabled = true
        finderBtn.contentTintColor = .controlAccentColor
        download = nil; partURL = nil
    }

    func markFailed(message: String = "Failed") {
        kvo = nil; currentSpeed = 0
        progressBar.stopAnimation(nil); progressBar.isHidden = true
        sizeLabel.stringValue = message; sizeLabel.textColor = .systemRed
        download = nil
    }

    @objc private func showInFinder() {
        guard let url = destinationURL else { return }
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }

    @objc private func cancelOrClear() {
        if let dl = download {
            dl.cancel { _ in }
            if let part = partURL { try? FileManager.default.removeItem(at: part); partURL = nil }
            markFailed(message: "Cancelled")
        } else {
            guard let stack = rowView.superview as? NSStackView else { return }
            let views = stack.arrangedSubviews
            guard let idx = views.firstIndex(of: rowView) else { return }
            if idx + 1 < views.count, views[idx + 1] is NSBox { stack.removeView(views[idx + 1]) }
            else if idx > 0, views[idx - 1] is NSBox { stack.removeView(views[idx - 1]) }
            stack.removeView(rowView)
        }
    }
}

// ==========================================
// 2. DOWNLOAD MANAGER
// ==========================================
class DownloadManager: NSObject {
    static let shared = DownloadManager()
    let popover = NSPopover()
    private let itemsStack = NSStackView()
    private var items: [ObjectIdentifier: DownloadItem] = [:]
    private let scrollView = NSScrollView()

    override init() {
        super.init()

        itemsStack.orientation = .vertical
        itemsStack.alignment = .leading
        itemsStack.spacing = 0
        itemsStack.translatesAutoresizingMaskIntoConstraints = false

        let flipHost = FlippedView()
        flipHost.translatesAutoresizingMaskIntoConstraints = false
        flipHost.addSubview(itemsStack)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = flipHost

        NSLayoutConstraint.activate([
            itemsStack.topAnchor.constraint(equalTo: flipHost.topAnchor),
            itemsStack.leadingAnchor.constraint(equalTo: flipHost.leadingAnchor),
            itemsStack.trailingAnchor.constraint(equalTo: flipHost.trailingAnchor),
            itemsStack.bottomAnchor.constraint(equalTo: flipHost.bottomAnchor),
            flipHost.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])

        let titleLabel = NSTextField(labelWithString: "Downloads")
        titleLabel.font = .boldSystemFont(ofSize: 14)

        let openBtn = NSButton(title: "Open Folder", target: self, action: #selector(openFolder))
        openBtn.bezelStyle = .inline

        // INVISIBLE SPACER: Pushes the Open Folder button to the far right edge
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let headerRow = NSStackView(views: [titleLabel, headerSpacer, openBtn])
        headerRow.orientation = .horizontal
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let headerSep = NSBox(); headerSep.boxType = .separator
        headerSep.translatesAutoresizingMaskIntoConstraints = false

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 0
        container.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 8, right: 12)
        
        container.addArrangedSubview(headerRow)
        container.setCustomSpacing(8, after: headerRow)
        container.addArrangedSubview(headerSep)
        container.setCustomSpacing(0, after: headerSep)
        container.addArrangedSubview(scrollView)
        
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 420))
        container.frame = contentView.bounds
        container.autoresizingMask = [.width, .height]
        contentView.addSubview(container)

        // FORCE FULL WIDTH: Explicitly link widths to the container frame width
        NSLayoutConstraint.activate([
            headerRow.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -24),
            headerSep.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -24),
            scrollView.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -24)
        ])

        let vc = NSViewController()
        vc.view = contentView
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: 340, height: 420)
        popover.behavior = .transient
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!)
    }

    func show(relativeTo button: NSButton) {
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    func startTracking(_ download: WKDownload) {
        let item = DownloadItem(download: download)
        let id = ObjectIdentifier(download)
        DispatchQueue.main.async {
            let hadItems = !self.itemsStack.arrangedSubviews.isEmpty
            self.itemsStack.insertView(item.rowView, at: 0, in: .top)
            
            // STRICTLY PIN THE ROW TO BOTH THE LEFT AND RIGHT SIDES OF THE POPOVER
            NSLayoutConstraint.activate([ 
                item.rowView.leadingAnchor.constraint(equalTo: self.itemsStack.leadingAnchor),
                item.rowView.trailingAnchor.constraint(equalTo: self.itemsStack.trailingAnchor)
            ])
            
            if hadItems {
                let sep = NSBox(); sep.boxType = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                self.itemsStack.insertView(sep, at: 1, in: .top)
                NSLayoutConstraint.activate([ 
                    sep.leadingAnchor.constraint(equalTo: self.itemsStack.leadingAnchor),
                    sep.trailingAnchor.constraint(equalTo: self.itemsStack.trailingAnchor)
                ])
            }
            
            self.items[id] = item
            self.scrollView.contentView.scroll(to: .zero)
        }
    }

    func setPartURL(_ partURL: URL, for download: WKDownload) {
        DispatchQueue.main.async { self.items[ObjectIdentifier(download)]?.partURL = partURL }
    }
    func updateFilename(_ filename: String, for download: WKDownload) {
        DispatchQueue.main.async { self.items[ObjectIdentifier(download)]?.setFilename(filename) }
    }
    func markComplete(at url: URL, for download: WKDownload) {
        DispatchQueue.main.async { self.items[ObjectIdentifier(download)]?.markComplete(at: url) }
    }
    func markFailed(for download: WKDownload) {
        DispatchQueue.main.async { self.items[ObjectIdentifier(download)]?.markFailed() }
    }
}

// ==========================================
// 3. HISTORY & FREQUENCY MANAGER
// ==========================================
class HistoryManager {
    static let shared = HistoryManager()
    var history: [String: Int] = [:]

    init() {
        if let saved = UserDefaults.standard.dictionary(forKey: "SBFrequency") as? [String: Int] {
            history = saved
        }
    }

    func addVisit(_ url: String) {
        guard url.starts(with: "http") else { return }
        history[url, default: 0] += 1
        UserDefaults.standard.set(history, forKey: "SBFrequency")
    }

    func suggest(for input: String) -> String? {
        guard !input.isEmpty else { return nil }
        let isDomainOnly = !input.contains("/")
        var bestMatch: String?
        var highestFreq = -1
        let clean = input.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "").lowercased()

        for (urlStr, freq) in history {
            let u = urlStr.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            if u.lowercased().hasPrefix(clean) && freq > highestFreq {
                highestFreq = freq
                bestMatch = isDomainOnly ? (u.components(separatedBy: "/").first ?? u) : u
            }
        }
        return bestMatch
    }
}

// ==========================================
// 4. CONTENT BLOCKER MANAGER
// ==========================================
struct FilterListInfo: Codable {
    let id: String
    let name: String
    let category: String
    var enabled: Bool
    var lastUpdated: Date?
    var url: URL
}

class ContentBlockerManager {
    static let shared = ContentBlockerManager()

    private(set) var lists: [FilterListInfo] = [
        FilterListInfo(id: "ublock-filters", name: "uBlock filters", category: "uBlock Origin", enabled: true, lastUpdated: nil, 
                       url: URL(string: "https://github.com/bnema/ublock-webkit-filters/releases/latest/download/ublock-filters.json")!),
        FilterListInfo(id: "ublock-badware", name: "uBlock filters - Badware risks", category: "uBlock Origin", enabled: true, lastUpdated: nil, 
                       url: URL(string: "https://github.com/bnema/ublock-webkit-filters/releases/latest/download/ublock-badware.json")!),
        FilterListInfo(id: "ublock-privacy", name: "uBlock filters - Privacy", category: "uBlock Origin", enabled: true, lastUpdated: nil, 
                       url: URL(string: "https://github.com/bnema/ublock-webkit-filters/releases/latest/download/ublock-privacy.json")!),
        FilterListInfo(id: "ublock-quick-fixes", name: "uBlock filters - Quick fixes", category: "uBlock Origin", enabled: true, lastUpdated: nil, 
                       url: URL(string: "https://github.com/bnema/ublock-webkit-filters/releases/latest/download/ublock-quick-fixes.json")!),
        FilterListInfo(id: "ublock-unbreak", name: "uBlock filters - Unbreak", category: "uBlock Origin", enabled: true, lastUpdated: nil, 
                       url: URL(string: "https://github.com/bnema/ublock-webkit-filters/releases/latest/download/ublock-unbreak.json")!),

        FilterListInfo(id: "easylist", name: "EasyList", category: "EasyList", enabled: true, lastUpdated: nil, 
                       url: URL(string: "https://github.com/bnema/ublock-webkit-filters/releases/latest/download/easylist.json")!),
        FilterListInfo(id: "easyprivacy", name: "EasyPrivacy", category: "EasyList", enabled: true, lastUpdated: nil, 
                       url: URL(string: "https://github.com/bnema/ublock-webkit-filters/releases/latest/download/easyprivacy.json")!),

        FilterListInfo(id: "listkr", name: "List-KR", category: "Miscellaneous", enabled: true, lastUpdated: nil, 
                       url: URL(string: "https://list-kr-webkit.pages.dev/listkr-unified.json")!),
        FilterListInfo(id: "peter-lowe", name: "Peter Lowe's Ad and tracking server list", category: "Miscellaneous", enabled: true, lastUpdated: nil, 
                       url: URL(string: "https://github.com/bnema/ublock-webkit-filters/releases/latest/download/peter-lowe.json")!),
    ]

    private let store = WKContentRuleListStore.default()
    private(set) var compiledRules: [String: [WKContentRuleList]] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: "SBContentBlockerLists"),
           let saved = try? JSONDecoder().decode([FilterListInfo].self, from: data) {
            for savedList in saved {
                if let idx = lists.firstIndex(where: { $0.id == savedList.id }) {
                    lists[idx].enabled = savedList.enabled
                    lists[idx].lastUpdated = savedList.lastUpdated
                }
            }
        }
    }

    func saveState() {
        if let data = try? JSONEncoder().encode(lists) {
            UserDefaults.standard.set(data, forKey: "SBContentBlockerLists")
        }
    }

    func setEnabled(_ enabled: Bool, forListID id: String) {
        if let idx = lists.firstIndex(where: { $0.id == id }) {
            lists[idx].enabled = enabled
            saveState()
            
            if enabled {
                downloadAndCompile(listID: id)
            } else {
                compiledRules.removeValue(forKey: id)
                applyToAllTabs()
            }
        }
    }

    func downloadAndCompile(listID: String, completion: ((Bool, String) -> Void)? = nil) {
        guard let idx = lists.firstIndex(where: { $0.id == listID }) else { return }
        let info = lists[idx]
        
        URLSession.shared.dataTask(with: info.url) { data, response, error in
            if let err = error {
                DispatchQueue.main.async { completion?(false, "Download failed: \(err.localizedDescription)") }
                return
            }
            
            // Validate it's an actual file, preventing WebKit Error 6
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                DispatchQueue.main.async { completion?(false, "HTTP Error \(httpResponse.statusCode): Not found") }
                return
            }
            
            guard let data = data, let rawJSON = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async { completion?(false, "Invalid JSON data received") }
                return
            }
            
            self.store?.compileContentRuleList(forIdentifier: listID, encodedContentRuleList: rawJSON) { ruleList, error in
                if let err = error {
                    print("[Blocker] Compilation error for \(listID): \(err.localizedDescription)")
                    DispatchQueue.main.async { completion?(false, "Compilation failed: \(err.localizedDescription)") }
                    return
                }
                
                guard let ruleList = ruleList else {
                    DispatchQueue.main.async { completion?(false, "Rule list was nil after compilation") }
                    return
                }
                
                DispatchQueue.main.async {
                    self.compiledRules[listID] = [ruleList]
                    self.lists[idx].lastUpdated = Date()
                    self.saveState()
                    self.applyToAllTabs()
                    completion?(true, "Compiled successfully")
                }
            }
        }.resume()
    }

    func applyToAllTabs() {
        let app = NSApplication.shared.delegate as! AppDelegate
        for tab in app.tabs {
            let ucc = tab.webView.configuration.userContentController
            ucc.removeAllContentRuleLists()
            
            for info in lists where info.enabled {
                if let rules = compiledRules[info.id] {
                    for rl in rules {
                        ucc.add(rl)
                    }
                }
            }
        }
    }

    func apply(to ucc: WKUserContentController) {
        ucc.removeAllContentRuleLists()
        for info in lists where info.enabled {
            if let rules = compiledRules[info.id] {
                for rl in rules {
                    ucc.add(rl)
                }
            }
        }
    }

    func loadAllEnabled() {
        for info in lists where info.enabled {
            store?.lookUpContentRuleList(forIdentifier: info.id) { ruleList, error in
                if let rl = ruleList {
                    DispatchQueue.main.async {
                        self.compiledRules[info.id] = [rl]
                        self.applyToAllTabs()
                    }

                    if let lastUpdated = info.lastUpdated, Date().timeIntervalSince(lastUpdated) > 86400 {
                        self.downloadAndCompile(listID: info.id)
                    }
                } else {
                    self.downloadAndCompile(listID: info.id)
                }
            }
        }
    }

    func updateAll(progress: ((String, Bool, String) -> Void)?, completion: (() -> Void)?) {
        let group = DispatchGroup()
        for info in lists where info.enabled {
            group.enter()
            downloadAndCompile(listID: info.id) { ok, reason in
                progress?(info.id, ok, reason)
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion?()
        }
    }

    func enabledCount() -> Int {
        return lists.filter { $0.enabled }.count
    }
}

// ==========================================
// 5. USER SCRIPT MANAGER
// ==========================================
struct UserScriptMeta: Codable {
    let filename: String
    var name: String
    var description: String
    var matches: [String]
    var enabled: Bool
}

class UserScriptManager {
    static let shared = UserScriptManager()

    private(set) var scripts: [UserScriptMeta] = []
    
    let scriptsDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SwiftBrowse/UserScripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private init() {
        seedDefaultScriptsIfNeeded()
        loadScripts()
    }

    private func seedDefaultScriptsIfNeeded() {
        let ytFilename = "youtube-ad-skipper.user.js"
        let ytFile = scriptsDir.appendingPathComponent(ytFilename)
        let didSeed = UserDefaults.standard.bool(forKey: "SBSeededUserScripts")
        
        if !didSeed && !FileManager.default.fileExists(atPath: ytFile.path) {
            let ytCode = """
            // ==UserScript==
            // @name         YouTube Ad Skipper
            // @description  Auto-skips YouTube video ads immediately
            // @match        *://*.youtube.com/*
            // ==/UserScript==
            (function() {
                const observer = new MutationObserver(() => {
                    const skipBtn = document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button');
                    if (skipBtn) skipBtn.click();
                    const adShowing = document.querySelector('.ad-showing, .ad-interrupting');
                    const vid = document.querySelector('video');
                    if (adShowing && vid && vid.duration > 0) vid.currentTime = vid.duration;
                });
                observer.observe(document.body, { childList: true, subtree: true });
            })();
            """
            try? ytCode.write(to: ytFile, atomically: true, encoding: .utf8)
            UserDefaults.standard.set(true, forKey: "SBSeededUserScripts")
        }
    }

    func loadScripts() {
        scripts.removeAll()
        let savedMeta = loadPersistedMeta()
        
        guard let files = try? FileManager.default.contentsOfDirectory(at: scriptsDir, includingPropertiesForKeys: nil) else { return }
        
        for file in files where file.pathExtension == "js" {
            let filename = file.lastPathComponent
            if let content = try? String(contentsOf: file, encoding: .utf8) {
                let parsed = parseHeader(content)
                let enabled = savedMeta[filename]?.enabled ?? true
                let meta = UserScriptMeta(filename: filename, name: parsed.name, description: parsed.desc, matches: parsed.matches, enabled: enabled)
                scripts.append(meta)
            }
        }
        scripts.sort { $0.name < $1.name }
    }

    private func parseHeader(_ js: String) -> (name: String, desc: String, matches: [String]) {
        var name = "Unnamed Script"
        var desc = "No description provided."
        var matches = [String]()
        
        let lines = js.components(separatedBy: .newlines)
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("// @name") { name = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("// @description") { desc = String(t.dropFirst(14)).trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("// @match") { matches.append(String(t.dropFirst(8)).trimmingCharacters(in: .whitespaces)) }
            if t.hasPrefix("// @include") { matches.append(String(t.dropFirst(10)).trimmingCharacters(in: .whitespaces)) }
            if t.hasPrefix("// ==/UserScript==") { break }
        }
        return (name, desc, matches)
    }

    private func loadPersistedMeta() -> [String: UserScriptMeta] {
        guard let data = UserDefaults.standard.data(forKey: "SBUserScriptsMeta"),
              let dict = try? JSONDecoder().decode([String: UserScriptMeta].self, from: data) else { return [:] }
        return dict
    }

    private func savePersistedMeta() {
        let dict = Dictionary(uniqueKeysWithValues: scripts.map { ($0.filename, $0) })
        if let data = try? JSONEncoder().encode(dict) { UserDefaults.standard.set(data, forKey: "SBUserScriptsMeta") }
    }

    func setEnabled(_ enabled: Bool, forFilename filename: String) {
        guard let idx = scripts.firstIndex(where: { $0.filename == filename }) else { return }
        scripts[idx].enabled = enabled
        savePersistedMeta()
        NotificationCenter.default.post(name: .reloadBrowserScripts, object: nil)
    }

    func deleteScript(filename: String) {
        let url = scriptsDir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
        scripts.removeAll { $0.filename == filename }
        savePersistedMeta()
        NotificationCenter.default.post(name: .reloadBrowserScripts, object: nil)
    }

    func importScript(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        let dest = scriptsDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.copyItem(at: url, to: dest)
        loadScripts()
        NotificationCenter.default.post(name: .reloadBrowserScripts, object: nil)
    }

    private func convertMatchToJSRegex(_ match: String) -> String {
        var r = match.replacingOccurrences(of: ".", with: "\\.")
        r = r.replacingOccurrences(of: "*", with: ".*")
        r = r.replacingOccurrences(of: "?", with: "\\?")
        r = r.replacingOccurrences(of: "/", with: "\\/")
        return "/^\(r)$/"
    }

    func injectScripts(into controller: WKUserContentController) {
        for meta in scripts where meta.enabled {
            let fileURL = scriptsDir.appendingPathComponent(meta.filename)
            guard let rawJS = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            
            let jsRegexes = meta.matches.map { convertMatchToJSRegex($0) }.joined(separator: ", ")
            
            let safeWrapper = """
            (function() {
                try {
                    var href = window.location.href;
                    var matchers = [\(jsRegexes)];
                    var shouldRun = matchers.length === 0 || matchers.some(function(r) { return r.test(href); });
                    if (!shouldRun) return;
                    \(rawJS)
                } catch(e) { console.error('SwiftBrowse Script Error (\(meta.name)):', e); }
            })();
            """
            
            let wkScript = WKUserScript(source: safeWrapper, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
            controller.addUserScript(wkScript)
        }
    }
}


// ==========================================
// 6. SETTINGS WINDOW
// ==========================================
class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var containerView: NSView!
    private var segmentedControl: NSSegmentedControl!

    private var blockersView: NSView!
    private var scriptsView: NSView!
    private var networkView: NSView!

    // Blocker UI State
    private var statusLabels: [String: NSTextField] = [:]
    private var toggleButtons: [String: NSSwitch] = [:]
    private var updateButtons: [String: NSButton] = [:]
    private var progressIndicators: [String: NSProgressIndicator] = [:]
    private var updateAllBtn: NSButton!
    private var globalStatusLabel: NSTextField!
    
    // Proxy UI State
    private var proxyEnableSwitch: NSSwitch!
    private var proxyHostField: NSTextField!
    private var proxyPortField: NSTextField!

    func showSettings() {
        if let w = window, w.isVisible { w.makeKeyAndOrderFront(nil); return }
        buildWindow()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Settings"
        w.minSize = NSSize(width: 480, height: 380)
        w.isReleasedWhenClosed = false
        self.window = w

        segmentedControl = NSSegmentedControl(labels: ["Content Blockers", "User Scripts", "Network"], trackingMode: .selectOne, target: self, action: #selector(tabChanged(_:)))
        segmentedControl.selectedSegment = 0
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false

        containerView = NSView()
        containerView.translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView(views: [segmentedControl, containerView])
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 0, bottom: 0, right: 0)
        
        w.contentView = root
        NSLayoutConstraint.activate([
            containerView.widthAnchor.constraint(equalTo: root.widthAnchor),
            containerView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        buildBlockersView()
        buildScriptsView()
        buildNetworkView()
        tabChanged(segmentedControl)
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        containerView.subviews.forEach { $0.removeFromSuperview() }
        let activeView: NSView
        if sender.selectedSegment == 0 { activeView = blockersView }
        else if sender.selectedSegment == 1 { activeView = scriptsView }
        else { activeView = networkView }
        
        containerView.addSubview(activeView)
        NSLayoutConstraint.activate([
            activeView.topAnchor.constraint(equalTo: containerView.topAnchor),
            activeView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            activeView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            activeView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor)
        ])
    }

    // --- Network / Proxy View ---
    private func buildNetworkView() {
        networkView = NSView(); networkView.translatesAutoresizingMaskIntoConstraints = false
        
        let config = ProxyManager.shared.config
        
        proxyEnableSwitch = NSSwitch()
        proxyEnableSwitch.state = config.isEnabled ? .on : .off
        
        proxyHostField = NSTextField(string: config.host)
        proxyHostField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        
        proxyPortField = NSTextField(string: "\(config.port)")
        proxyPortField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        
        let enableRow = NSStackView(views: [NSTextField(labelWithString: "Enable Web Proxy:"), proxyEnableSwitch])
        let hostRow = NSStackView(views: [NSTextField(labelWithString: "Proxy Host:"), proxyHostField])
        let portRow = NSStackView(views: [NSTextField(labelWithString: "Proxy Port:"), proxyPortField])
        
        let saveBtn = NSButton(title: "Save & Apply Proxy Settings", target: self, action: #selector(saveProxySettings))
        saveBtn.bezelStyle = .rounded
        
        let stack = NSStackView(views: [enableRow, hostRow, portRow, saveBtn])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 15
        stack.edgeInsets = NSEdgeInsets(top: 30, left: 30, bottom: 30, right: 30)
        stack.translatesAutoresizingMaskIntoConstraints = false
        
        networkView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: networkView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: networkView.leadingAnchor)
        ])
    }
    
    @objc private func saveProxySettings() {
        let portInt = Int(proxyPortField.stringValue) ?? 8081
        let config = ProxyConfigData(isEnabled: proxyEnableSwitch.state == .on, host: proxyHostField.stringValue, port: portInt)
        ProxyManager.shared.save(config: config)
        
        NotificationCenter.default.post(name: .proxySettingsChanged, object: nil)
        
        let alert = NSAlert()
        alert.messageText = "Proxy Settings Saved"
        alert.informativeText = "Settings applied to future connections and tabs."
        alert.runModal()
    }

    // --- Blockers View Building ---
    private func buildBlockersView() {
        blockersView = NSView()
        blockersView.translatesAutoresizingMaskIntoConstraints = false
        
        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 15
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        
        var currentCategory = ""
        var currentBox: NSStackView?
        
        for info in ContentBlockerManager.shared.lists {
            if info.category != currentCategory {
                currentCategory = info.category
                let catLabel = NSTextField(labelWithString: currentCategory)
                catLabel.font = .boldSystemFont(ofSize: 13)
                catLabel.textColor = .secondaryLabelColor
                contentStack.addArrangedSubview(catLabel)
                
                let box = NSStackView()
                box.orientation = .vertical
                box.alignment = .leading
                box.spacing = 8
                box.translatesAutoresizingMaskIntoConstraints = false
                
                contentStack.addArrangedSubview(box)
                // Stretch the category box to the full width of the container
                box.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
                currentBox = box
            }
            
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            
            let toggle = NSSwitch()
            toggle.state = info.enabled ? .on : .off
            toggle.target = self
            toggle.action = #selector(toggleList(_:))
            toggle.identifier = NSUserInterfaceItemIdentifier(info.id)
            toggle.controlSize = .small
            toggleButtons[info.id] = toggle
            
            let nameLabel = NSTextField(labelWithString: info.name)
            nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
            
            let ts: String
            if let d = info.lastUpdated {
                let fmt = DateFormatter(); fmt.dateStyle = .short; fmt.timeStyle = .short
                ts = "Updated: \(fmt.string(from: d))"
            } else {
                ts = "Not yet downloaded"
            }
            
            let statusLabel = NSTextField(labelWithString: ts)
            statusLabel.font = .systemFont(ofSize: 10)
            statusLabel.textColor = .tertiaryLabelColor
            statusLabels[info.id] = statusLabel
            
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isDisplayedWhenStopped = false
            spinner.translatesAutoresizingMaskIntoConstraints = false
            progressIndicators[info.id] = spinner
            
            let updateBtn = NSButton(title: "Update", target: self, action: #selector(updateSingleList(_:)))
            updateBtn.bezelStyle = .inline
            updateBtn.controlSize = .small
            updateBtn.identifier = NSUserInterfaceItemIdentifier(info.id)
            updateBtn.isEnabled = info.enabled
            updateButtons[info.id] = updateBtn
            
            // THE INVISIBLE SPACER: Pushes everything after it to the right
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            
            row.addArrangedSubview(toggle)
            row.addArrangedSubview(nameLabel)
            row.addArrangedSubview(spacer) // <--- Insert spacer here
            row.addArrangedSubview(spinner)
            row.addArrangedSubview(statusLabel)
            row.addArrangedSubview(updateBtn)
            
            currentBox?.addArrangedSubview(row)
            
            // Stretch the row to the full width of the category box
            row.widthAnchor.constraint(equalTo: currentBox!.widthAnchor).isActive = true
        }
        
        let sep = NSBox(); sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        
        let bottomRow = NSStackView()
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 10
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        
        updateAllBtn = NSButton(title: "Update All Enabled", target: self, action: #selector(updateAllLists))
        updateAllBtn.bezelStyle = .push
        updateAllBtn.controlSize = .regular
        
        globalStatusLabel = NSTextField(labelWithString: "\(ContentBlockerManager.shared.enabledCount()) lists enabled")
        globalStatusLabel.font = .systemFont(ofSize: 11)
        globalStatusLabel.textColor = .secondaryLabelColor
        
        // Pushes label to the left, button to the right
        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        
        bottomRow.addArrangedSubview(globalStatusLabel)
        bottomRow.addArrangedSubview(bottomSpacer)
        bottomRow.addArrangedSubview(updateAllBtn)
        
        contentStack.addArrangedSubview(bottomRow)
        bottomRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        
        let flipHost = FlippedView()
        flipHost.translatesAutoresizingMaskIntoConstraints = false
        flipHost.addSubview(contentStack)
        
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: flipHost.topAnchor, constant: 20),
            contentStack.leadingAnchor.constraint(equalTo: flipHost.leadingAnchor, constant: 30),
            contentStack.trailingAnchor.constraint(equalTo: flipHost.trailingAnchor, constant: -30),
            contentStack.bottomAnchor.constraint(equalTo: flipHost.bottomAnchor, constant: -20)
        ])
        
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = flipHost
        
        blockersView.addSubview(scrollView)
        
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: blockersView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: blockersView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: blockersView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: blockersView.bottomAnchor),
            flipHost.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])
    }

    private func buildBlockerRow(for info: FilterListInfo) -> NSView {
        let row = NSView(); row.translatesAutoresizingMaskIntoConstraints = false

        let toggle = NSSwitch(); toggle.state = info.enabled ? .on : .off; toggle.target = self; toggle.action = #selector(toggleList(_:))
        toggle.translatesAutoresizingMaskIntoConstraints = false; toggle.controlSize = .small
        toggleButtons[info.id] = toggle

        let nameLabel = NSTextField(labelWithString: info.name); nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail; nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let ts: String
        if let d = info.lastUpdated { let fmt = DateFormatter(); fmt.dateStyle = .short; fmt.timeStyle = .short; ts = "Updated: \(fmt.string(from: d))" }
        else { ts = "Not yet downloaded" }
        let statusLabel = NSTextField(labelWithString: ts); statusLabel.font = .systemFont(ofSize: 10); statusLabel.textColor = .tertiaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabels[info.id] = statusLabel

        let updateBtn = NSButton(title: "Update", target: self, action: #selector(updateSingleList(_:))); updateBtn.bezelStyle = .inline
        updateBtn.controlSize = .small; updateBtn.font = .systemFont(ofSize: 10); updateBtn.translatesAutoresizingMaskIntoConstraints = false
        updateButtons[info.id] = updateBtn

        row.addSubview(toggle); row.addSubview(nameLabel); row.addSubview(statusLabel); row.addSubview(updateBtn)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 44),
            toggle.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16), toggle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: 10), nameLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 7),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: updateBtn.leadingAnchor, constant: -8),
            statusLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor), statusLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            updateBtn.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16), updateBtn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    @objc private func toggleList(_ sender: NSSwitch) {
        guard let id = sender.identifier?.rawValue else { return }
        let isEnabled = sender.state == .on
        ContentBlockerManager.shared.setEnabled(isEnabled, forListID: id)
        updateButtons[id]?.isEnabled = isEnabled
        globalStatusLabel.stringValue = "\(ContentBlockerManager.shared.enabledCount()) lists enabled"
    }

    @objc private func updateSingleList(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        
        sender.isEnabled = false
        statusLabels[id]?.stringValue = "Downloading…"
        statusLabels[id]?.textColor = .tertiaryLabelColor
        progressIndicators[id]?.startAnimation(nil) // Spin
        
        ContentBlockerManager.shared.downloadAndCompile(listID: id) { [weak self] ok, reason in
            DispatchQueue.main.async {
                sender.isEnabled = true
                self?.progressIndicators[id]?.stopAnimation(nil) // Hide Spin
                
                if ok, let info = ContentBlockerManager.shared.lists.first(where: { $0.id == id }), let d = info.lastUpdated {
                    let fmt = DateFormatter(); fmt.dateStyle = .short; fmt.timeStyle = .short
                    self?.statusLabels[id]?.stringValue = "Updated: \(fmt.string(from: d))"
                    self?.statusLabels[id]?.textColor = .secondaryLabelColor
                } else {
                    self?.statusLabels[id]?.stringValue = "Failed — \(reason)"
                    self?.statusLabels[id]?.textColor = .systemRed
                }
            }
        }
    }

    @objc private func updateAllLists() {
        updateAllBtn.isEnabled = false
        globalStatusLabel.stringValue = "Updating all…"
        
        for (id, spinner) in progressIndicators {
            if ContentBlockerManager.shared.lists.first(where: { $0.id == id })?.enabled == true {
                spinner.startAnimation(nil)
                statusLabels[id]?.stringValue = "Downloading…"
                statusLabels[id]?.textColor = .tertiaryLabelColor
            }
        }

        ContentBlockerManager.shared.updateAll(progress: { [weak self] id, ok, reason in
            DispatchQueue.main.async {
                self?.progressIndicators[id]?.stopAnimation(nil)
                
                if ok, let info = ContentBlockerManager.shared.lists.first(where: { $0.id == id }), let d = info.lastUpdated {
                    let fmt = DateFormatter(); fmt.dateStyle = .short; fmt.timeStyle = .short
                    self?.statusLabels[id]?.stringValue = "Updated: \(fmt.string(from: d))"
                    self?.statusLabels[id]?.textColor = .secondaryLabelColor
                } else {
                    self?.statusLabels[id]?.stringValue = "Failed — \(reason)"
                    self?.statusLabels[id]?.textColor = .systemRed
                }
            }
        }) { [weak self] in
            self?.updateAllBtn.isEnabled = true
            self?.globalStatusLabel.stringValue = "\(ContentBlockerManager.shared.enabledCount()) lists enabled"
        }
    }

    // --- Scripts View Building ---
    private func buildScriptsView() {
        scriptsView = NSView(); scriptsView.translatesAutoresizingMaskIntoConstraints = false
        
        let contentStack = NSStackView(); contentStack.orientation = .vertical; contentStack.alignment = .leading; contentStack.spacing = 0
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        for meta in UserScriptManager.shared.scripts {
            let row = buildScriptRow(for: meta)
            contentStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            
            let sep = NSBox(); sep.boxType = .separator; sep.translatesAutoresizingMaskIntoConstraints = false
            contentStack.addArrangedSubview(sep)
            sep.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        let flipHost = FlippedView(); flipHost.translatesAutoresizingMaskIntoConstraints = false; flipHost.addSubview(contentStack)
        let scrollView = NSScrollView(); scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true; scrollView.autohidesScrollers = true; scrollView.drawsBackground = false; scrollView.documentView = flipHost

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: flipHost.topAnchor), contentStack.leadingAnchor.constraint(equalTo: flipHost.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: flipHost.trailingAnchor), contentStack.bottomAnchor.constraint(equalTo: flipHost.bottomAnchor),
            flipHost.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        let importBtn = NSButton(title: "Import .user.js…", target: self, action: #selector(importScript))
        importBtn.bezelStyle = .rounded
        let dirBtn = NSButton(title: "Open Folder", target: self, action: #selector(openScriptsFolder))
        dirBtn.bezelStyle = .inline
        
        let bottomBar = NSStackView(views: [dirBtn, importBtn])
        bottomBar.orientation = .horizontal; bottomBar.spacing = 12; bottomBar.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        
        let sep = NSBox(); sep.boxType = .separator
        
        let root = NSStackView(views: [scrollView, sep, bottomBar])
        root.orientation = .vertical; root.spacing = 0; root.translatesAutoresizingMaskIntoConstraints = false
        scriptsView.addSubview(root)
        NSLayoutConstraint.activate([ root.topAnchor.constraint(equalTo: scriptsView.topAnchor), root.bottomAnchor.constraint(equalTo: scriptsView.bottomAnchor),
                                      root.leadingAnchor.constraint(equalTo: scriptsView.leadingAnchor), root.trailingAnchor.constraint(equalTo: scriptsView.trailingAnchor),
                                      sep.widthAnchor.constraint(equalTo: root.widthAnchor), bottomBar.widthAnchor.constraint(equalTo: root.widthAnchor) ])
    }

    private func buildScriptRow(for meta: UserScriptMeta) -> NSView {
        let row = NSView(); row.translatesAutoresizingMaskIntoConstraints = false

        let toggle = NSSwitch(); toggle.state = meta.enabled ? .on : .off; toggle.target = self; toggle.action = #selector(toggleScript(_:))
        toggle.translatesAutoresizingMaskIntoConstraints = false; toggle.controlSize = .small
        toggle.identifier = NSUserInterfaceItemIdentifier(meta.filename)

        let nameLabel = NSTextField(labelWithString: meta.name); nameLabel.font = .systemFont(ofSize: 12, weight: .bold)
        nameLabel.lineBreakMode = .byTruncatingTail; nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let descLabel = NSTextField(labelWithString: meta.description); descLabel.font = .systemFont(ofSize: 10); descLabel.textColor = .secondaryLabelColor
        descLabel.lineBreakMode = .byTruncatingTail; descLabel.translatesAutoresizingMaskIntoConstraints = false

        let delBtn = NSButton(title: "Delete", target: self, action: #selector(deleteScript(_:))); delBtn.bezelStyle = .inline
        delBtn.controlSize = .small; delBtn.contentTintColor = .systemRed; delBtn.translatesAutoresizingMaskIntoConstraints = false
        delBtn.identifier = NSUserInterfaceItemIdentifier(meta.filename)

        row.addSubview(toggle); row.addSubview(nameLabel); row.addSubview(descLabel); row.addSubview(delBtn)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 48),
            toggle.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16), toggle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: 10), nameLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: delBtn.leadingAnchor, constant: -8),
            descLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor), descLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            descLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            delBtn.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16), delBtn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    @objc private func toggleScript(_ sender: NSSwitch) {
        guard let filename = sender.identifier?.rawValue else { return }
        UserScriptManager.shared.setEnabled(sender.state == .on, forFilename: filename)
    }

    @objc private func deleteScript(_ sender: NSButton) {
        guard let filename = sender.identifier?.rawValue else { return }
        let alert = NSAlert()
        alert.messageText = "Delete Script?"
        alert.informativeText = "Are you sure you want to permanently delete \(filename)?"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            UserScriptManager.shared.deleteScript(filename: filename)
            buildScriptsView()
            tabChanged(segmentedControl) 
        }
    }

    @objc private func importScript() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        
        if #available(macOS 11.0, *) {
            if let jsType = UTType(filenameExtension: "js") { panel.allowedContentTypes = [jsType] }
        } else {
            panel.allowedFileTypes = ["js"]
        }
        
        if panel.runModal() == .OK, let url = panel.url {
            UserScriptManager.shared.importScript(from: url)
            buildScriptsView()
            tabChanged(segmentedControl)
        }
    }

    @objc private func openScriptsFolder() {
        NSWorkspace.shared.open(UserScriptManager.shared.scriptsDir)
    }
}


// ==========================================
// 7. FAVICON MANAGER
// ==========================================
class FaviconManager {
    static let shared = FaviconManager()
    private var cache: [String: NSImage] = [:]

    func fetchExplicitFavicon(from iconURLString: String, forHost host: String, completion: @escaping (NSImage?) -> Void) {
        if let cached = cache[host] { completion(cached); return }
        guard let url = URL(string: iconURLString) else { completion(nil); return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5.0; request.setValue(safariUA, forHTTPHeaderField: "User-Agent")
        
        ProxyManager.shared.getURLSession().dataTask(with: request) { data, response, _ in
            if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode), let data = data, let original = NSImage(data: data) {
                original.size = NSSize(width: 14, height: 14)
                let roundedImage = NSImage(size: original.size)
                roundedImage.lockFocus()
                NSGraphicsContext.current?.imageInterpolation = .high
                let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: original.size), xRadius: 3, yRadius: 3)
                path.addClip()
                original.draw(in: NSRect(origin: .zero, size: original.size), from: .zero, operation: .sourceOver, fraction: 0.85)
                roundedImage.unlockFocus()
                DispatchQueue.main.async { self.cache[host] = roundedImage; completion(roundedImage) }
            } else { DispatchQueue.main.async { completion(nil) } }
        }.resume()
    }
}

// ==========================================
// 8. CUSTOM BROWSER WEBVIEW
// ==========================================
class BrowserWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        if let newWinItem = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" }) {
            newWinItem.title = "Open Link in New Tab"
        }
        let isLink = menu.items.contains(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopyLink" })
        if !isLink {
            if !menu.items.contains(where: { $0.title == "Save Page As…" }) {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                let saveItem = NSMenuItem(title: "Save Page As…", action: #selector(savePageAs), keyEquivalent: "")
                saveItem.target = self
                menu.addItem(saveItem)
            }
        }
    }
    @objc private func savePageAs() {
        if #available(macOS 11.0, *) {
            self.createWebArchiveData { result in
                if case .success(let data) = result {
                    DispatchQueue.main.async {
                        let savePanel = NSSavePanel()
                        let titleStr = (self.title?.isEmpty == false) ? self.title! : "Saved Page"
                        savePanel.nameFieldStringValue = "\(titleStr).webarchive"
                        if savePanel.runModal() == .OK, let url = savePanel.url { try? data.write(to: url) }
                    }
                }
            }
        }
    }

    @objc func performFindPanelAction(_ sender: Any?) {
        guard let win = self.window else { return }
        (NSApp.delegate as? AppDelegate)?.tab(for: win)?.showFindBar()
    }
}

// ==========================================
// 9. URL BAR
// ==========================================
class URLBar: NSTextField {
    var justGainedFocus = false; var alwaysShowFullURL = false; var onFocusChanged: ((Bool) -> Void)?
    private(set) var fullURL: String = ""
    private let cornerR: CGFloat = 10

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false; drawsBackground = false; usesSingleLineMode = true; cell?.isScrollable = true; lineBreakMode = .byClipping
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func drawFocusRingMask() {
        guard isEditable, let wrapper = superview else { return }
        let rect = convert(wrapper.bounds, from: wrapper)
        NSBezierPath(roundedRect: rect, xRadius: cornerR, yRadius: cornerR).fill()
    }
    override var focusRingMaskBounds: NSRect {
        guard let wrapper = superview else { return bounds }
        return convert(wrapper.bounds, from: wrapper)
    }

    override func becomeFirstResponder() -> Bool {
        guard isEditable else { return super.becomeFirstResponder() }
        onFocusChanged?(true)
        self.alignment = .left
        let ok = super.becomeFirstResponder()
        if ok {
            justGainedFocus = true
            if !fullURL.isEmpty { stringValue = fullURL }
            (currentEditor() as? NSTextView)?.alignment = .left
        }
        return ok
    }

    override func mouseDown(with event: NSEvent) {
        guard isEditable else { super.mouseDown(with: event); return }
        super.mouseDown(with: event)
        if justGainedFocus { currentEditor()?.selectAll(nil); justGainedFocus = false }
    }

    func displayIdleURL(_ urlStr: String) {
        fullURL = urlStr
        if alwaysShowFullURL { stringValue = urlStr; alignment = .left; return }
        alignment = .center
        if let host = URL(string: urlStr)?.host { stringValue = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host } 
        else { stringValue = urlStr.isEmpty ? "" : urlStr }
    }

    func clearForBlankPage() { fullURL = ""; stringValue = ""; alignment = .center }
}

struct ClosedTab { let url: String; let index: Int; let isPrivate: Bool; let sessionID: String? }

extension NSToolbarItem.Identifier {
    static let navigationControls = NSToolbarItem.Identifier("navigationControls")
    static let urlBar = NSToolbarItem.Identifier("urlBar")
    static let actionControls = NSToolbarItem.Identifier("actionControls")
}

// ==========================================
// 10. FIND BAR
// ==========================================
class FindBarView: NSView, NSTextFieldDelegate {
    let searchField = NSTextField()
    private let matchLabel = NSTextField(labelWithString: "")
    private let prevBtn = NSButton()
    private let nextBtn = NSButton()
    private let doneBtn = NSButton()

    var onSearch: ((String) -> Void)?
    var onPrev: (() -> Void)?
    var onNext: (() -> Void)?
    var onDone: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        let vev = NSVisualEffectView()
        vev.material = .popover
        vev.blendingMode = .behindWindow
        vev.state = .active
        vev.wantsLayer = true
        vev.layer?.cornerRadius = 8
        vev.layer?.masksToBounds = true
        vev.translatesAutoresizingMaskIntoConstraints = false
        addSubview(vev)
        NSLayoutConstraint.activate([
            vev.topAnchor.constraint(equalTo: topAnchor), vev.bottomAnchor.constraint(equalTo: bottomAnchor),
            vev.leadingAnchor.constraint(equalTo: leadingAnchor), vev.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        searchField.placeholderString = "Find…"
        searchField.bezelStyle = .roundedBezel
        searchField.font = .systemFont(ofSize: 13)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        matchLabel.font = .systemFont(ofSize: 12)
        matchLabel.textColor = .secondaryLabelColor
        matchLabel.alignment = .right
        matchLabel.isEditable = false; matchLabel.isBordered = false; matchLabel.drawsBackground = false
        matchLabel.translatesAutoresizingMaskIntoConstraints = false
        matchLabel.setContentHuggingPriority(.required, for: .horizontal)

        let iconCfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        prevBtn.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Previous")?.withSymbolConfiguration(iconCfg)
        prevBtn.isBordered = false; prevBtn.target = self; prevBtn.action = #selector(prevTapped)
        prevBtn.translatesAutoresizingMaskIntoConstraints = false

        nextBtn.image = NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: "Next")?.withSymbolConfiguration(iconCfg)
        nextBtn.isBordered = false; nextBtn.target = self; nextBtn.action = #selector(nextTapped)
        nextBtn.translatesAutoresizingMaskIntoConstraints = false

        doneBtn.title = "Done"
        if #available(macOS 14.0, *) { doneBtn.bezelStyle = .push } else { doneBtn.bezelStyle = .rounded }
        doneBtn.controlSize = .small
        doneBtn.target = self; doneBtn.action = #selector(doneTapped)
        doneBtn.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [searchField, matchLabel, prevBtn, nextBtn, doneBtn])
        stack.orientation = .horizontal; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateMatchLabel(current: Int, total: Int) {
        matchLabel.stringValue = total > 0 ? "\(current) of \(total)" : ""
        prevBtn.isEnabled = total > 0; nextBtn.isEnabled = total > 0
    }

    func focusSearchField() { window?.makeFirstResponder(searchField) }

    @objc private func prevTapped() { onPrev?() }
    @objc private func nextTapped() { onNext?() }
    @objc private func doneTapped() { onDone?() }

    func controlTextDidChange(_ obj: Notification) { onSearch?(searchField.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSStandardKeyBindingResponding.insertNewline(_:)) { onNext?(); return true }
        if sel == #selector(NSStandardKeyBindingResponding.cancelOperation(_:)) { onDone?(); return true }
        return false
    }
}

class FindBarMessageHandler: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?
    init(_ tab: BrowserTab) { self.tab = tab; super.init() }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String, let tab = tab else { return }
        DispatchQueue.main.async {
            switch body {
            case "show": tab.showFindBar()
            case "next": tab.isFindBarVisible ? tab.navigateMatch(forward: true) : tab.showFindBar()
            case "prev": tab.isFindBarVisible ? tab.navigateMatch(forward: false) : tab.showFindBar()
            case "escape": if tab.isFindBarVisible { tab.hideFindBar() }
            default: break
            }
        }
    }
}

// ==========================================
// 11. BROWSER TAB
// ==========================================
class BrowserTab: NSObject, NSTextFieldDelegate, WKNavigationDelegate, WKUIDelegate,
                  WKDownloadDelegate, NSWindowDelegate, NSToolbarDelegate {

    var window: NSWindow!; var webView: BrowserWebView!; var urlField: URLBar!; var downloadBtn: NSButton!
    private var rootContainer: NSView!; private var blurView: NSVisualEffectView?; private var solidBackgroundBox: NSBox?
    let isPrivate: Bool; let isPopup: Bool; let sessionID: String?
    weak var openerWindow: NSWindow? 

    var urlObserver: NSKeyValueObservation?; var titleObserver: NSKeyValueObservation?
    var progressObserver: NSKeyValueObservation?; var loadingObserver: NSKeyValueObservation?
    private var currentFavicon: NSImage?
    private var isSplashVisible = false
    private var splashOverlay: NSView?
    private var findBar: FindBarView?
    private var findMatchCount = 0
    private var findCurrentIndex = 0
    private var findBarHandler: FindBarMessageHandler?
    private var isFindBarHandlerRegistered = false
    var isFindBarVisible: Bool { !(findBar?.isHidden ?? true) }
    // Tracks which UCC instances have "findBar" registered, including those
    // inherited by popup/new tabs whose isFindBarHandlerRegistered starts false.
    private static let findBarRegisteredUCCs = NSHashTable<WKUserContentController>.weakObjects()
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]; private var downloadPartURLs: [ObjectIdentifier: URL] = [:]

    private var leftGroup: NSStackView!; private var pillWrapper: PillWrapperView!; private var pillIcon: NSImageView!
    private var urlLeadingToIcon: NSLayoutConstraint!; private var urlLeadingToPill: NSLayoutConstraint!
    private var rightGroup: NSStackView!; private var backBtn: ToolbarButton!; private var fwdBtn: ToolbarButton!

    private let uaScript = WKUserScript(source: """
    (function() {
        var host = window.location.hostname;
        var isDiscord = (host === 'discord.com' || host.endsWith('.discord.com'));
        
        var ua = isDiscord ? '\(discordUA)' : '\(safariUA)';
        var appVer = isDiscord 
            ? '5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15'
            : '5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15';
            
        try {
            Object.defineProperty(navigator, 'userAgent',   { get: function(){ return ua; }, configurable: true });
            Object.defineProperty(navigator, 'appVersion',  { get: function(){ return appVer; }, configurable: true });
            Object.defineProperty(navigator, 'vendor',      { get: function(){ return 'Apple Computer, Inc.'; }, configurable: true });
            Object.defineProperty(navigator, 'platform',    { get: function(){ return 'MacIntel'; }, configurable: true });
        } catch(e) {}
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

    private let ytAdSkipScript = WKUserScript(source: """
    setInterval(function() {
        // 1. Only run this on YouTube
        if (!window.location.hostname.includes('youtube.com')) return;

        var skipBtn = document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button');
        var adShowing = document.querySelector('.ad-showing');
        var video = document.querySelector('video');

        // 2. If the native skip button is clickable, click it
        if (skipBtn) { 
            skipBtn.click(); 
            return; 
        }

        // 3. Unskippable ad handling
        if (adShowing && video) {
            // Mute the ad and make it play 16x faster
            video.muted = true;
            video.playbackRate = 16.0;

            // Jump to 0.5 seconds before the end. 
            // This allows YouTube's own scripts to detect the end of the ad normally and avoids crashing the player.
            if (!isNaN(video.duration) && video.currentTime < video.duration - 0.5) {
                video.currentTime = video.duration - 0.5;
            }
        }
    }, 250);
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

    private static let findBarInterceptSource = """
    (function(){
        window.addEventListener('keydown', function(e){
            if((e.metaKey||e.ctrlKey)&&!e.altKey){
                var k=(e.key||'').toLowerCase();
                if(k==='f'&&!e.shiftKey&&!e.defaultPrevented){
                    e.preventDefault();
                    try{webkit.messageHandlers.findBar.postMessage('show');}catch(_){}
                    return false;
                }
                if(k==='g'&&!e.defaultPrevented){
                    e.preventDefault();
                    try{webkit.messageHandlers.findBar.postMessage(e.shiftKey?'prev':'next');}catch(_){}
                    return false;
                }
            }
            if(e.key==='Escape'&&!e.metaKey&&!e.ctrlKey){
                try{webkit.messageHandlers.findBar.postMessage('escape');}catch(_){}
            }
        }, false);
    })();
    """

    init(parentWindow: NSWindow?, isPrivate: Bool, sessionID: String? = nil, dataStore: WKWebsiteDataStore? = nil,
         configuration: WKWebViewConfiguration? = nil, targetIndex: Int? = nil, focusURL: Bool = true,
         showSplash: Bool = true, isPopup: Bool = false) {

        self.isPrivate = isPrivate; self.sessionID = sessionID; self.openerWindow = parentWindow; self.isPopup = isPopup
        super.init()

        window = NSWindow(contentRect: NSMakeRect(0, 0, 1200, 800), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 450, height: 250); window.titleVisibility = .hidden 
        window.isMovableByWindowBackground = true; window.center(); window.isReleasedWhenClosed = false
        window.tabbingMode = isPopup ? .disallowed : .automatic
        
        if let parent = parentWindow, !isPopup { window.tabbingIdentifier = parent.tabbingIdentifier } 
        else { window.tabbingIdentifier = isPrivate ? "private-\(UUID().uuidString)" : "standard-\(UUID().uuidString)" }
        
        window.title = isPrivate ? "🔒 SwiftBrowse" : "SwiftBrowse"
        if parentWindow == nil && !isPopup { window.setFrameAutosaveName("SwiftBrowseMainWindow") }
        window.delegate = self

        backBtn = ToolbarButton(symbol: "chevron.left", tooltip: "Back", target: self, action: #selector(goBack))
        fwdBtn = ToolbarButton(symbol: "chevron.right", tooltip: "Forward", target: self, action: #selector(goForward))
        let reloadBtn = ToolbarButton(symbol: "arrow.clockwise", tooltip: "Reload", target: self, action: #selector(reload))
        backBtn.isEnabled = false; fwdBtn.isEnabled = false
        leftGroup = NSStackView(views: [backBtn, fwdBtn, reloadBtn]); leftGroup.orientation = .horizontal; leftGroup.spacing = 8; leftGroup.translatesAutoresizingMaskIntoConstraints = false

        let newTabBtn = ToolbarButton(symbol: "plus", tooltip: "New Tab", target: NSApp.delegate, action: #selector(AppDelegate.createNewTab))
        let shieldBtn = ToolbarButton(symbol: "gearshape.fill", tooltip: "Settings", target: NSApp.delegate, action: #selector(AppDelegate.openSettings))
        let dlBtn = ToolbarButton(symbol: "arrow.down.circle", tooltip: "Downloads", target: self, action: #selector(toggleDownloads))
        downloadBtn = dlBtn
        rightGroup = NSStackView(views: [newTabBtn, shieldBtn, dlBtn]); rightGroup.orientation = .horizontal; rightGroup.spacing = 8; rightGroup.translatesAutoresizingMaskIntoConstraints = false

        urlField = URLBar(); urlField.delegate = self; urlField.font = .systemFont(ofSize: 13); urlField.alignment = .center; urlField.translatesAutoresizingMaskIntoConstraints = false
        
        if isPopup { urlField.isEditable = false; urlField.isSelectable = true; urlField.alwaysShowFullURL = true; urlField.textColor = .labelColor }
        
        let placeholderText = isPrivate ? "Search privately…" : "Search or enter website name…"
        let searchIconCfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        if let searchImg = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(searchIconCfg) {
            let att = NSTextAttachment(); att.image = searchImg; att.bounds = NSRect(x: 0, y: -1.5, width: 14, height: 14)
            let attrPlaceholder = NSMutableAttributedString(attachment: att)
            attrPlaceholder.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: attrPlaceholder.length))
            let style = NSMutableParagraphStyle(); style.alignment = .center
            attrPlaceholder.append(NSAttributedString(string: "  " + placeholderText, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor, .paragraphStyle: style]))
            attrPlaceholder.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: attrPlaceholder.length))
            urlField.placeholderAttributedString = attrPlaceholder
        } else { urlField.placeholderString = placeholderText }

        pillWrapper = PillWrapperView(); pillWrapper.translatesAutoresizingMaskIntoConstraints = false
        pillIcon = NSImageView(); pillIcon.translatesAutoresizingMaskIntoConstraints = false; pillIcon.imageScaling = .scaleProportionallyUpOrDown; pillIcon.isHidden = true
        
        pillWrapper.addSubview(pillIcon); pillWrapper.addSubview(urlField)
        
        urlLeadingToIcon = urlField.leadingAnchor.constraint(equalTo: pillIcon.trailingAnchor, constant: 5)
        urlLeadingToPill = urlField.leadingAnchor.constraint(equalTo: pillWrapper.leadingAnchor, constant: 10)
        urlLeadingToIcon.isActive = false; urlLeadingToPill.isActive = true

        NSLayoutConstraint.activate([
            pillWrapper.heightAnchor.constraint(equalToConstant: 32),
            pillIcon.leadingAnchor.constraint(equalTo: pillWrapper.leadingAnchor, constant: 10), pillIcon.centerYAnchor.constraint(equalTo: pillWrapper.centerYAnchor),
            pillIcon.widthAnchor.constraint(equalToConstant: 14), pillIcon.heightAnchor.constraint(equalToConstant: 14),
            urlField.centerYAnchor.constraint(equalTo: pillWrapper.centerYAnchor), urlField.trailingAnchor.constraint(equalTo: pillWrapper.trailingAnchor, constant: -10),
        ])
        
        urlField.onFocusChanged = { [weak self] focused in if focused { self?.showEditingIcon() } }

        if !isPopup {
            pillWrapper.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
            let idealWidth = pillWrapper.widthAnchor.constraint(equalToConstant: 600)
            idealWidth.priority = .defaultLow; idealWidth.isActive = true
        }

        if !isPopup {
            let toolbar = NSToolbar(identifier: "BrowserToolbar"); toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.centeredItemIdentifier = .urlBar
            window.toolbar = toolbar; window.toolbarStyle = .unified

            let navMenu = NSMenu()
            let newTabItem = NSMenuItem(title: "New Tab", action: #selector(AppDelegate.createNewTab), keyEquivalent: "")
            newTabItem.target = NSApp.delegate; navMenu.addItem(newTabItem)
            let newWinItem = NSMenuItem(title: "New Window", action: #selector(AppDelegate.createNewWindow), keyEquivalent: "")
            newWinItem.target = NSApp.delegate; navMenu.addItem(newWinItem)
            let newPrivItem = NSMenuItem(title: "New Private Window", action: #selector(AppDelegate.createPrivateWindow), keyEquivalent: "")
            newPrivItem.target = NSApp.delegate; navMenu.addItem(newPrivItem)
            navMenu.addItem(.separator())
            let reloadItem = NSMenuItem(title: "Reload", action: #selector(reload), keyEquivalent: "")
            reloadItem.target = self; navMenu.addItem(reloadItem)
            let dlItem = NSMenuItem(title: "Downloads", action: #selector(toggleDownloads), keyEquivalent: "")
            dlItem.target = self; navMenu.addItem(dlItem)
            navMenu.addItem(.separator())
            let settingsItem = NSMenuItem(title: "Settings…", action: #selector(AppDelegate.openSettings), keyEquivalent: "")
            settingsItem.target = NSApp.delegate; navMenu.addItem(settingsItem)

            DispatchQueue.main.async {
                if let themeFrame = self.window.contentView?.superview { self.overrideToolbarMenu(view: themeFrame, menu: navMenu) }
            }
        } else { window.titleVisibility = .visible }

        let config = configuration ?? {
            let c = WKWebViewConfiguration()
            if isPrivate { c.websiteDataStore = dataStore ?? .nonPersistent() }
            ProxyManager.shared.apply(to: c.websiteDataStore)
            ContentBlockerManager.shared.apply(to: c.userContentController)
            c.websiteDataStore.httpCookieStore.setCookiePolicy(.allow) { }
            c.preferences.setValue(true, forKey: "developerExtrasEnabled")
            if #available(macOS 12.3, *) {
                c.preferences.isElementFullscreenEnabled = true
            } else {
                c.preferences.setValue(true, forKey: "fullScreenEnabled")
            }
            return c
        }()

        webView = BrowserWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self; webView.uiDelegate = self; webView.allowsBackForwardNavigationGestures = true; webView.customUserAgent = safariUA
        if #available(macOS 13.3, *) { webView.isInspectable = true }

        // Setup unified scripts pipeline (UA, UserScripts)
        setupUserScripts()

        rootContainer = NSView()
        var popupTopBar: NSView?
        if isPopup {
            let bar = NSView(); bar.translatesAutoresizingMaskIntoConstraints = false; bar.wantsLayer = true
            bar.layer?.backgroundColor = isPrivate ? NSColor(calibratedWhite: 0.12, alpha: 1.0).cgColor : NSColor.windowBackgroundColor.cgColor
            let sep = NSBox(); sep.boxType = .custom; sep.borderWidth = 0; sep.fillColor = isPrivate ? NSColor(calibratedWhite: 0.2, alpha: 1.0) : NSColor.separatorColor; sep.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(pillWrapper); bar.addSubview(sep)
            NSLayoutConstraint.activate([
                pillWrapper.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12), pillWrapper.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
                pillWrapper.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
                sep.leadingAnchor.constraint(equalTo: bar.leadingAnchor), sep.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                sep.bottomAnchor.constraint(equalTo: bar.bottomAnchor), sep.heightAnchor.constraint(equalToConstant: 1)
            ])
            popupTopBar = bar; rootContainer.addSubview(bar)
        }
        
        if isPrivate { window.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1.0) } 
        else {
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
            let bv = NSVisualEffectView(); bv.material = .underWindowBackground; bv.blendingMode = .behindWindow; bv.state = .active; bv.translatesAutoresizingMaskIntoConstraints = false
            rootContainer.addSubview(bv); self.blurView = bv
            let sb = NSBox(); sb.boxType = .custom; sb.borderWidth = 0; sb.fillColor = .windowBackgroundColor; sb.alphaValue = 0.0; sb.translatesAutoresizingMaskIntoConstraints = false
            rootContainer.addSubview(sb); self.solidBackgroundBox = sb
            webView.setValue(false, forKey: "drawsBackground")
            let anchorTop = popupTopBar?.bottomAnchor ?? rootContainer.topAnchor
            NSLayoutConstraint.activate([
                bv.topAnchor.constraint(equalTo: anchorTop), bv.bottomAnchor.constraint(equalTo: rootContainer.bottomAnchor),
                bv.leadingAnchor.constraint(equalTo: rootContainer.leadingAnchor), bv.trailingAnchor.constraint(equalTo: rootContainer.trailingAnchor),
                sb.topAnchor.constraint(equalTo: anchorTop), sb.bottomAnchor.constraint(equalTo: rootContainer.bottomAnchor),
                sb.leadingAnchor.constraint(equalTo: rootContainer.leadingAnchor), sb.trailingAnchor.constraint(equalTo: rootContainer.trailingAnchor)
            ])
        }
        
        webView.translatesAutoresizingMaskIntoConstraints = false; rootContainer.addSubview(webView)
        let webViewTopAnchor = popupTopBar?.bottomAnchor ?? rootContainer.topAnchor
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: webViewTopAnchor), webView.bottomAnchor.constraint(equalTo: rootContainer.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: rootContainer.leadingAnchor), webView.trailingAnchor.constraint(equalTo: rootContainer.trailingAnchor)
        ])
        
        // Native Splash View to avoid WebKit HTML render flashes entirely
        let splash = NSView(); splash.translatesAutoresizingMaskIntoConstraints = false
        splash.wantsLayer = true
        splash.layer?.backgroundColor = isPrivate ? NSColor(calibratedWhite: 0.12, alpha: 1.0).cgColor : NSColor.clear.cgColor
        splash.isHidden = true
        
        let titleLabel = NSTextField(labelWithString: "SwiftBrowse")
        titleLabel.font = .systemFont(ofSize: 48, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.isEditable = false; titleLabel.isBordered = false; titleLabel.drawsBackground = false
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        let subtitleLabel = NSTextField(labelWithString: isPrivate ? "Private session active — no history will be saved." : "Ready for unmanaged execution.")
        subtitleLabel.font = .systemFont(ofSize: 16)
        subtitleLabel.textColor = NSColor(calibratedWhite: 0.62, alpha: 1.0)
        subtitleLabel.isEditable = false; subtitleLabel.isBordered = false; subtitleLabel.drawsBackground = false
        subtitleLabel.alignment = .center
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        splash.addSubview(titleLabel); splash.addSubview(subtitleLabel)
        
        rootContainer.addSubview(splash)
        NSLayoutConstraint.activate([
            splash.topAnchor.constraint(equalTo: webViewTopAnchor), splash.bottomAnchor.constraint(equalTo: rootContainer.bottomAnchor),
            splash.leadingAnchor.constraint(equalTo: rootContainer.leadingAnchor), splash.trailingAnchor.constraint(equalTo: rootContainer.trailingAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: splash.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: splash.centerYAnchor, constant: -20),
            subtitleLabel.centerXAnchor.constraint(equalTo: splash.centerXAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10)
        ])
        self.splashOverlay = splash
        
        if let topBar = popupTopBar {
            NSLayoutConstraint.activate([
                topBar.topAnchor.constraint(equalTo: rootContainer.topAnchor), topBar.leadingAnchor.constraint(equalTo: rootContainer.leadingAnchor),
                topBar.trailingAnchor.constraint(equalTo: rootContainer.trailingAnchor), topBar.heightAnchor.constraint(equalToConstant: 44) 
            ])
        }

        window.contentView = rootContainer

        urlObserver = webView.observe(\.url, options: .new) { [weak self] wv, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let urlStr = wv.url?.absoluteString ?? ""
                let isBlank = urlStr.isEmpty || urlStr.starts(with: "about:blank")
                
                if !self.isPrivate {
                    if isBlank {
                        // Returning to blank/splash — restore transparent mode
                        self.window.isOpaque = false; self.window.backgroundColor = .clear
                        self.blurView?.isHidden = false; self.solidBackgroundBox?.isHidden = false
                        self.solidBackgroundBox?.alphaValue = 0.0
                        self.webView.setValue(false, forKey: "drawsBackground")
                    } else {
                        // Navigating to a real page — go fully opaque
                        self.webView.setValue(true, forKey: "drawsBackground")
                        self.window.isOpaque = true; self.window.backgroundColor = .windowBackgroundColor
                        self.blurView?.isHidden = true; self.solidBackgroundBox?.isHidden = true
                    }
                }
                
                if wv.url?.host != URL(string: self.urlField.fullURL)?.host { self.currentFavicon = nil }
                self.syncTabTitleAndIcon()
                
                if isBlank { return }
                
                let isEditing = self.window.firstResponder is NSTextView && self.window.firstResponder === self.urlField.currentEditor()
                if !isEditing { self.urlField.displayIdleURL(urlStr); self.hideEditingIcon() }
                if !self.isPrivate { HistoryManager.shared.addVisit(urlStr) }
                self.backBtn.isEnabled = wv.canGoBack; self.fwdBtn.isEnabled = wv.canGoForward
            }
        }

        titleObserver = webView.observe(\.title, options: .new) { [weak self] wv, _ in
            guard let self else { return }
            let t = wv.title?.isEmpty == false ? wv.title! : "SwiftBrowse"
            self.window.title = self.isPrivate ? "🔒 \(t)" : t
            self.syncTabTitleAndIcon()
            if let urlStr = wv.url?.absoluteString, !urlStr.starts(with: "about:blank") { self.updateFavicon() }
        }

        progressObserver = webView.observe(\.estimatedProgress, options: .new) { [weak self] wv, _ in
            DispatchQueue.main.async {
                let urlStr = wv.url?.absoluteString ?? ""
                if !(urlStr.isEmpty || urlStr.starts(with: "about:blank")) { self?.pillWrapper.progress = max(0.1, wv.estimatedProgress) }
            }
        }

        loadingObserver = webView.observe(\.isLoading, options: .new) { [weak self] wv, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let urlStr = wv.url?.absoluteString ?? ""
                let isBlank = urlStr.isEmpty || urlStr.starts(with: "about:blank")
                
                if self.isPopup && !isBlank { self.urlField.displayIdleURL(urlStr) }
                
                if wv.isLoading {
                    if !isBlank {
                        if wv.estimatedProgress < 0.1 { self.pillWrapper.progress = 0.1 }
                        self.pillWrapper.showProgress = true
                    }
                } else {
                    if !isBlank { self.pillWrapper.progress = 1.0; self.updateFavicon() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        if !self.webView.isLoading { self.pillWrapper.showProgress = false }
                    }
                }
            }
        }

        if let parent = parentWindow, !isPopup {
            let existing = parent.tabGroup?.windows ?? [parent]
            if let index = targetIndex, index < existing.count { existing[index].addTabbedWindow(window, ordered: .above) } 
            else { (existing.last ?? parent).addTabbedWindow(window, ordered: .above) }
        } else { if showSplash { window.makeKeyAndOrderFront(nil) } }

        DispatchQueue.main.async {
            self.syncTabTitleAndIcon()
            if let initialURL = self.webView.url?.absoluteString, !initialURL.isEmpty, !initialURL.starts(with: "about:blank") { self.urlField.displayIdleURL(initialURL) }
            if focusURL && !isPopup { self.window.makeKeyAndOrderFront(nil); self.window.makeFirstResponder(self.urlField); self.urlField.currentEditor()?.selectAll(nil) }
        }
        
        if showSplash && !isPopup { showSplashPage() } 
        else {
            if !isPrivate {
                window.isOpaque = true; window.backgroundColor = .windowBackgroundColor
                blurView?.isHidden = true; solidBackgroundBox?.isHidden = true
                webView.setValue(true, forKey: "drawsBackground")
            }
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(setupUserScripts), name: .reloadBrowserScripts, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applyProxySettings), name: .proxySettingsChanged, object: nil)
    }
    
    @objc func applyProxySettings() {
        ProxyManager.shared.apply(to: webView.configuration.websiteDataStore)
    }
    
    @objc func setupUserScripts() {
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        // Remove existing "findBar" handler — covers both re-entrant calls on this tab
        // and popup tabs that inherit a parent UCC which already has it registered.
        if isFindBarHandlerRegistered || BrowserTab.findBarRegisteredUCCs.contains(ucc) {
            if #available(macOS 11.0, *) {
                ucc.removeScriptMessageHandler(forName: "findBar", contentWorld: .page)
            } else {
                ucc.removeScriptMessageHandler(forName: "findBar")
            }
            isFindBarHandlerRegistered = false
            BrowserTab.findBarRegisteredUCCs.remove(ucc)
        }
        ucc.addUserScript(self.uaScript)
        ucc.addUserScript(self.ytAdSkipScript)
        if !isPopup {
            if findBarHandler == nil { findBarHandler = FindBarMessageHandler(self) }
            let src = BrowserTab.findBarInterceptSource
            if #available(macOS 11.0, *) {
                ucc.add(findBarHandler!, contentWorld: .page, name: "findBar")
                ucc.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
            } else {
                ucc.add(findBarHandler!, name: "findBar")
                ucc.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            }
            isFindBarHandlerRegistered = true
            BrowserTab.findBarRegisteredUCCs.add(ucc)
        }
        UserScriptManager.shared.injectScripts(into: ucc)
    }

    // MARK: - Find in Page

    func showFindBar() {
        if findBar == nil {
            let bar = FindBarView()
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.onSearch = { [weak self] q in self?.performSearch(q) }
            bar.onNext   = { [weak self] in self?.navigateMatch(forward: true) }
            bar.onPrev   = { [weak self] in self?.navigateMatch(forward: false) }
            bar.onDone   = { [weak self] in self?.hideFindBar() }
            rootContainer.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.trailingAnchor.constraint(equalTo: rootContainer.trailingAnchor, constant: -16),
                bar.topAnchor.constraint(equalTo: rootContainer.topAnchor, constant: 10),
                bar.heightAnchor.constraint(equalToConstant: 38),
                bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 340)
            ])
            findBar = bar
        }
        findBar?.isHidden = false
        DispatchQueue.main.async { [weak self] in self?.findBar?.focusSearchField() }
        if let q = findBar?.searchField.stringValue, !q.isEmpty { performSearch(q) }
    }

    func hideFindBar() {
        findBar?.isHidden = true
        findMatchCount = 0; findCurrentIndex = 0
        findBar?.updateMatchLabel(current: 0, total: 0)
        webView.evaluateJavaScript("window._swbFind && window._swbFind.clear()", completionHandler: nil)
        window.makeFirstResponder(webView)
    }

    private func performSearch(_ query: String) {
        guard !query.isEmpty else {
            findMatchCount = 0; findCurrentIndex = 0
            findBar?.updateMatchLabel(current: 0, total: 0)
            webView.evaluateJavaScript("window._swbFind && window._swbFind.clear()", completionHandler: nil)
            return
        }
        let esc = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        let js = """
        (function(){
          var C='_swb_';
          function escRe(s){return s.replace(/[.*+?^${}()|[\\]\\\\]/g,'\\\\$&');}
          if(!window._swbFind){
            window._swbFind={
              count:0,current:-1,
              search:function(q){
                this.clear();
                if(!q)return{count:0,current:-1};
                var re=new RegExp(escRe(q),'gi');
                var walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,{
                  acceptNode:function(n){
                    var t=n.parentElement?n.parentElement.tagName:'';
                    if(t==='SCRIPT'||t==='STYLE'||t==='NOSCRIPT')return NodeFilter.FILTER_REJECT;
                    return NodeFilter.FILTER_ACCEPT;
                  }
                });
                var nodes=[],n;
                while((n=walker.nextNode()))nodes.push(n);
                var cnt=0;
                nodes.forEach(function(n){
                  var text=n.textContent;
                  if(!re.test(text)){re.lastIndex=0;return;}
                  re.lastIndex=0;
                  var frag=document.createDocumentFragment(),last=0,m;
                  while((m=re.exec(text))!==null){
                    if(m.index>last)frag.appendChild(document.createTextNode(text.slice(last,m.index)));
                    var mark=document.createElement('mark');
                    mark.className=C;mark.dataset.i=cnt++;
                    mark.style.cssText='background:#FFE55C!important;color:inherit!important;border-radius:2px;';
                    mark.textContent=m[0];frag.appendChild(mark);last=re.lastIndex;
                  }
                  if(last<text.length)frag.appendChild(document.createTextNode(text.slice(last)));
                  n.parentNode.replaceChild(frag,n);
                });
                this.count=cnt;this.current=cnt>0?0:-1;
                if(cnt>0)this._scrollTo(0);
                return{count:cnt,current:this.current};
              },
              next:function(){
                if(!this.count)return{count:0,current:-1};
                this.current=(this.current+1)%this.count;
                this._scrollTo(this.current);
                return{count:this.count,current:this.current};
              },
              prev:function(){
                if(!this.count)return{count:0,current:-1};
                this.current=((this.current-1)%this.count+this.count)%this.count;
                this._scrollTo(this.current);
                return{count:this.count,current:this.current};
              },
              _scrollTo:function(i){
                var marks=document.querySelectorAll('mark.'+C);
                marks.forEach(function(m){m.style.background='#FFE55C!important';});
                if(i>=0&&i<marks.length){
                  marks[i].style.background='#FF9500!important';
                  marks[i].scrollIntoView({block:'center',behavior:'smooth'});
                }
              },
              clear:function(){
                document.querySelectorAll('mark.'+C).forEach(function(m){
                  var p=m.parentNode;
                  while(m.firstChild)p.insertBefore(m.firstChild,m);
                  p.removeChild(m);p.normalize();
                });
                this.count=0;this.current=-1;
              }
            };
          }
          return JSON.stringify(window._swbFind.search("\(esc)"));
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, let json = result as? String,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let count = obj["count"] as? Int, let current = obj["current"] as? Int else { return }
            self.findMatchCount = count; self.findCurrentIndex = current
            DispatchQueue.main.async {
                self.findBar?.updateMatchLabel(current: count > 0 ? current + 1 : 0, total: count)
            }
        }
    }

    func navigateMatch(forward: Bool) {
        let js = "window._swbFind ? JSON.stringify(window._swbFind.\(forward ? "next" : "prev")()) : '{\"count\":0,\"current\":-1}'"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, let json = result as? String,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let count = obj["count"] as? Int, let current = obj["current"] as? Int, count > 0 else { return }
            self.findCurrentIndex = current
            DispatchQueue.main.async { self.findBar?.updateMatchLabel(current: current + 1, total: count) }
        }
    }

    private func updateFavicon() {
        guard let urlStr = webView.url?.absoluteString, !urlStr.isEmpty, !urlStr.starts(with: "about:blank"), let host = webView.url?.host else { return }
        let js = "(() => { var links = document.querySelectorAll('link[rel=\"apple-touch-icon\"], link[rel~=\"icon\"], link[rel=\"shortcut icon\"]'); for (var i = 0; i < links.length; i++) { if (links[i].href) return links[i].href; } return window.location.origin + '/favicon.ico'; })();"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self, let iconUrlStr = result as? String else { return }
            FaviconManager.shared.fetchExplicitFavicon(from: iconUrlStr, forHost: host) { image in
                self.currentFavicon = image; self.syncTabTitleAndIcon()
                let isEditing = self.window.firstResponder is NSTextView && self.window.firstResponder === self.urlField.currentEditor()
                if isEditing { self.showEditingIcon() }
            }
        }
    }
    
    private func syncTabTitleAndIcon() {
        let t = window.title; let tab = window.tab 
        let textAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.labelColor]
        if let img = currentFavicon {
            let attachment = NSTextAttachment(); attachment.image = img; attachment.bounds = NSRect(x: 0, y: -2, width: 14, height: 14)
            let attrStr = NSMutableAttributedString(attachment: attachment)
            attrStr.append(NSAttributedString(string: "  " + t, attributes: textAttrs))
            tab.attributedTitle = attrStr
        } else { tab.attributedTitle = NSAttributedString(string: t, attributes: textAttrs) }
    }
    
    private func showEditingIcon() {
        let iconCfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let urlStr = webView.url?.absoluteString ?? ""
        let isBlank = urlStr.isEmpty || urlStr.starts(with: "about:blank")
        
        if isBlank { pillIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(iconCfg); pillIcon.contentTintColor = .secondaryLabelColor } 
        else if let fav = currentFavicon { pillIcon.image = fav; pillIcon.contentTintColor = nil } 
        else { pillIcon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?.withSymbolConfiguration(iconCfg); pillIcon.contentTintColor = .secondaryLabelColor }
        
        pillIcon.isHidden = false; urlLeadingToPill.isActive = false; urlLeadingToIcon.isActive = true
        urlField.placeholderAttributedString = nil; urlField.placeholderString = isPrivate ? "Search privately…" : "Search or enter website name…"
        pillWrapper.needsLayout = true
    }
    
    private func hideEditingIcon() {
        pillIcon.isHidden = true; urlLeadingToIcon.isActive = false; urlLeadingToPill.isActive = true
        let placeholderText = isPrivate ? "Search privately…" : "Search or enter website name…"
        let searchIconCfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        if let searchImg = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(searchIconCfg) {
            let att = NSTextAttachment(); att.image = searchImg; att.bounds = NSRect(x: 0, y: -1.5, width: 14, height: 14)
            let attrPlaceholder = NSMutableAttributedString(attachment: att)
            attrPlaceholder.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: attrPlaceholder.length))
            let style = NSMutableParagraphStyle(); style.alignment = .center
            attrPlaceholder.append(NSAttributedString(string: "  " + placeholderText, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor, .paragraphStyle: style]))
            attrPlaceholder.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: attrPlaceholder.length))
            urlField.placeholderAttributedString = attrPlaceholder
        }
        pillWrapper.needsLayout = true
    }

    private func overrideToolbarMenu(view: NSView, menu: NSMenu) {
        let typeName = String(describing: type(of: view))
        if typeName.contains("Toolbar") || typeName.contains("Titlebar") { view.menu = menu }
        for subview in view.subviews { if subview is URLBar { continue }; overrideToolbarMenu(view: subview, menu: menu) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        if isPopup { return [.urlBar] }
        return [.navigationControls, .urlBar, .actionControls, .flexibleSpace, .space]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        if isPopup { return [.urlBar] }
        return [.navigationControls, .flexibleSpace, .urlBar, .flexibleSpace, .actionControls]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case .navigationControls: item.view = leftGroup
        case .urlBar: item.view = pillWrapper
        case .actionControls: item.view = rightGroup
        default: return nil
        }
        return item
    }

    func showSplashPage() {
        isSplashVisible = true
        splashOverlay?.isHidden = false
        urlField.clearForBlankPage()
        if !isPrivate {
            window.isOpaque = false; window.backgroundColor = .clear
            webView.setValue(false, forKey: "drawsBackground")
            blurView?.isHidden = false; solidBackgroundBox?.isHidden = false; solidBackgroundBox?.alphaValue = 0.0
        }
    }

    func windowWillClose(_ notification: Notification) {
        let app = NSApplication.shared.delegate as! AppDelegate
        if let url = webView.url?.absoluteString, let group = window.tabGroup, let idx = group.windows.firstIndex(of: window) {
            app.closedTabs.append(ClosedTab(url: url, index: idx, isPrivate: isPrivate, sessionID: sessionID))
        }
        
        let isSelected = (window.tabGroup?.selectedWindow == window) || window.tabGroup == nil
        let opener = self.openerWindow
        let closedImmediately = webView.backForwardList.backList.isEmpty
        
        urlObserver = nil; titleObserver = nil; progressObserver = nil; loadingObserver = nil
        NotificationCenter.default.removeObserver(self)
        window.delegate = nil; webView.navigationDelegate = nil; webView.uiDelegate = nil
        let target = self.window
        
        DispatchQueue.main.async {
            app.tabs.removeAll { $0.window == target }
            if let sid = self.sessionID { if !app.tabs.contains(where: { $0.sessionID == sid }) { app.privateStores.removeValue(forKey: sid) } }
            if isSelected, let o = opener, o.isVisible, closedImmediately { o.makeKeyAndOrderFront(nil) }
        }
    }

    @objc func goBack() { if webView.canGoBack { webView.goBack() } }
    @objc func goForward() { if webView.canGoForward { webView.goForward() } }
    @objc func reload() { webView.reload() }
    @objc func toggleDownloads() { DownloadManager.shared.show(relativeTo: downloadBtn) }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let editor = field.currentEditor() as? NSTextView else { return }
        guard window.currentEvent?.keyCode != 51 else { return }
        let input = field.stringValue
        if let sug = HistoryManager.shared.suggest(for: input) {
            let tail = sug.dropFirst(input.count)
            field.stringValue = input + tail
            editor.setSelectedRange(NSRange(location: input.count, length: tail.count))
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let raw = self.webView.url?.absoluteString ?? ""
            if !raw.isEmpty && !raw.hasPrefix("about:blank") { self.urlField.displayIdleURL(raw) } 
            else { self.urlField.clearForBlankPage() }
            self.hideEditingIcon()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            var input = urlField.stringValue
            if !input.contains(".") && !input.contains("://") { input = "https://duckduckgo.com/?q=\(input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" } 
            else if !input.lowercased().hasPrefix("http") { input = "https://" + input }
            if let url = URL(string: input) {
                if isSplashVisible { 
                    isSplashVisible = false
                    splashOverlay?.isHidden = true 
                }
                urlField.stringValue = url.absoluteString; webView.load(URLRequest(url: url))
            }
            window.makeFirstResponder(webView)
            return true
        } else if sel == #selector(NSResponder.cancelOperation(_:)) {
            window.makeFirstResponder(webView)
            return true
        }
        return false
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame == true,
           let url = action.request.url, let host = url.host {
            let isDiscord = (host == "discord.com" || host.hasSuffix(".discord.com"))
            let desiredUA = isDiscord ? discordUA : safariUA

            if webView.customUserAgent != desiredUA {
                webView.customUserAgent = desiredUA
                decisionHandler(.cancel)
                webView.load(action.request)
                return
            }
        }

        let flags = action.modifierFlags
        if action.navigationType == .linkActivated {
            if flags.contains(.command) || flags.contains(.option) {
                decisionHandler(.cancel)
                if let url = action.request.url {
                    let app = NSApp.delegate as! AppDelegate
                    let currentStore = self.webView.configuration.websiteDataStore
                    if flags.contains(.option) {
                        let newTab = BrowserTab(parentWindow: nil, isPrivate: self.isPrivate, sessionID: self.sessionID, dataStore: currentStore, focusURL: false, showSplash: false)
                        newTab.webView.load(URLRequest(url: url))
                        newTab.window.makeKeyAndOrderFront(nil)
                        app.tabs.append(newTab)
                    } else {
                        let newTab = BrowserTab(parentWindow: self.window, isPrivate: self.isPrivate, sessionID: self.sessionID, dataStore: currentStore, focusURL: false, showSplash: false)
                        newTab.webView.load(URLRequest(url: url))
                        app.tabs.append(newTab)
                        if flags.contains(.shift) { newTab.window.makeKeyAndOrderFront(nil) }
                    }
                }
                return
            }
        }
        decisionHandler(action.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if isSplashVisible {
            isSplashVisible = false
            splashOverlay?.isHidden = true
        }
        findMatchCount = 0; findCurrentIndex = 0
        findBar?.updateMatchLabel(current: 0, total: 0)
    }

    // ---- Error Handling ----

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Accept self-signed certs in development if needed — default handling otherwise
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private func handleNavigationError(_ error: Error) {
        if isSplashVisible { isSplashVisible = false; splashOverlay?.isHidden = true }
        let nsError = error as NSError

        // Ignore cancellations (user navigated away, frame cancelled, etc.)
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        // Ignore WebKit "Frame load interrupted" (triggered by redirects / policy decisions)
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }

        let failedURL = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
                      ?? webView.url?.absoluteString ?? ""
        let escapedURL = failedURL.replacingOccurrences(of: "'", with: "\\'")
                                   .replacingOccurrences(of: "\"", with: "&quot;")

        let (title, suggestion) = errorInfo(for: nsError)

        // Private mode: force dark. Normal mode: follow system appearance.
        let colorScheme = isPrivate ? "dark" : "light dark"

        let html = """
        <html><head><meta charset="utf-8"><meta name="color-scheme" content="\(colorScheme)">
        <style>
          :root {
            --bg: #fafafa; --text: #333; --subtle: #666; --card-bg: #fff;
            --card-border: #e0e0e0; --code-bg: #f0f0f0; --btn-bg: #007aff;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --bg: #1c1c1e; --text: #e0e0e0; --subtle: #8e8e93; --card-bg: #2c2c2e;
              --card-border: #3a3a3c; --code-bg: #3a3a3c; --btn-bg: #0a84ff;
            }
          }
          * { margin:0; padding:0; box-sizing:border-box; }
          body { background:var(--bg); color:var(--text); font-family:-apple-system,BlinkMacSystemFont,sans-serif;
                 display:flex; align-items:center; justify-content:center; height:100vh; padding:32px; }
          .card { max-width:520px; width:100%; background:var(--card-bg); border:1px solid var(--card-border);
                  border-radius:14px; padding:40px; text-align:center; }
          .icon { font-size:48px; margin-bottom:16px; }
          h1 { font-size:20px; font-weight:600; margin-bottom:8px; }
          .subtitle { font-size:14px; color:var(--subtle); line-height:1.5; margin-bottom:6px; }
          .url { font-size:12px; color:var(--subtle); background:var(--code-bg); padding:6px 12px;
                 border-radius:6px; margin:16px 0; word-break:break-all; font-family:SF Mono,Menlo,monospace; }
          .code { font-size:11px; color:var(--subtle); margin-bottom:20px; }
          .retry { display:inline-block; padding:10px 28px; background:var(--btn-bg); color:#fff; border:none;
                   border-radius:8px; font-size:14px; font-weight:500; cursor:pointer; text-decoration:none; }
          .retry:hover { opacity:0.85; }
          .suggestion { font-size:13px; color:var(--subtle); margin-top:20px; line-height:1.5; }
        </style></head><body>
        <div class="card">
          <div class="icon">\(errorIcon(for: nsError))</div>
          <h1>\(title)</h1>
          <p class="subtitle">\(nsError.localizedDescription)</p>
          <div class="url">\(failedURL.isEmpty ? "(no URL)" : failedURL)</div>
          <p class="code">Error \(nsError.code) · \(nsError.domain)</p>
          <a class="retry" href="\(failedURL)" onclick="window.location.href='\(escapedURL)';return false;">Try Again</a>
          <p class="suggestion">\(suggestion)</p>
        </div></body></html>
        """

        webView.loadHTMLString(html, baseURL: URL(string: failedURL))

        // Update window title to reflect the error
        let host = URL(string: failedURL)?.host ?? failedURL
        window.title = isPrivate ? "🔒 Failed to open \(host)" : "Failed to open \(host)"
        syncTabTitleAndIcon()
    }

    private func errorInfo(for error: NSError) -> (title: String, suggestion: String) {
        guard error.domain == NSURLErrorDomain else {
            return ("Page Failed to Load", "The page encountered an unexpected error.")
        }
        switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return ("No Internet Connection",
                    "Check your Wi-Fi or Ethernet connection and try again.")
        case NSURLErrorTimedOut:
            return ("Connection Timed Out",
                    "The server took too long to respond. It may be down or overloaded.")
        case NSURLErrorCannotFindHost:
            return ("Server Not Found",
                    "The address couldn't be resolved. Check the URL for typos, or the site may be down.")
        case NSURLErrorCannotConnectToHost:
            return ("Can't Connect to Server",
                    "The server exists but refused the connection. It may be temporarily offline.")
        case NSURLErrorDNSLookupFailed:
            return ("DNS Lookup Failed",
                    "The domain name couldn't be resolved. Check your DNS settings or try again later.")
        case NSURLErrorSecureConnectionFailed:
            return ("Secure Connection Failed",
                    "An SSL/TLS connection couldn't be established. The site's certificate may be expired or untrusted.")
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid:
            return ("Certificate Error",
                    "The server's security certificate isn't trusted. Proceed with caution.")
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL:
            return ("Invalid Address",
                    "The URL is malformed or uses an unsupported scheme. Check the address and try again.")
        case NSURLErrorRedirectToNonExistentLocation:
            return ("Redirect Error",
                    "The page tried to redirect to a location that doesn't exist.")
        case NSURLErrorHTTPTooManyRedirects:
            return ("Too Many Redirects",
                    "The page is stuck in a redirect loop. Try clearing cookies for this site.")
        default:
            return ("Page Failed to Load",
                    "Something went wrong loading this page.")
        }
    }

    private func errorIcon(for error: NSError) -> String {
        guard error.domain == NSURLErrorDomain else { return "⚠️" }
        switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return "📡"
        case NSURLErrorTimedOut: return "⏱"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "🔍"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateNotYetValid: return "🔒"
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL: return "🔗"
        case NSURLErrorRedirectToNonExistentLocation, NSURLErrorHTTPTooManyRedirects: return "↩️"
        default: return "⚠️"
        }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { startTracking(download) }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { startTracking(download) }

    func startTracking(_ download: WKDownload) {
        download.delegate = self
        DownloadManager.shared.startTracking(download)
        DispatchQueue.main.async { DownloadManager.shared.show(relativeTo: self.downloadBtn) }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        DownloadManager.shared.updateFilename(suggestedFilename, for: download)
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let partURL  = downloadsDir.appendingPathComponent(suggestedFilename + ".part")
        let finalURL = downloadsDir.appendingPathComponent(suggestedFilename)

        let id = ObjectIdentifier(download)
        downloadPartURLs[id] = partURL; downloadDestinations[id] = finalURL

        DownloadManager.shared.setPartURL(partURL, for: download)
        completionHandler(partURL)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        let partURL = downloadPartURLs.removeValue(forKey: id)
        let finalURL = downloadDestinations.removeValue(forKey: id)

        guard let part = partURL, let final = finalURL else { DownloadManager.shared.markFailed(for: download); return }
        let fm = FileManager.default
        try? fm.removeItem(at: final)
        do { try fm.moveItem(at: part, to: final); DownloadManager.shared.markComplete(at: final, for: download) } 
        catch { DownloadManager.shared.markFailed(for: download) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let id = ObjectIdentifier(download)
        if let part = downloadPartURLs.removeValue(forKey: id) { try? FileManager.default.removeItem(at: part) }
        downloadDestinations.removeValue(forKey: id)
        DownloadManager.shared.markFailed(for: download)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let app = NSApplication.shared.delegate as! AppDelegate
        ProxyManager.shared.apply(to: configuration.websiteDataStore)
        if windowFeatures.width != nil || windowFeatures.height != nil {
            let popupTab = BrowserTab(parentWindow: nil, isPrivate: self.isPrivate, sessionID: self.sessionID, dataStore: configuration.websiteDataStore, configuration: configuration, focusURL: false, showSplash: false, isPopup: true) 
            let w = CGFloat(windowFeatures.width?.doubleValue ?? 520); let h = CGFloat(windowFeatures.height?.doubleValue ?? 640)
            popupTab.window.setContentSize(NSSize(width: w, height: h))
            popupTab.openerWindow = self.window 
            popupTab.window.makeKeyAndOrderFront(nil)
            app.tabs.append(popupTab)
            return popupTab.webView
        }
        
        let newTab = BrowserTab(parentWindow: self.window, isPrivate: self.isPrivate, sessionID: self.sessionID, dataStore: configuration.websiteDataStore, configuration: configuration, focusURL: false, showSplash: false) 
        newTab.window.makeKeyAndOrderFront(nil)
        app.tabs.append(newTab)
        return newTab.webView
    }
    
    func webViewDidClose(_ webView: WKWebView) { self.window.close() }
}

// ==========================================
// 11. APP DELEGATE & MENU ACTIONS
// ==========================================
@objc private protocol EditMenuActions {
    func undo(_ sender: Any?); func redo(_ sender: Any?); func cut(_ sender: Any?); func copy(_ sender: Any?); func paste(_ sender: Any?); func selectAll(_ sender: Any?)
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var tabs: [BrowserTab] = []
    var closedTabs: [ClosedTab] = []
    var privateStores: [String: WKWebsiteDataStore] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        ProxyManager.shared.apply(to: WKWebsiteDataStore.default())
        setupMenus()
        createNewWindow()
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }

        ContentBlockerManager.shared.loadAllEnabled()

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Cmd+F — only intercept when WKWebView does NOT have focus.
            // When WKWebView has focus, let the event reach the page; the bubble-phase
            // JS listener will call showFindBar() only if the site didn't preventDefault.
            if event.keyCode == 3 && flags == .command {
                if let tab = self?.tab(for: NSApp.keyWindow), !tab.isPopup {
                    let fr = tab.window.firstResponder
                    let inWebView = (fr as? NSView)?.isDescendant(of: tab.webView) ?? (fr === tab.webView)
                    if !inWebView { tab.showFindBar(); return nil }
                }
            }
            // Ctrl+Tab / Ctrl+Shift+Tab — tab navigation
            if event.keyCode == 48 && flags.contains(.control) {
                if flags.contains(.shift) { NSApp.keyWindow?.selectPreviousTab(nil) }
                else { NSApp.keyWindow?.selectNextTab(nil) }
                return nil
            }
            // Cmd+Opt+I — web inspector
            if event.keyCode == 34 && flags.contains(.command) && flags.contains(.option) {
                NSApp.sendAction(Selector(("toggleWebInspector:")), to: nil, from: nil)
                return nil
            }
            let activeTab = self?.tab(for: NSApp.keyWindow)
            // Cmd+G / Cmd+Shift+G — next / previous match
            if event.keyCode == 5 && flags.contains(.command) {
                if let tab = activeTab, tab.isFindBarVisible {
                    flags.contains(.shift) ? tab.navigateMatch(forward: false) : tab.navigateMatch(forward: true)
                    return nil
                }
            }
            // Escape — close find bar
            if event.keyCode == 53 {
                if let tab = activeTab, tab.isFindBarVisible { tab.hideFindBar(); return nil }
            }
            return event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Walk up the parent-window chain so child windows (dropdowns, pickers)
    // created by WKWebView still resolve to the owning BrowserTab.
    func tab(for window: NSWindow?) -> BrowserTab? {
        var w = window
        while let candidate = w {
            if let tab = tabs.first(where: { $0.window === candidate }) { return tab }
            w = candidate.parent
        }
        return nil
    }

    private func existingPrivateSessionID(for window: NSWindow) -> String? {
        let wins = window.tabGroup?.windows ?? [window]
        return tabs.first(where: { wins.contains($0.window) && $0.isPrivate })?.sessionID
    }

    private func store(for sid: String) -> WKWebsiteDataStore {
        if let s = privateStores[sid] { return s }
        let s = WKWebsiteDataStore.nonPersistent()
        ProxyManager.shared.apply(to: s)
        privateStores[sid] = s; return s
    }

    @objc func createNewTab() {
        guard let win = NSApp.keyWindow else { createNewWindow(); return }
        let winsInGroup = win.tabGroup?.windows ?? [win]
        let isPrivateWindow = tabs.contains { winsInGroup.contains($0.window) && $0.isPrivate }
        
        if isPrivateWindow {
            let sid = existingPrivateSessionID(for: win) ?? UUID().uuidString
            tabs.append(BrowserTab(parentWindow: win, isPrivate: true, sessionID: sid, dataStore: store(for: sid), focusURL: true))
        } else { tabs.append(BrowserTab(parentWindow: win, isPrivate: false, focusURL: true)) }
    }

    @objc func createNewWindow() { tabs.append(BrowserTab(parentWindow: nil, isPrivate: false, focusURL: true)) }

    @objc func createPrivateWindow() {
        let sid = UUID().uuidString
        tabs.append(BrowserTab(parentWindow: nil, isPrivate: true, sessionID: sid, dataStore: store(for: sid), focusURL: true))
    }

    @objc func reopenClosedTab() {
        guard let last = closedTabs.popLast(), let win = NSApp.keyWindow else { return }
        let hasURL = !last.url.isEmpty && !last.url.starts(with: "about:blank")
        if last.isPrivate {
            let sid: String
            if let orig = last.sessionID, privateStores[orig] != nil { sid = orig }
            else { sid = existingPrivateSessionID(for: win) ?? UUID().uuidString }
            let t = BrowserTab(parentWindow: win, isPrivate: true, sessionID: sid, dataStore: store(for: sid), targetIndex: last.index, focusURL: false, showSplash: !hasURL)
            if hasURL, let url = URL(string: last.url) { t.webView.load(URLRequest(url: url)) }
            tabs.append(t)
        } else {
            let t = BrowserTab(parentWindow: win, isPrivate: false, targetIndex: last.index, focusURL: false, showSplash: !hasURL)
            if hasURL, let url = URL(string: last.url) { t.webView.load(URLRequest(url: url)) }
            tabs.append(t)
        }
    }

    @objc func openSettings() { SettingsWindowController.shared.showSettings() }

    @objc func openFindBar() {
        if let tab = tab(for: NSApp.keyWindow), !tab.isPopup { tab.showFindBar() }
    }

    @objc func focusURLBar() {
        guard let win = NSApp.keyWindow, let tab = tabs.first(where: { $0.window == win }) else { return }
        win.makeFirstResponder(tab.urlField)
        tab.urlField.currentEditor()?.selectAll(nil)
    }

    @objc func reloadCurrentTab() {
        if let win = NSApp.keyWindow, let tab = tabs.first(where: { $0.window == win }) { tab.reload() }
    }

    func setupMenus() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "New Window", action: #selector(createNewWindow), keyEquivalent: "n"))
        fileMenu.addItem(NSMenuItem(title: "New Private Window", action: #selector(createPrivateWindow), keyEquivalent: "N"))
        fileMenu.addItem(NSMenuItem(title: "New Tab", action: #selector(createNewTab), keyEquivalent: "t"))
        fileMenu.addItem(NSMenuItem(title: "Reopen Closed Tab", action: #selector(reopenClosedTab), keyEquivalent: "T"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileItem.submenu = fileMenu

        let viewItem = NSMenuItem(); mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(NSMenuItem(title: "Reload", action: #selector(reloadCurrentTab), keyEquivalent: "r"))
        viewMenu.addItem(NSMenuItem(title: "Focus URL Bar", action: #selector(focusURLBar), keyEquivalent: "l"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        viewItem.submenu = viewMenu

        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: #selector(EditMenuActions.undo(_:)), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: #selector(EditMenuActions.redo(_:)), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(EditMenuActions.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(EditMenuActions.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(EditMenuActions.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(EditMenuActions.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Find…", action: #selector(openFindBar), keyEquivalent: ""))
        editItem.submenu = editMenu

        let winItem = NSMenuItem(); mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(NSMenuItem(title: "Show Next Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "}"))
        winMenu.addItem(NSMenuItem(title: "Show Previous Tab", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "{"))
        winItem.submenu = winMenu

        NSApp.mainMenu = mainMenu
    }
}

// ==========================================
// ENTRY POINT
// ==========================================
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
