import pytest

from novel.textnorm import fold, query


def test_fullwidth_and_length():
    original = "".join(chr(code) for code in range(0xFF01, 0xFF5F)) + "\u3000"
    assert fold(original) == "".join(chr(code).lower() for code in range(33, 127)) + " "
    assert len(fold(original)) == len(original)


@pytest.mark.parametrize(("original", "expected"), [
    ("İÉẞΣß", "İéßσß"), ("繁體简体", "繁體简体"), ("ABC中文", "abc中文"), ("", ""),
])
def test_lowercase_preserves_length(original, expected):
    assert fold(original) == expected
    assert len(fold(original)) == len(original)


def test_query_whitespace():
    assert query(" \tＡＢＣ　 \n 中文\r\n 书 \t") == "abc 中文 书"
    assert query("\u3000\n\t") == ""
