import AppKit
import Foundation

/// Minimal VT-style terminal emulator written from scratch. Replaces
/// SwiftTerm's TerminalView, which kept pushing the top of the diagnostic
/// test display into scrollback no matter how we positioned the cursor or
/// scoped the alt buffer. This emulator only speaks the subset of VT220 /
/// xterm that the DCL shell actually emits:
///
///   * CR (0x0D), LF (0x0A), BS (0x08), TAB (0x09)
///   * CSI cursor position: `ESC [ row;col H` and `ESC [ row;col f`
///   * CSI erase in display: `ESC [ 0/1/2 J` (and `3 J` as no-op -- we
///     don't keep scrollback so there's nothing to clear)
///   * CSI erase in line:    `ESC [ 0/1/2 K`
///   * CSI cursor movement:  `ESC [ <n> A/B/C/D`
///   * DECSET 1049 / 25:      alt screen / cursor visibility
///   * SGR is consumed but ignored -- we paint with the single configured
///     foreground / background colour.
///
/// Anything outside this set is parsed (so we don't drop into a corrupt
/// state) but applied as a no-op.
final class RetroTerminalView: NSView {

    // MARK: - Public API

    /// Bytes the emulator generates from keystrokes flow out through this
    /// callback. The DCL line discipline in VTShellView's coordinator
    /// reads them.
    var onInput: (([UInt8]) -> Void)?

    /// Fires once, the first time the view has been sized to something
    /// larger than the initial `.zero` frame. Callers use it to defer
    /// feeding content until the buffer has real cols/rows -- otherwise
    /// everything gets mashed into a 1x1 grid and then thrown away when
    /// the view is reshaped.
    var onReady: (() -> Void)?
    private var hasReportedReady = false

    var foregroundColor: NSColor = NSColor(srgbRed: 1.00, green: 0.72, blue: 0.20, alpha: 1) {
        didSet { needsDisplay = true }
    }
    var backgroundColor: NSColor = NSColor(srgbRed: 0.04, green: 0.04, blue: 0.05, alpha: 1) {
        didSet {
            layer?.backgroundColor = backgroundColor.cgColor
            needsDisplay = true
        }
    }

    let font: NSFont

    private(set) var cols: Int = 1
    private(set) var rows: Int = 1

    // MARK: - Cell + Buffer

    private struct Cell {
        var character: Character = " "
    }

    /// 2-D grid of cells. We keep two of these: the primary buffer and
    /// the alternate buffer (entered/exited via DECSET 1049). Indexed
    /// `[row][col]`, both 0-based.
    private var primary: [[Cell]] = []
    private var alternate: [[Cell]] = []
    private var inAltBuffer: Bool = false

    /// Current write target. Computed each access so callers can mutate
    /// the grid via subscripts without copying the whole buffer.
    private var buffer: [[Cell]] {
        get { inAltBuffer ? alternate : primary }
        set {
            if inAltBuffer { alternate = newValue } else { primary = newValue }
        }
    }

    // MARK: - Cursor

    private var cursorRow: Int = 0
    private var cursorCol: Int = 0
    private var savedRow: Int = 0
    private var savedCol: Int = 0
    /// Cursor position stashed when we enter the alt buffer via DECSET
    /// 1049 -- restored on exit so the prompt picks up where it left
    /// off in the primary buffer rather than landing in mid-screen.
    private var altReturnRow: Int = 0
    private var altReturnCol: Int = 0
    private var cursorVisible: Bool = true

    // MARK: - Font metrics

    private let cellWidth: CGFloat
    private let cellHeight: CGFloat
    private let glyphBaseline: CGFloat

    // MARK: - CSI parser state

    private enum ParserState {
        case ground
        case escape
        case csi
    }
    private var parser: ParserState = .ground
    private var csiPrivate: Bool = false
    private var csiParams: [Int] = []
    private var csiCurrent: Int = 0
    private var csiHasDigit: Bool = false

    // MARK: - Init

    init(frame: CGRect, font: NSFont) {
        self.font = font
        // Cell width: true glyph advance via CoreText (NSString.size
        // returns inked extent, which under-reports for pixel fonts
        // like VT323 and made the cursor render as a sliver).
        // Cell height: NSLayoutManager.defaultLineHeight matches what
        // NSAttributedString.draw lays out, so glyphs and cursor align.
        let ctFont = font as CTFont
        var chars: [UniChar] = [0x4D]                    // 'M'
        var glyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(ctFont, &chars, &glyph, 1)
        var advance: CGSize = .zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, [glyph], &advance, 1)
        self.cellWidth = max(1, ceil(advance.width))
        let mgr = NSLayoutManager()
        self.cellHeight = max(1, ceil(mgr.defaultLineHeight(for: font)))
        // NSLayoutManager packs the glyph so its baseline sits at
        // (cellHeight + font.descender) from the cell top; descender
        // is negative for most fonts.
        self.glyphBaseline = ceil(self.cellHeight + font.descender)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
        recomputeGrid()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Resize

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recomputeGrid()
        if !hasReportedReady, cols > 1, rows > 1 {
            hasReportedReady = true
            onReady?()
        }
    }

    /// Recompute cols/rows from the current bounds and reshape both
    /// buffers preserving any existing content (truncated to the new
    /// dimensions). Reserves one cell of vertical padding at the bottom
    /// so the prompt row (which is always cursor's row after engine
    /// output) isn't clipped by the window's bottom edge / chrome.
    private func recomputeGrid() {
        let newCols = max(1, Int(bounds.width / cellWidth))
        let raw = Int((bounds.height - cellHeight) / cellHeight)
        let newRows = max(1, raw)
        if newCols == cols && newRows == rows && !primary.isEmpty { return }
        cols = newCols
        rows = newRows
        primary   = Self.reshape(primary,   cols: newCols, rows: newRows)
        alternate = Self.reshape(alternate, cols: newCols, rows: newRows)
        cursorRow = min(cursorRow, max(0, rows - 1))
        cursorCol = min(cursorCol, max(0, cols - 1))
        needsDisplay = true
    }

    private static func reshape(_ src: [[Cell]], cols: Int, rows: Int) -> [[Cell]] {
        var result = Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
        for r in 0..<min(rows, src.count) {
            for c in 0..<min(cols, src[r].count) {
                result[r][c] = src[r][c]
            }
        }
        return result
    }

    // MARK: - Feed

    /// Push a chunk of text / control bytes through the parser.
    func feed(text: String) {
        for scalar in text.unicodeScalars {
            handleScalar(scalar)
        }
        needsDisplay = true
    }

    /// Convenience for legacy byte-array callers.
    func feed(byteArray: [UInt8]) {
        feed(text: String(decoding: byteArray, as: UTF8.self))
    }

    /// Drive the parser one Unicode scalar at a time. The scalar
    /// granularity is enough for our needs -- DCL never emits combined
    /// graphemes through the engine, and the box-drawing chars are all
    /// single scalars.
    private func handleScalar(_ scalar: Unicode.Scalar) {
        switch parser {
        case .ground:
            handleGround(scalar)
        case .escape:
            handleEscape(scalar)
        case .csi:
            handleCSI(scalar)
        }
    }

    private func handleGround(_ scalar: Unicode.Scalar) {
        switch scalar.value {
        case 0x1B:                                  // ESC
            parser = .escape
        case 0x0D:                                  // CR
            cursorCol = 0
        case 0x0A:                                  // LF
            lineFeed()
        case 0x08:                                  // BS
            if cursorCol > 0 { cursorCol -= 1 }
        case 0x09:                                  // TAB -> next 8-col stop
            let next = ((cursorCol / 8) + 1) * 8
            cursorCol = min(cols - 1, next)
        case 0x07:                                  // BEL -- silent
            break
        case 0x00...0x1F:                           // other C0 -- swallow
            break
        default:
            if cursorCol >= cols {
                // Soft wrap: previous char hit the right edge.
                cursorCol = 0
                lineFeed()
            }
            putChar(Character(scalar))
            cursorCol += 1
        }
    }

    private func putChar(_ ch: Character) {
        guard cursorRow >= 0, cursorRow < rows,
              cursorCol >= 0, cursorCol < cols else { return }
        var buf = buffer
        buf[cursorRow][cursorCol].character = ch
        buffer = buf
    }

    /// Move cursor down one row. If already on the bottom row, scroll
    /// the buffer up by one (oldest row falls off the top). Only the
    /// active buffer is affected.
    private func lineFeed() {
        if cursorRow < rows - 1 {
            cursorRow += 1
        } else {
            scrollUp()
        }
    }

    private func scrollUp() {
        var buf = buffer
        if buf.count >= 1 {
            buf.removeFirst()
            buf.append(Array(repeating: Cell(), count: cols))
        }
        buffer = buf
    }

    // MARK: - ESC parser

    private func handleEscape(_ scalar: Unicode.Scalar) {
        switch scalar.value {
        case 0x5B:                                  // '['
            parser = .csi
            csiPrivate = false
            csiParams = []
            csiCurrent = 0
            csiHasDigit = false
        case 0x37:                                  // '7' DECSC -- save cursor
            savedRow = cursorRow
            savedCol = cursorCol
            parser = .ground
        case 0x38:                                  // '8' DECRC -- restore cursor
            cursorRow = savedRow
            cursorCol = savedCol
            parser = .ground
        case 0x63:                                  // 'c' RIS -- full reset
            inAltBuffer = false
            primary   = Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
            alternate = Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
            cursorRow = 0
            cursorCol = 0
            parser = .ground
        case 0x44, 0x45, 0x4D:                      // 'D'/'E'/'M' -- index / next-line / reverse-index
            // Treated as LF for our needs.
            lineFeed()
            if scalar == "E" { cursorCol = 0 }
            parser = .ground
        case 0x28, 0x29, 0x2A, 0x2B:                // SCS designators -- swallow next char
            parser = .escape // crude but unused by DCL
        default:
            parser = .ground
        }
    }

    private func handleCSI(_ scalar: Unicode.Scalar) {
        let v = scalar.value
        // Parameter accumulation
        if v >= 0x30 && v <= 0x39 {                 // '0'..'9'
            csiCurrent = csiCurrent * 10 + Int(v - 0x30)
            csiHasDigit = true
            return
        }
        if v == 0x3B {                              // ';'
            csiParams.append(csiHasDigit ? csiCurrent : -1)
            csiCurrent = 0
            csiHasDigit = false
            return
        }
        if v == 0x3F && csiParams.isEmpty && !csiHasDigit {
            csiPrivate = true
            return
        }
        // Final byte: 0x40 .. 0x7E
        if v >= 0x40 && v <= 0x7E {
            csiParams.append(csiHasDigit ? csiCurrent : -1)
            executeCSI(final: scalar)
            parser = .ground
            return
        }
        // Anything else aborts the sequence.
        parser = .ground
    }

    private func param(_ index: Int, default def: Int) -> Int {
        guard index < csiParams.count else { return def }
        let v = csiParams[index]
        return v < 0 ? def : v
    }

    private func executeCSI(final: Unicode.Scalar) {
        switch final {
        case "H", "f":                              // CUP / HVP -- cursor position
            let r = max(1, param(0, default: 1)) - 1
            let c = max(1, param(1, default: 1)) - 1
            cursorRow = min(max(0, r), rows - 1)
            cursorCol = min(max(0, c), cols - 1)
        case "A":                                   // CUU
            cursorRow = max(0, cursorRow - max(1, param(0, default: 1)))
        case "B":                                   // CUD
            cursorRow = min(rows - 1, cursorRow + max(1, param(0, default: 1)))
        case "C":                                   // CUF
            cursorCol = min(cols - 1, cursorCol + max(1, param(0, default: 1)))
        case "D":                                   // CUB
            cursorCol = max(0, cursorCol - max(1, param(0, default: 1)))
        case "G":                                   // CHA -- cursor to col
            cursorCol = min(cols - 1, max(0, param(0, default: 1) - 1))
        case "d":                                   // VPA -- cursor to row
            cursorRow = min(rows - 1, max(0, param(0, default: 1) - 1))
        case "J":                                   // ED
            eraseInDisplay(param(0, default: 0))
        case "K":                                   // EL
            eraseInLine(param(0, default: 0))
        case "h":
            handleSetMode(set: true)
        case "l":
            handleSetMode(set: false)
        case "s":                                   // SCP -- save cursor
            savedRow = cursorRow
            savedCol = cursorCol
        case "u":                                   // RCP -- restore cursor
            cursorRow = savedRow
            cursorCol = savedCol
        case "m":
            // SGR -- ignored, we paint with the single configured palette.
            break
        default:
            break
        }
    }

    private func handleSetMode(set: Bool) {
        guard csiPrivate else { return }
        for p in csiParams {
            switch p {
            case 25:                                // DECTCEM -- cursor visibility
                cursorVisible = set
            case 47, 1047, 1049:                    // alt screen variants
                if set {
                    if !inAltBuffer {
                        // Stash the primary cursor so we can return to
                        // the same line when DECSET 1049l fires.
                        altReturnRow = cursorRow
                        altReturnCol = cursorCol
                        // Snap into alt buffer; clear it on entry.
                        alternate = Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
                        inAltBuffer = true
                        cursorRow = 0
                        cursorCol = 0
                    }
                } else {
                    if inAltBuffer {
                        inAltBuffer = false
                        cursorRow = min(altReturnRow, rows - 1)
                        cursorCol = min(altReturnCol, cols - 1)
                    }
                }
            default:
                break
            }
        }
    }

    private func eraseInDisplay(_ kind: Int) {
        switch kind {
        case 0:
            // From cursor to end of screen.
            var buf = buffer
            for c in cursorCol..<cols { buf[cursorRow][c] = Cell() }
            for r in (cursorRow + 1)..<rows {
                buf[r] = Array(repeating: Cell(), count: cols)
            }
            buffer = buf
        case 1:
            // From start of screen to cursor.
            var buf = buffer
            for r in 0..<cursorRow {
                buf[r] = Array(repeating: Cell(), count: cols)
            }
            for c in 0...min(cursorCol, cols - 1) { buf[cursorRow][c] = Cell() }
            buffer = buf
        case 2, 3:
            // Entire screen. (3 also clears scrollback, but we have none.)
            buffer = Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
        default:
            break
        }
    }

    private func eraseInLine(_ kind: Int) {
        var buf = buffer
        switch kind {
        case 0:
            for c in cursorCol..<cols { buf[cursorRow][c] = Cell() }
        case 1:
            for c in 0...min(cursorCol, cols - 1) { buf[cursorRow][c] = Cell() }
        case 2:
            buf[cursorRow] = Array(repeating: Cell(), count: cols)
        default:
            break
        }
        buffer = buf
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(backgroundColor.cgColor)
        ctx.fill(bounds)

        // Build a single attributed string per row and render in one
        // shot. The fixed-pitch font keeps the column math trivial.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foregroundColor
        ]
        for r in 0..<min(rows, buffer.count) {
            let row = buffer[r]
            // Trim trailing blanks so we don't draw the whole line every time.
            var lastNonBlank = -1
            for c in (0..<cols).reversed() where c < row.count && row[c].character != " " {
                lastNonBlank = c
                break
            }
            if lastNonBlank < 0 { continue }
            let chars = String(row.prefix(lastNonBlank + 1).map { $0.character })
            let y = CGFloat(r) * cellHeight + glyphBaseline
            let line = NSAttributedString(string: chars, attributes: attrs)
            // Draw each character cell-aligned. Even with a monospace
            // font, AppKit's text drawing can drift over long lines on
            // some fonts -- per-cell drawing keeps the grid honest.
            for (i, ch) in chars.enumerated() {
                let cellOrigin = CGPoint(x: CGFloat(i) * cellWidth, y: y)
                let glyphStr = NSAttributedString(string: String(ch), attributes: attrs)
                glyphStr.draw(at: cellOrigin)
            }
            _ = line // silence unused-let warning
        }

        // Cursor: render as a `█` character using the SAME drawing path
        // as the rest of the text. Earlier attempts used ctx.fill(rect)
        // for the cursor block, but the rect's y didn't line up with
        // where NSAttributedString.draw actually places glyphs in this
        // flipped view -- the block appeared one row above the prompt
        // it was supposed to mark. Drawing a glyph guarantees alignment.
        if cursorVisible,
           cursorRow >= 0, cursorRow < rows,
           cursorCol >= 0, cursorCol < cols {
            let cursorY = CGFloat(cursorRow) * cellHeight + glyphBaseline
            let cursorX = CGFloat(cursorCol) * cellWidth
            let fgAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: foregroundColor
            ]
            NSAttributedString(string: "\u{2588}", attributes: fgAttrs)
                .draw(at: CGPoint(x: cursorX, y: cursorY))
            // If there's a visible glyph under the cursor, re-stamp it
            // in the background colour so the user can still read it.
            if cursorRow < buffer.count, cursorCol < buffer[cursorRow].count {
                let ch = buffer[cursorRow][cursorCol].character
                if ch != " " {
                    let bgAttrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: backgroundColor
                    ]
                    NSAttributedString(string: String(ch), attributes: bgAttrs)
                        .draw(at: CGPoint(x: cursorX, y: cursorY))
                }
            }
        }
    }

    // MARK: - Keyboard

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        var bytes: [UInt8] = []
        let modifiers = event.modifierFlags
        let ctrl = modifiers.contains(.control)

        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            switch event.keyCode {
            case 0x24:                              // Return
                bytes = [0x0D]
            case 0x33:                              // Delete (Backspace)
                bytes = [0x7F]
            case 0x35:                              // Escape
                bytes = [0x1B]
            case 0x30:                              // Tab
                bytes = [0x09]
            case 0x7E:                              // Up arrow
                bytes = [0x1B, 0x5B, 0x41]
            case 0x7D:                              // Down
                bytes = [0x1B, 0x5B, 0x42]
            case 0x7C:                              // Right
                bytes = [0x1B, 0x5B, 0x43]
            case 0x7B:                              // Left
                bytes = [0x1B, 0x5B, 0x44]
            default:
                // Honor Ctrl-letter combos.
                if ctrl, let first = chars.unicodeScalars.first,
                   first.value >= 0x40 && first.value < 0x80 {
                    let masked = UInt8(first.value & 0x1F)
                    bytes = [masked]
                } else {
                    bytes = Array(chars.utf8)
                }
            }
        }

        if !bytes.isEmpty {
            onInput?(bytes)
        } else {
            super.keyDown(with: event)
        }
    }
}
