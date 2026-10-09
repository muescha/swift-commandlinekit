//
//  LineCompletion.swift
//  CommandLineKit
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

/// A candidate for the completion menu of `LineReader` (see `setCompletionMenuCallback`).
public struct LineCompletion {

  /// The whole line after choosing this candidate.
  public let text: String

  /// What the menu shows for this candidate, usually just the completed name.
  public let label: String

  /// Shown dimmed next to the label, e.g. a signature or a type.
  public let detail: String?

  public init(text: String, label: String? = nil, detail: String? = nil) {
    self.text = text
    self.label = label ?? text
    self.detail = detail
  }
}

/// What opened the completion menu of `LineReader`; see `setCompletionMenuCallback`.
public enum LineCompletionTrigger: Equatable {

  /// The user pressed Tab.
  case tab

  /// The line ended in one of `LineReader.completionMenuTriggers`: typed, or by accepting a
  /// candidate. The menu then opens only when there are candidates, so a callback may want to
  /// skip lookups here that are slow or have side effects, and do them only for Tab.
  case typed(Character)
}
