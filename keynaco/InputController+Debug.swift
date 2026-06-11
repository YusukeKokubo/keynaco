#if DEBUG

import Cocoa
import KeynacoCore
import InputMethodKit

extension InputController {

    func runKeyDownPublishingSnapshot(
        keyCode: UInt16,
        characters: String?,
        baseCharacters: String?,
        modifiers: NSEvent.ModifierFlags,
        adapter: IMKTextInputAdapter,
        imkSenderForSurrounding: Any?
    ) -> Bool {
        let consumed = runKeyDown(
            keyCode: keyCode,
            characters: characters,
            baseCharacters: baseCharacters,
            modifiers: modifiers,
            adapter: adapter,
            imkSenderForSurrounding: imkSenderForSurrounding
        )
        let snap = handler.snapshot(markedText: adapter.lastMarkedText)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .imeStateDidUpdate,
                object: nil,
                userInfo: ["snapshot": snap]
            )
        }
        return consumed
    }
}

#endif
