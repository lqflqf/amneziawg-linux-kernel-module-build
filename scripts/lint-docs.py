#!/usr/bin/env python3
"""Check the Markdown files for some ASD-STE100 Simplified Technical English rules.

Usage: scripts/lint-docs.py [file.md ...]
Without arguments, the script checks README.md, docs/*.md, and keys/*.md.

Errors (exit code 1):
  * Words and phrases that ASD-STE100 does not approve, or that have more than one meaning.
Warnings:
  * Sentences with more than 25 words.

The script does not check code blocks, inline code, link targets, or URLs.
A check by a person is also necessary. This script finds only the frequent problems.
"""

import glob
import re
import sys

# Word or phrase -> recommended replacement.
DENY = {
    "should": "must / can / it is recommended to",
    "ensure": "make sure",
    "please": "(remove)",
    "utilize": "use",
    "utilise": "use",
    "in order to": "to",
    "e.g.": "for example",
    "i.e.": "that is",
    "etc.": "(give the full list)",
    "via": "through / with",
    "simply": "(remove)",
    "basically": "(remove)",
    "might": "can",
    "may": "can",
    "would": "(use a direct statement)",
    "shall": "must",
    "whilst": "while",
    "leverage": "use",
    "obviously": "(remove)",
    "just": "only / (remove)",
}
MAX_WORDS = 25


def clean(text):
    text = re.sub(r"```.*?```", "", text, flags=re.S)
    text = re.sub(r"`[^`\n]*`", "CODE", text)
    text = re.sub(r"\]\([^)]*\)", "]", text)
    text = re.sub(r"<https?://[^>]*>", "URL", text)
    text = re.sub(r"https?://\S+", "URL", text)
    return text


def main(files):
    if not files:
        files = ["README.md"] + sorted(glob.glob("docs/*.md")) + sorted(glob.glob("keys/*.md"))
    errors = warnings = 0
    for path in files:
        with open(path) as f:
            text = clean(f.read())
        for lineno, line in enumerate(text.splitlines(), 1):
            for word, fix in DENY.items():
                pattern = r"(?<![\w-])" + re.escape(word) + (r"(?![\w-])" if word[-1].isalnum() else "")
                if re.search(pattern, line, re.I):
                    print(f"{path}:{lineno}: error: \"{word}\" is not approved. Use: {fix}")
                    errors += 1
        # Sentences: join the lines of a paragraph. Lists, tables, and headings are separate.
        for block in re.split(r"\n\s*\n|\n(?=\s*(?:[-*|#]|\d+\.)\s)", text):
            block = " ".join(block.split())
            for sentence in re.split(r"(?<=[.!?:])\s+", block):
                words = re.findall(r"[A-Za-z0-9][\w'/-]*", sentence)
                if len(words) > MAX_WORDS and "|" not in sentence:
                    print(f"{path}: warning: sentence with {len(words)} words: {sentence[:80]}...")
                    warnings += 1
    print(f"{errors} errors, {warnings} warnings")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
