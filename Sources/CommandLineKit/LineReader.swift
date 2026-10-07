//
//  LineReader.swift
//  CommandLineKit
//
//  Created by Matthias Zenger on 07/04/2018.
//  Copyright © 2018-2021 Google LLC
//  Copyright © 2017 Andy Best <andybest.net at gmail dot com>
//  Copyright © 2010-2014 Salvatore Sanfilippo <antirez at gmail dot com>
//  Copyright © 2010-2013 Pieter Noordhuis <pcnoordhuis at gmail dot com>
//
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions are met:
//
//  * Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
//
//  * Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
//  * Neither the name of the copyright holder nor the names of its contributors
//    may be used to endorse or promote products derived from this software without
//    specific prior written permission.
//
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
//  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
//  WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//  DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
//  ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
//  (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
//  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
//  ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
//  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
//  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

import Foundation


public class LineReader {

  /// Does this terminal support this line reader?
  public let termSupported: Bool

  /// Terminal type
  public let currentTerm: String

  /// Does the terminal support colors?
  public let fullColorSupport: Bool

  /// If false (the default) any edits by the user to a line in the history will be discarded
  /// if the user moves forward or back in the history without pressing Enter. If true, all
  /// history edits will be preserved.
  public var preserveHistoryEdits = false

  /// The history of previous line reads
  private var history: LineReaderHistory

  /// Temporary line read buffer to handle browsing of histories
  private var tempBuf: String?

  /// A callback for handling line completions
  private var completionCallback: ((String) -> [String])?

  /// A callback for handling hints
  private var hintsCallback: ((String) -> (String, TextProperties)?)?

  /// A callback for the completion menu; replaces `completionCallback` when set
  private var completionMenuCallback: ((String) -> [LineCompletion])?

  /// The maximum number of candidates the completion menu shows at once.
  public var completionMenuHeight = 8

  /// How long to wait after Esc for the rest of an escape sequence (an arrow key sends Esc and
  /// two more bytes at once); without more input it was the Esc key itself.
  private static let escapeSequenceTimeout: Int32 = 50

  /// How the completion menu shows the selected candidate.
  public var completionMenuSelectedProperties = TextProperties(textStyles: [.swap])

  /// How the completion menu shows the details of the candidates that aren't selected.
  public var completionMenuDetailProperties = TextProperties(textColor: .grey)

  /// A POSIX file handle for the input
  private let inputFile: Int32

  /// Text from `printAbove` waiting for the reading thread, guarded by `messageLock`
  private var pendingMessages: [String] = []

  /// Set while `readLine` is reading in raw mode, guarded by `messageLock`
  private var isReading = false

  /// Guards `pendingMessages` and `isReading`
  private let messageLock = NSLock()

  /// Wakes up the reading thread when `printAbove` queued text: [read end, write end]
  private var messagePipe: [Int32] = [-1, -1]

  /// A POSIX file handle for the output
  private let outputFile: Int32

  /// Initializer
  public init?(inputFile: Int32 = STDIN_FILENO,
               outputFile: Int32 = STDOUT_FILENO,
               completionCallback: ((String) -> [String])? = nil,
               hintsCallback: ((String) -> (String, TextProperties)?)? = nil) {
    self.inputFile = inputFile
    self.outputFile = outputFile
    self.currentTerm = Terminal.current
    if isatty(inputFile) != 1 {
      return nil
    } else {
      self.termSupported = LineReader.supportedBy(terminal: self.currentTerm)
    }
    self.fullColorSupport = Terminal.fullColorSupport(terminal: self.currentTerm)
    self.history = LineReaderHistory()
    self.completionCallback = completionCallback
    self.hintsCallback = hintsCallback
    if pipe(&self.messagePipe) == 0 {
      _ = fcntl(self.messagePipe[0], F_SETFL, O_NONBLOCK)
      _ = fcntl(self.messagePipe[1], F_SETFL, O_NONBLOCK)
    }
  }

  deinit {
    for descriptor in self.messagePipe where descriptor >= 0 {
      close(descriptor)
    }
  }

  /// Erases the line just read, the prompt and the input over as many rows as they took, e.g. to
  /// replace it with an echo that arrives through `printAbove`. `promptWidth` is the width of the
  /// prompt plus the input, in columns.
  public func eraseLastLine(promptWidth: Int) {
    guard self.termSupported else {
      return
    }
    // The cursor is on the row below the input. Input ending exactly at the right edge still
    // took a row more: the space drawn after it wrapped.
    let rows = promptWidth / self.numColumns + 1
    try? self.output(text: AnsiCodes.cursorUp(rows) + AnsiCodes.beginningOfLine +
                           AnsiCodes.clearCursorToBottom)
  }

  /// Prints `text` above the line being read, then redraws the prompt, the input and an open
  /// completion menu below it. Can be called from any thread, e.g. for log messages arriving
  /// while the user types; while no line is being read, `text` is just printed.
  public func printAbove(_ text: String) {
    self.messageLock.lock()
    defer { self.messageLock.unlock() }
    guard self.isReading && self.messagePipe[1] >= 0 else {
      Swift.print(text)
      return
    }
    self.pendingMessages.append(text)
    var wake: UInt8 = 1
    _ = write(self.messagePipe[1], &wake, 1)
  }

  public static var supportedByTerminal: Bool {
    return LineReader.supportedBy(terminal: Terminal.current)
  }

  public static func supportedBy(terminal: String) -> Bool {
    #if os(macOS)
    if let xpcServiceName = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"],
       xpcServiceName.localizedCaseInsensitiveContains("com.apple.dt.xcode") {
      return false
    }
    #endif
    switch terminal {
      case "", "xcode", "dumb", "cons25", "emacs":
        return false
      default:
        return true
    }
  }

  /// Adds a string to the history buffer.
  public func addHistory(_ item: String) {
    self.history.add(item)
  }

  /// Adds a callback for tab completion. The callback is taking the current text and returning
  /// an array of Strings containing possible completions.
  public func setCompletionCallback(_ callback: @escaping (String) -> [String]) {
    self.completionCallback = callback
  }

  /// Adds a callback for a completion menu. The callback is taking the current text and
  /// returning the candidates. On Tab, a single candidate is accepted right away; for more,
  /// the line is extended to what they share and a menu opens below it: Tab, Down and Up move
  /// the selection (previewed as a hint after the cursor), Return or Right accepts it, Esc
  /// closes the menu, and typing filters it. Takes precedence over `setCompletionCallback`.
  public func setCompletionMenuCallback(_ callback: @escaping (String) -> [LineCompletion]) {
    self.completionMenuCallback = callback
  }

  /// Adds a callback for hints as you type. The callback is taking the current text and
  /// optionally returning the hint and a tuple of RGB colours for the hint text. Right at the
  /// end of the line accepts the hint.
  public func setHintsCallback(_ callback: @escaping (String) -> (String, TextProperties)?) {
    self.hintsCallback = callback
  }

  /// Loads history from a file and appends it to the current history buffer. This method can
  /// throw an error if the file cannot be found or loaded.
  public func loadHistory(fromFile path: String) throws {
    try self.history.load(fromFile: path)
  }

  /// Saves history to a file. This method can throw an error if the file cannot be written to.
  public func saveHistory(toFile path: String) throws {
    try self.history.save(toFile: path)
  }

  /// Sets the maximum amount of items to keep in history. If this limit is reached, the oldest
  /// item is discarded when a new item is added. Setting the maximum length of history to 0
  /// (the default) will keep unlimited items in history.
  public func setHistoryMaxLength(_ historyMaxLength: UInt) {
    self.history.maxLength = historyMaxLength
  }

  /// Clears the screen. This method can throw an error if the terminal cannot be written to.
  public func clearScreen() throws {
    if self.termSupported {
      try self.output(text: AnsiCodes.homeCursor)
      try self.output(text: AnsiCodes.clearScreen)
    }
  }

  /// The main function of LineReader. This method shows a prompt to the user at the beginning
  /// of the line and reads the input from the user, returning it as a string. The method can
  /// throw an error if the terminal cannot be written to.
  public func readLine(prompt: String,
                       maxCount: Int? = nil,
                       strippingNewline: Bool = true,
                       promptProperties: TextProperties = TextProperties.empty,
                       readProperties: TextProperties = TextProperties.empty,
                       parenProperties: TextProperties = TextProperties.empty) throws -> String {
    tempBuf = nil
    if self.termSupported {
      return try self.readLineSupported(prompt: prompt,
                                        maxCount: maxCount,
                                        strippingNewline: strippingNewline,
                                        promptProperties: promptProperties,
                                        readProperties: readProperties,
                                        parenProperties: parenProperties)
    } else {
      return try self.readLineUnsupported(prompt: prompt,
                                          maxCount: maxCount,
                                          strippingNewline: strippingNewline)
    }
  }

  private func readLineUnsupported(prompt: String,
                                   maxCount: Int?,
                                   strippingNewline: Bool) throws -> String {
    Swift.print(prompt, terminator: "")
    if let line = Swift.readLine(strippingNewline: strippingNewline) {
      return maxCount != nil ? String(line.prefix(maxCount!)) : line
    } else {
      throw LineReaderError.EOF
    }
  }

  private func readLineSupported(prompt: String,
                                 maxCount: Int?,
                                 strippingNewline: Bool,
                                 promptProperties: TextProperties,
                                 readProperties: TextProperties,
                                 parenProperties: TextProperties) throws -> String {
    var line: String = ""
    if fileno(stdout) == self.outputFile {
      fflush(stdout)
    }
    self.setReading(true)
    defer {
      // Text that arrived after the line was read is printed normally
      for message in self.setReading(false) {
        Swift.print(message)
      }
    }
    try self.withRawMode {
      if let col = self.cursorColumn, col > 1 {
        try self.output(text: "\n" + AnsiCodes.setCursorColumn(0))
      }
      try self.output(text: promptProperties.apply(to: prompt))
      let editState = EditState(prompt: prompt,
                                maxCount: maxCount,
                                promptProperties: promptProperties,
                                readProperties: readProperties,
                                parenProperties: parenProperties)
      while true {
        guard var char = try self.readByte(editState: editState) else {
          return
        }
        if char == ControlCharacters.Tab.rawValue && self.completionMenuCallback != nil {
          guard let completionChar = try self.completeWithMenu(editState: editState) else {
            continue
          }
          char = completionChar
        } else if char == ControlCharacters.Tab.rawValue && self.completionCallback != nil,
           let completionChar = try self.completeLine(editState: editState) {
          char = completionChar
        }
        if let rv = try self.handleCharacter(char, editState: editState) {
          if editState.moveEnd() {
            try self.updateCursorPos(editState: editState)
          }
          // It's unclear to me why it's necessary to set the cursor to column 0
          try self.output(text: "\n" + AnsiCodes.setCursorColumn(0))
          line = rv
          return
        }
      }
    }
    return strippingNewline ? line : line + "\n"
  }

  private func completeLine(editState: EditState) throws -> UInt8? {
    guard let completionCallback = self.completionCallback else {
      return nil
    }
    let completions = completionCallback(editState.buffer)
    guard completions.count > 0 else {
      self.ringBell()
      return nil
    }
    // Loop to handle inputs
    var completionIndex = 0
    while true {
      if completionIndex < completions.count {
        try editState.withTemporaryState {
          try self.setBuffer(editState: editState, new: completions[completionIndex])
        }
      } else {
        try refreshLine(editState: editState)
      }
      guard let char = self.readByte() else {
        return nil
      }
      switch char {
        case ControlCharacters.Tab.rawValue:
          // Move to next completion
          completionIndex = (completionIndex + 1) % (completions.count + 1)
          if completionIndex == completions.count {
            self.ringBell()
          }
        case ControlCharacters.Esc.rawValue:
          // Show the original buffer
          if completionIndex < completions.count {
            try refreshLine(editState: editState)
          }
          return char
        default:
          // Update the buffer and return
          if completionIndex < completions.count {
            try self.setBuffer(editState: editState, new: completions[completionIndex])
          }
          return char
      }
    }
  }

  /// Completes with the menu. Returns a character the main loop should still handle, or `nil`
  /// if the menu consumed all input.
  private func completeWithMenu(editState: EditState) throws -> UInt8? {
    guard let callback = self.completionMenuCallback else {
      return nil
    }
    var menu = CompletionMenu(candidates: callback(editState.buffer))
    guard !menu.candidates.isEmpty else {
      self.ringBell()
      return nil
    }
    // A single candidate, or one the others all start with: just take what they share
    let common = menu.commonPrefix
    if common.count > editState.buffer.count && common.hasPrefix(editState.buffer) {
      try self.setBuffer(editState: editState, new: common)
    }
    if menu.candidates.count == 1 {
      return nil
    }
    while true {
      try self.refreshLine(editState: editState, menu: menu)
      guard let char = try self.readByte(editState: editState, menu: menu) else {
        return nil
      }
      switch char {
        case ControlCharacters.Tab.rawValue:
          menu.move(by: 1, height: self.completionMenuHeight)
        case ControlCharacters.Enter.rawValue:
          try self.setBuffer(editState: editState, new: menu.candidates[menu.selected].text)
          return nil
        case ControlCharacters.Esc.rawValue:
          guard self.waitForInput(milliseconds: LineReader.escapeSequenceTimeout) else {
            // A lone Esc closes the menu
            try self.refreshLine(editState: editState)
            return nil
          }
          guard self.readCharacter() == "[" else {
            break
          }
          var code = self.readCharacter()
          while let c = code, c.isNumber || c == ";" {
            code = self.readCharacter()
          }
          switch code {
            case "A", "Z":
              // Up, Shift-Tab
              menu.move(by: -1, height: self.completionMenuHeight)
            case "B":
              // Down
              menu.move(by: 1, height: self.completionMenuHeight)
            case "C":
              // Right accepts the selection, like Return
              try self.setBuffer(editState: editState, new: menu.candidates[menu.selected].text)
              return nil
            default:
              break
          }
        case ControlCharacters.Backspace.rawValue, 0x20..<0x7F, 0x80...0xFF:
          // Edit the line, then filter the menu by it
          _ = try self.handleCharacter(char, editState: editState)
          menu = CompletionMenu(candidates: callback(editState.buffer))
          guard menu.candidates.count > 1 else {
            try self.refreshLine(editState: editState)
            return nil
          }
        default:
          try self.refreshLine(editState: editState)
          return char
      }
    }
  }

  private func handleCharacter(_ ch: UInt8, editState: EditState) throws -> String? {
    switch ch {
      case ControlCharacters.Enter.rawValue:
        try refreshLine(editState: editState, decorate: false)
        return editState.buffer
      case ControlCharacters.CtrlA.rawValue:
        try self.moveHome(editState: editState)
      case ControlCharacters.CtrlE.rawValue:
        try self.moveEnd(editState: editState)
      case ControlCharacters.CtrlB.rawValue:
        try self.moveLeft(editState: editState)
      case ControlCharacters.CtrlC.rawValue:
        // Throw an error so that CTRL+C can be handled by the caller
        throw LineReaderError.CTRLC
      case ControlCharacters.CtrlD.rawValue:
        // If there is a character at the right of the cursor, remove it
        if editState.eraseCharacterRight() {
          try self.refreshLine(editState: editState)
        } else {
          self.ringBell()
        }
      case ControlCharacters.CtrlP.rawValue:
        // Previous history item
        try self.moveHistory(editState: editState, direction: .previous)
      case ControlCharacters.CtrlN.rawValue:
        // Next history item
        try self.moveHistory(editState: editState, direction: .next)
      case ControlCharacters.CtrlL.rawValue:
        // Clear screen
        try self.clearScreen()
        editState.cursorRow = 0
        try self.refreshLine(editState: editState)
      case ControlCharacters.CtrlT.rawValue:
        if editState.swapCharacterWithPrevious() {
          try refreshLine(editState: editState)
        } else {
          self.ringBell()
        }
      case ControlCharacters.CtrlU.rawValue:
        // Delete whole line
        try self.setBuffer(editState: editState, new: "")
      case ControlCharacters.CtrlK.rawValue:
        // Delete to the end of the line
        if editState.deleteToEndOfLine() {
          try self.refreshLine(editState: editState)
        } else {
          self.ringBell()
        }
      case ControlCharacters.CtrlW.rawValue:
        // Delete previous word
        if editState.deletePreviousWord() {
          try self.refreshLine(editState: editState)
        } else {
          self.ringBell()
        }
      case ControlCharacters.Backspace.rawValue:
        // Delete character
        if editState.backspace() {
          try self.refreshLine(editState: editState)
        } else {
          self.ringBell()
        }
      case ControlCharacters.Esc.rawValue:
        try self.handleEscapeCode(editState: editState)
      default:
        // Read unicode character and insert it at the cursor position using UTF8 encoding
        var scalar = UInt32(ch)
        if ch >> 7 == 0 {
          // done
        } else if ch >> 5 == 0x6 {
          let ch2 = self.forceReadByte()
          scalar = (UInt32(ch & 0x1F) << 6) | UInt32(ch2 & 0x3F)
        } else if ch >> 4 == 0xE {
          let ch2 = self.forceReadByte()
          let ch3 = self.forceReadByte()
          scalar = (UInt32(ch & 0xF) << 12) | (UInt32(ch2 & 0x3F) << 6) | UInt32(ch3 & 0x3F)
        } else if ch >> 3 == 0x1E {
          let ch2 = self.forceReadByte()
          let ch3 = self.forceReadByte()
          let ch4 = self.forceReadByte()
          scalar = (UInt32(ch & 0x7) << 18) |
                   (UInt32(ch2 & 0x3F) << 12) |
                   (UInt32(ch3 & 0x3F) << 6) |
                   UInt32(ch4 & 0x3F)
        }
        let char = Character(UnicodeScalar(scalar) ?? UnicodeScalar(" "))
        if editState.insertCharacter(char) {
          // More input waiting is pasted text: draw the line once, after its last character
          if self.bytesAvailable == 0 {
            try refreshLine(editState: editState)
          }
        } else {
          self.ringBell()
        }
    }
    return nil
  }

  private func handleEscapeCode(editState: EditState) throws {
    let fst = self.readCharacter()
    switch fst {
      case "[":
        let snd = self.readCharacter()
        switch snd {
          // Handle multi-byte sequence ^[[0...
          case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
            let trd = self.readCharacter()
            switch trd {
              case "~":
                switch snd {
                  case "1", "7":
                    try self.moveHome(editState: editState)
                  case "3":
                    try self.deleteCharacter(editState: editState)
                  case "4":
                    try self.moveEnd(editState: editState)
                  default:
                    break
                }
              case ";":
                let fot = self.readCharacter()
                let fth = self.readCharacter()
                // Shift
                if fot == "2" {
                  switch fth {
                    case "C":
                      try self.moveRight(editState: editState)
                    case "D":
                      try self.moveLeft(editState: editState)
                    default:
                      break
                  }
                }
                break
              case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
                _ = self.readCharacter()
                // ignore these codes for now
                break
              default:
                break
            }
          // ^[...
          case "A":
            try self.moveHistory(editState: editState, direction: .previous)
          case "B":
            try self.moveHistory(editState: editState, direction: .next)
          case "C":
            // At the end of the line, Right accepts the hint
            if editState.cursorAtEnd, let hint = self.hintsCallback?(editState.buffer)?.0,
               !hint.isEmpty {
              try self.setBuffer(editState: editState, new: editState.buffer + hint)
            } else {
              try self.moveRight(editState: editState)
            }
          case "D":
            try self.moveLeft(editState: editState)
          case "H":
            try self.moveHome(editState: editState)
          case "F":
            try self.moveEnd(editState: editState)
          default:
            break
        }
      case "O":
        // ^[O...
        let snd = self.readCharacter()
        switch snd {
          case "H":
            try self.moveHome(editState: editState)
          case "F":
            try self.moveEnd(editState: editState)
          case "P":
            // F1
            break
          case "Q":
            // F2
            break
          case "R":
            // F3
            break
          case "S":
            // F4
            break
          default:
            break
        }
      case "b":
        // Alt+Left
        try self.moveToWordStart(editState: editState)
      case "f":
        // Alt+Right
        try self.moveToWordEnd(editState: editState)
      default:
        break
    }
  }

  private var cursorColumn: Int? {
    do {
      try self.output(text: AnsiCodes.cursorLocation)
    } catch {
      return nil
    }
    var buf = [UInt8]()
    while true {
      if let c = self.readByte() {
        if c == 82 { // "R"
          break
        }
        buf.append(c)
      } else {
        return nil
      }
    }
    guard buf[0] == 0x1B && buf[1] == 0x5B,
          let cursor = String(bytes: buf[2..<buf.count], encoding: .utf8)?.split(separator: ";"),
          cursor.count == 2 else {
      return nil
    }
    return Int(String(cursor[1]))
  }

  private var numColumns: Int {
    var winSize = winsize()
    if ioctl(1, UInt(TIOCGWINSZ), &winSize) == -1 || winSize.ws_col == 0 {
      return 80
    } else {
      return Int(winSize.ws_col)
    }
  }

  /// This constant is unfortunately not defined right now for usage in Swift; it is specific
  /// to macOS. Thus, this code is not portable!
  private static let FIONREAD: UInt = 0x4004667f

  private var bytesAvailable: Int {
    var available: Int = 0
    guard ioctl(self.inputFile, LineReader.FIONREAD, &available) >= 0 else {
      return 0
    }
    return available
  }

  private func updateCursorPos(editState: EditState) throws {
    if editState.requiresMatching() {
      try self.refreshLine(editState: editState)
    } else {
      let cursorWidth = editState.cursorWidth
      let numColumns = self.numColumns
      let cursorRows = cursorWidth / numColumns
      let cursorCols = cursorWidth % numColumns
      var commandBuf = AnsiCodes.cursorUp(editState.cursorRow) + AnsiCodes.beginningOfLine
      commandBuf += AnsiCodes.cursorDown(cursorRows)
      commandBuf += AnsiCodes.cursorForward(cursorCols)
      try self.output(text: commandBuf)
      editState.cursorRow = cursorRows
    }
  }

  private func refreshLine(editState: EditState,
                           decorate: Bool = true,
                           menu: CompletionMenu? = nil) throws {
    let cursorWidth = editState.cursorWidth
    let numColumns = self.numColumns
    let cursorRows = cursorWidth / numColumns
    let cursorCols = cursorWidth % numColumns
    // Back to where the prompt starts: the line may wrap over several rows
    var commandBuf = AnsiCodes.cursorUp(editState.cursorRow) +
                     AnsiCodes.beginningOfLine +
                     editState.promptProperties.apply(to: editState.prompt)
    if decorate, let idx = editState.matchingParen() {
      var fst = editState.buffer.index(before: editState.location)
      var snd = idx
      if fst > snd {
        snd = fst
        fst = idx
      }
      let one = String(editState.buffer.prefix(upTo: fst))
      let two = String(editState.buffer[editState.buffer.index(after: fst)..<snd])
      let three = String(editState.buffer.suffix(from: editState.buffer.index(after: snd)))
      let highlightProperties = editState.readProperties.with(editState.parenProperties)
      commandBuf += editState.readProperties.apply(to: one)
      commandBuf += highlightProperties.apply(to: String(editState.buffer[fst]))
      commandBuf += editState.readProperties.apply(to: two)
      commandBuf += highlightProperties.apply(to: String(editState.buffer[snd]))
      commandBuf += editState.readProperties.apply(to: three)
    } else {
      commandBuf += editState.readProperties.apply(to: editState.buffer)
    }
    var (hints, hintsWidth) = decorate && menu == nil ? try self.refreshHints(editState: editState) : ("", 0)
    if decorate, let menu = menu {
      // The hint previews the selected candidate
      let text = menu.candidates[menu.selected].text
      if text.hasPrefix(editState.buffer) && text.count > editState.buffer.count {
        let preview = String(text.dropFirst(editState.buffer.count))
        hints = self.completionMenuDetailProperties.apply(to: preview)
        hintsWidth = preview.count
      }
    }
    commandBuf += hints.isEmpty ? " " : hints
    // The row the line ends on. Text ending exactly at the right edge leaves the cursor on its
    // last row: the terminal wraps only when the next character comes.
    let lineWidth = editState.prompt.count + editState.buffer.count + max(1, hintsWidth)
    let endRow = (lineWidth - 1) / numColumns
    var menuRows = 0
    if let menu = menu {
      let rows = self.menuRows(menu)
      commandBuf += rows.map { "\r\n" + AnsiCodes.clearLine + $0 }.joined()
      menuRows = rows.count
    }
    commandBuf += AnsiCodes.clearCursorToBottom +
                  AnsiCodes.cursorUp(menuRows + endRow) +
                  AnsiCodes.beginningOfLine +
                  AnsiCodes.cursorDown(cursorRows) +
                  AnsiCodes.cursorForward(cursorCols)
    try self.output(text: commandBuf)
    editState.cursorRow = cursorRows
  }

  /// The rows of the completion menu: the visible candidates and a position indicator.
  private func menuRows(_ menu: CompletionMenu) -> [String] {
    let numColumns = self.numColumns
    let visible = menu.candidates[menu.top..<min(menu.top + self.completionMenuHeight,
                                                 menu.candidates.count)]
    let labelWidth = min(visible.map { $0.label.count }.max() ?? 0, numColumns - 2)
    var rows = visible.indices.map { index -> String in
      let candidate = menu.candidates[index]
      let label = String(candidate.label.prefix(labelWidth))
      let padded = label + String(repeating: " ", count: labelWidth - label.count)
      let detailWidth = numColumns - labelWidth - 5
      let detail = detailWidth > 0 ? String((candidate.detail ?? "").prefix(detailWidth)) : ""
      if index == menu.selected {
        let row = " " + padded + (detail.isEmpty ? "" : "  " + detail) + " "
        return self.completionMenuSelectedProperties.apply(to: row)
      }
      return " " + padded +
             (detail.isEmpty ? "" : "  " + self.completionMenuDetailProperties.apply(to: detail))
    }
    if menu.candidates.count > visible.count {
      rows.append(self.completionMenuDetailProperties.apply(
        to: " \(menu.selected + 1)/\(menu.candidates.count)"))
    }
    return rows
  }

  /// Sets `isReading` and returns the text `printAbove` queued so far.
  @discardableResult
  private func setReading(_ reading: Bool) -> [String] {
    self.messageLock.lock()
    defer { self.messageLock.unlock() }
    self.isReading = reading
    let messages = self.pendingMessages
    self.pendingMessages = []
    var drain = [UInt8](repeating: 0, count: 64)
    while self.messagePipe[0] >= 0 && read(self.messagePipe[0], &drain, drain.count) > 0 {}
    return messages
  }

  /// Reads the next input byte. Meanwhile, prints text from `printAbove` above the line and
  /// redraws the line (and `menu`) below it.
  private func readByte(editState: EditState, menu: CompletionMenu? = nil) throws -> UInt8? {
    guard self.messagePipe[0] >= 0 else {
      return self.readByte()
    }
    while true {
      var descriptors = [pollfd(fd: self.inputFile, events: Int16(POLLIN), revents: 0),
                         pollfd(fd: self.messagePipe[0], events: Int16(POLLIN), revents: 0)]
      guard poll(&descriptors, 2, -1) >= 0 || errno == EINTR else {
        return self.readByte()
      }
      if descriptors[1].revents & Int16(POLLIN) != 0 {
        let messages = self.setReading(true)
        if !messages.isEmpty {
          let lines = messages.joined(separator: "\n")
                              .split(separator: "\n", omittingEmptySubsequences: false)
          try self.output(text: AnsiCodes.cursorUp(editState.cursorRow) + AnsiCodes.beginningOfLine +
                                AnsiCodes.clearCursorToBottom +
                                lines.joined(separator: "\r\n") + "\r\n")
          editState.cursorRow = 0
          try self.refreshLine(editState: editState, menu: menu)
        }
      }
      if descriptors[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
        return self.readByte()
      }
    }
  }

  /// Waits up to `milliseconds` for input; tells a lone Esc from an escape sequence.
  private func waitForInput(milliseconds: Int32) -> Bool {
    var descriptor = pollfd(fd: self.inputFile, events: Int16(POLLIN), revents: 0)
    return poll(&descriptor, 1, milliseconds) > 0
  }

  private func readByte() -> UInt8? {
    var input: UInt8 = 0
    if read(self.inputFile, &input, 1) == 0 {
      return nil
    }
    return input
  }

  private func forceReadByte() -> UInt8 {
    var input: UInt8 = 0
    _ = read(self.inputFile, &input, 1)
    return input
  }

  private func readCharacter() -> Character? {
    var input: UInt8 = 0
    _ = read(self.inputFile, &input, 1)
    return Character(UnicodeScalar(input))
  }

  private func ringBell() {
    do {
      try self.output(character: ControlCharacters.Bell.character)
    } catch {
      // ignore failure
    }
  }

  private func output(character: ControlCharacters) throws {
    try self.output(character: character.character)
  }

  private func output(character: Character) throws {
    try self.output(text: String(character))
  }

  private func output(text: String) throws {
    if write(self.outputFile, text, text.utf8.count) == -1 {
      throw LineReaderError.generalError("Unable to write to output")
    }
  }

  private func setBuffer(editState: EditState, new buffer: String) throws {
    if editState.setBuffer(buffer) {
      _ = editState.moveEnd()
      try self.refreshLine(editState: editState)
    } else {
      self.ringBell()
    }
  }

  private func moveLeft(editState: EditState) throws {
    if editState.moveLeft() {
      try self.updateCursorPos(editState: editState)
    }
  }

  private func moveRight(editState: EditState) throws {
    if editState.moveRight() {
      try self.updateCursorPos(editState: editState)
    }
  }

  private func moveHome(editState: EditState) throws {
    if editState.moveHome() {
      try self.updateCursorPos(editState: editState)
    } else {
      self.ringBell()
    }
  }

  private func moveEnd(editState: EditState) throws {
    if editState.moveEnd() {
      try self.updateCursorPos(editState: editState)
    } else {
      self.ringBell()
    }
  }

  private func moveToWordStart(editState: EditState) throws {
    if editState.moveToWordStart() {
      try self.updateCursorPos(editState: editState)
    } else {
      self.ringBell()
    }
  }

  private func moveToWordEnd(editState: EditState) throws {
    if editState.moveToWordEnd() {
      try self.updateCursorPos(editState: editState)
    } else {
      self.ringBell()
    }
  }

  private func deleteCharacter(editState: EditState) throws {
    if editState.deleteCharacter() {
      try self.refreshLine(editState: editState)
    }
  }

  private func moveHistory(editState: EditState,
                           direction: LineReaderHistory.HistoryDirection) throws {
    // If we're at the end of history (editing the current line), push it into a temporary
    // buffer so it can be retrieved later
    if self.history.currentIndex == self.history.historyItems.count {
      tempBuf = editState.buffer
    } else if self.preserveHistoryEdits {
      self.history.replaceCurrent(editState.buffer)
    }
    if let historyItem = self.history.navigateHistory(direction: direction) {
      try self.setBuffer(editState: editState, new: historyItem)
    } else if case .next = direction {
      try self.setBuffer(editState: editState, new: tempBuf ?? "")
    } else {
      self.ringBell()
    }
  }

  /// The hint with its terminal colors, and its width in columns.
  private func refreshHints(editState: EditState) throws -> (String, Int) {
    guard let hintsCallback = self.hintsCallback,
          let (hint, properties) = hintsCallback(editState.buffer) else {
      return ("", 0)
    }
    let currentLineLength = editState.prompt.count + editState.buffer.count
    if hint.count + currentLineLength > self.numColumns {
      return ("", 0)
    } else {
      return (properties.apply(to: hint) + AnsiCodes.origTermColor, hint.count)
    }
  }

  private func withRawMode(body: () throws -> ()) throws {
    var originalTermios: termios = termios()
    defer {
      _ = tcsetattr(self.inputFile, TCSADRAIN, &originalTermios)
    }
    if tcgetattr(self.inputFile, &originalTermios) == -1 {
      throw LineReaderError.generalError("could not get term attributes")
    }
    var raw = originalTermios
    raw.c_iflag &= ~tcflag_t(BRKINT | ICRNL | INPCK | ISTRIP | IXON)
    raw.c_oflag &= ~tcflag_t(OPOST)
    raw.c_cflag |= tcflag_t(CS8)
    raw.c_lflag &= ~tcflag_t(ECHO | ICANON | IEXTEN | ISIG)
    // VMIN = 16
    raw.c_cc.16 = 1
    guard tcsetattr(self.inputFile, TCSADRAIN, &raw) >= 0 else {
      throw LineReaderError.generalError("Could not set raw mode")
    }
    try body()
  }
}
