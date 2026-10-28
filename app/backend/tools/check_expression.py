"""保守比较MySQL CHECK表达式，忽略服务端添加的括号／字符集前缀。"""

import re
from decimal import Decimal

TOKEN = re.compile(
    r"'(?:''|\\.|[^'])*'|`[^`]+`|[A-Za-z_][A-Za-z_0-9]*|\d+(?:\.\d+)?|<>|!=|>=|<=|\S"
)


def canonical_check(expression):
    tokens = []
    for token in TOKEN.findall(str(expression)):
        if token.lower() in {"_utf8mb4", "_utf8mb3", "_utf8", "_latin1"}:
            continue
        if token.startswith("'"):
            tokens.append(token)
        elif re.fullmatch(r"\d+(?:\.\d+)?", token):
            tokens.append(str(Decimal(token).normalize()))
        else:
            tokens.append(token.strip("`").lower())

    def parse(items):
        if not items:
            return ()
        # 去掉包住整个表达式的括号，保留有意义的布尔分组。
        while items[0] == "(" and items[-1] == ")":
            depth = 0
            closing = None
            for position, token in enumerate(items):
                depth += (token == "(") - (token == ")")
                if depth == 0:
                    closing = position
                    break
            if closing != len(items) - 1:
                break
            items = items[1:-1]
            if not items:
                return ()
        for operators in ({","}, {"or"}, {"and"}, {"=", "<>", "!=", "<", ">", "<=", ">="}):
            depth, between = 0, False
            for position, token in enumerate(items):
                depth += (token == "(") - (token == ")")
                if depth:
                    continue
                if token == "between":
                    between = True
                elif token == "and" and between:
                    between = False
                elif token in operators:
                    return (token, parse(items[:position]), parse(items[position + 1 :]))
        # 处理函数参数／IN列表中的括号；无法规范化的语法保留token，宁可报差异。
        result, position = [], 0
        while position < len(items):
            if items[position] != "(":
                result.append(items[position])
                position += 1
                continue
            depth, end = 1, position + 1
            while end < len(items) and depth:
                depth += (items[end] == "(") - (items[end] == ")")
                end += 1
            if depth:
                raise ValueError("CHECK括号不匹配。")
            result.append(parse(items[position + 1 : end - 1]))
            position = end
        return tuple(result)

    return parse(tokens)
