import XCTest
import Foundation
@testable import KeynacoCore
@testable import KeynacoTestSupport

/// `docs/domain/scenarios.md` の入力トレースを回帰用に固定化したテスト。
/// 辞書に依存しない箇所は `AzooKeyConverting` のモックで再現する。

// MARK: - S-01 用モック（候補に「漢字」のみ返す）

private final class ScenarioS01KanjiMockConverter: BaseAzooKeyStub {
    override func requestCandidates(
        hiragana: String,
        leftSideContext: String?,
        richCandidates: Bool,
        options: AzooKeyFetchOptions
    ) -> [AzooKeyCandidate] {
        _ = (leftSideContext, richCandidates, options)
        return hiragana == "かんじ" ? [.text("漢字")] : [.text("□")]
    }
}

// MARK: - なので dismiss 用モック（AzooKey がカタカナのみ返すケース）

private final class NanodeFunctionalWordStub: BaseAzooKeyStub {
    override func requestCandidates(
        hiragana: String,
        leftSideContext: String?,
        richCandidates: Bool,
        options: AzooKeyFetchOptions
    ) -> [AzooKeyCandidate] {
        _ = (leftSideContext, richCandidates, options)
        return hiragana == "なので" ? [.text("ナノデ")] : []
    }
}

final class ScenarioRegressionTests: InputHandlerTestCase {

    /// **S-01**: `k` `a` `n` `j` `i` Space Enter → 確定「漢字」。
    func testS01_kanji_space_enter_insertsKanji() {
        let mock = ScenarioS01KanjiMockConverter()
        var h = InputHandler(db: DatabaseManager(inMemory: true), azooKeyConverter: mock)
        let c = MockTextClient()

        for ch in "kanji" {
            _ = h.handle(
                keyCode: 0,
                characters: String(ch),
                baseCharacters: String(ch),
                modifiers: [],
                candidate: .hidden,
                client: c
            )
        }
        XCTAssertEqual(h.state.composedHiragana, "かんじ")

        let (_, spaceAction) = h.handle(
            keyCode: KeyCode.space,
            characters: nil,
            baseCharacters: nil,
            modifiers: [],
            candidate: .hidden,
            client: c
        )
        guard case .show = spaceAction else {
            XCTFail("Space で .show を返すはず: \(spaceAction)")
            return
        }

        _ = h.handle(
            keyCode: KeyCode.enter,
            characters: nil,
            baseCharacters: nil,
            modifiers: [],
            candidate: CandidateContext(isVisible: true, selectedRow: 0, selectedText: "漢字"),
            client: c
        )
        XCTAssertEqual(c.inserted.joined(), "漢字")
    }

    /// **S-04**: `t` Shift+`O` Shift+`K` `y` `o` Enter → `tOKyo`（シナリオ記載の混在大文字トレース）
    func testS04_tShiftOShiftKyo_enter_insertsTokyoStyleWord() {
        type(chars: "t", base: "t")
        type(chars: "O", base: "o", modifiers: .shift)
        type(chars: "K", base: "k", modifiers: .shift)
        type(chars: "y", base: "y")
        type(chars: "o", base: "o")
        press(keyCode: KeyCode.enter)
        assertInserted("tOKyo")
    }

    /// **S-05**: `n` `a` `n` `o` `d` `e` → whileTyping で dismiss。
    /// 「なので」は接続助詞（HiraganaPreferredBuiltins 登録済み）のため打鍵中は候補を出さない。
    /// AzooKey がカタカナ「ナノデ」のみを返しても「ナノデ」に誤フォーカスしないことも兼ねて確認する。
    func testS05_nanode_whileTyping_dismisses() {
        setUpWithConverter(NanodeFunctionalWordStub())
        typeRomaji("nanod")
        let (_, action) = type(chars: "e", base: "e")
        XCTAssertEqual(handler.state.composedHiragana, "なので")
        assertDismiss(action, "なので は接続助詞なので whileTyping では dismiss されるはず")
    }
}
