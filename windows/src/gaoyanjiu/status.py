from __future__ import annotations

# 与 macOS SubmissionStatusClassifier 相同的终态子串（小写后包含匹配）。
TERMINAL_KEYWORDS = (
    "accept",
    "publish",
    "reject",
    "withdraw",
    "declin",
    "cancel",
    "已接受",
    "接收",
    "录用",
    "已发表",
    "拒稿",
    "已拒",
    "撤稿",
    "已撤",
)


def is_terminal(status: str) -> bool:
    value = status.lower()
    return any(keyword in value for keyword in TERMINAL_KEYWORDS)
