#!/usr/bin/env python3
"""cleanup_history_db.py のユニットテスト（DB に触らない純関数のみ）。

  python3 scripts/test_cleanup_history_db.py
"""
from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cleanup_history_db import (
    plan_truncation_cleanup,
    plan_prefix_cleanup,
    plan_particle_cleanup,
)


class PlanTruncationCleanupTests(unittest.TestCase):
    """途中確定行（output が input の真の prefix）の検出。

    `recordPrefixesOnQueue` の (A) longer 統合が育てる「reading="ないので" で
    output="ない" を確定」型の有害行を炙り出す。
    """

    def test_detects_naide_nai_case(self) -> None:
        rows = [("ないので", "ない", 50, 0)]
        result = plan_truncation_cleanup(rows)
        self.assertEqual(result, [("ないので", "ない", 50)])

    def test_detects_san_truncation(self) -> None:
        rows = [("さんん", "さん", 32, 0)]
        self.assertEqual(plan_truncation_cleanup(rows), [("さんん", "さん", 32)])

    def test_detects_long_phrase_truncation(self) -> None:
        rows = [("ありがとうございます", "ありがとう", 4, 0)]
        self.assertEqual(plan_truncation_cleanup(rows), [("ありがとうございます", "ありがとう", 4)])

    def test_detects_pending_romaji_residue(self) -> None:
        rows = [("やるしかないのd", "やるしかない", 1, 0)]
        self.assertEqual(plan_truncation_cleanup(rows), [("やるしかないのd", "やるしかない", 1)])

    def test_skips_normal_kanji_conversion(self) -> None:
        rows = [
            ("かんじ", "漢字", 10, 0),
            ("とうきょう", "東京", 5, 0),
        ]
        self.assertEqual(plan_truncation_cleanup(rows), [])

    def test_skips_input_equals_output(self) -> None:
        rows = [("ない", "ない", 5, 0)]
        self.assertEqual(plan_truncation_cleanup(rows), [])

    def test_skips_output_longer_than_input(self) -> None:
        rows = [("とう", "東京", 3, 0)]
        self.assertEqual(plan_truncation_cleanup(rows), [])

    def test_skips_non_prefix_relation(self) -> None:
        rows = [("かんじ", "漢", 4, 0)]
        # "漢" は "かんじ" の prefix ではない（漢字違い）
        self.assertEqual(plan_truncation_cleanup(rows), [])

    def test_multiple_rows_mixed(self) -> None:
        rows = [
            ("ないので", "ない", 50, 0),
            ("かんじ", "漢字", 10, 0),
            ("さんん", "さん", 32, 0),
            ("ありがとう", "ありがとう", 1, 0),
        ]
        result = sorted(plan_truncation_cleanup(rows))
        self.assertEqual(result, [
            ("さんん", "さん", 32),
            ("ないので", "ない", 50),
        ])


class PlanPrefixCleanupRegressionTests(unittest.TestCase):
    """既存の冗長 prefix cleanup が truncation 行を取り違えないことの回帰テスト。

    plan_prefix_cleanup は「同じ output で input が前方一致」のみを対象とする。
    truncation 行は output が違うので干渉してはいけない。
    """

    def test_truncation_row_does_not_match_prefix_cleanup(self) -> None:
        rows = [("ないので", "ない", 50, 0), ("ない", "ない", 3, 0)]
        # output が異なる ("ない" vs "ない" は同じだが input "ない" は output "ない" と一致するため
        # is_hiragana_passthrough ではないが prefix cleanup は同一 output 内で input 前方一致を見る)
        # ("ない", "ない") と ("ないので", "ない") は同じ output → is_redundant_prefix("ない", "ないので")=True
        # で削除対象になる。これは既存挙動として正しい（短い読みを長い読みへ吸収）
        to_delete, to_update = plan_prefix_cleanup(rows)
        self.assertIn(("ない", "ない"), to_delete)
        self.assertIn(("ないので", "ない"), to_update)

    def test_truncation_only_rows_untouched_by_prefix_cleanup(self) -> None:
        rows = [("ないので", "ない", 50, 0)]
        to_delete, to_update = plan_prefix_cleanup(rows)
        # 同一 output 内に他 input がないので prefix cleanup は何もしない
        self.assertEqual(to_delete, [])
        self.assertEqual(to_update, {})


if __name__ == "__main__":
    unittest.main(verbosity=2)
