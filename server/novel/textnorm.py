import re


def fold(s: str) -> str:
    result = []
    for char in s:
        code = ord(char)
        if 0xFF01 <= code <= 0xFF5E:
            char = chr(code - 0xFEE0)
        elif code == 0x3000:
            char = " "
        lower = char.lower()
        result.append(lower if len(lower) == 1 else char)
    return "".join(result)


def query(s: str) -> str:
    return re.sub(r"\s+", " ", fold(s).strip())
