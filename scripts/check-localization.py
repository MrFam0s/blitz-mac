#!/usr/bin/env python3
"""Audit Blitz Neo's explicit UI catalogs without compiling or changing files.

This is a lexical audit of the supported Swift localization call sites, not a
Swift type checker. Nested strings/interpolations, raw strings, multiline
indentation, Unicode escapes and nested comments are read as Swift tokens.
Unsupported/unterminated syntax is reported, never silently guessed.
"""
from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass, field
import json
from pathlib import Path
import re
import sys
import tempfile
import unittest


class AuditError(ValueError):
    pass


@dataclass
class Token:
    kind: str
    value: str
    start: int
    children: list[Token] = field(default_factory=list)


class SwiftScanner:
    def __init__(self, source: str):
        self.source = source

    def error(self, offset: int, message: str):
        line = self.source.count("\n", 0, offset) + 1
        raise AuditError(f"line {line}: {message}")

    def scan(self) -> list[Token]:
        tokens, _ = self.code(0)
        return tokens

    def comment(self, start: int) -> int:
        s, i, depth = self.source, start + 2, 1
        while i < len(s):
            if s.startswith("/*", i):
                depth += 1
                i += 2
            elif s.startswith("*/", i):
                depth -= 1
                i += 2
                if not depth:
                    return i
            else:
                i += 1
        self.error(start, "unterminated block comment")

    def code(self, start: int, interpolation: bool = False) -> tuple[list[Token], int]:
        s, i, depth, tokens = self.source, start, 0, []
        while i < len(s):
            c = s[i]
            if c.isspace():
                i += 1
                continue
            if s.startswith("//", i):
                end = s.find("\n", i)
                i = len(s) if end < 0 else end + 1
                continue
            if s.startswith("/*", i):
                i = self.comment(i)
                continue
            quote = i
            while quote < len(s) and s[quote] == "#":
                quote += 1
            if c == '"' or (quote > i and quote < len(s) and s[quote] == '"'):
                token, i = self.string(i, quote - i)
                tokens.append(token)
                continue
            if c == ")" and interpolation:
                if depth == 0:
                    return tokens, i + 1
                depth -= 1
            elif c == "(" and interpolation:
                depth += 1
            if c.isalpha() or c == "_":
                end = i + 1
                while end < len(s) and (s[end].isalnum() or s[end] == "_"):
                    end += 1
                tokens.append(Token("identifier", s[i:end], i))
                i = end
            else:
                tokens.append(Token("punctuation", c, i))
                i += 1
        if interpolation:
            self.error(start, "unterminated string interpolation")
        return tokens, i

    def string(self, start: int, hashes: int) -> tuple[Token, int]:
        s = self.source
        quote_start = start + hashes
        multiline = s.startswith('"""', quote_start)
        quote = '"""' if multiline else '"'
        closing = quote + "#" * hashes
        escape = "\\" + "#" * hashes
        i = quote_start + len(quote)
        parts, children, argument_count = [], [], 0
        while i < len(s):
            if s.startswith(closing, i):
                text = "".join(parts)
                if multiline:
                    prefix = s[s.rfind("\n", 0, i) + 1:i]
                    if prefix.strip():
                        self.error(i, "multiline closing delimiter must start on its own line")
                    text = self.multiline_value(text, prefix, start)
                text = self.decode(text, escape, start)
                return Token("string", text, start, children), i + len(closing)
            if s.startswith(escape + "(", i):
                nested, end = self.code(i + len(escape) + 1, interpolation=True)
                children.extend(nested)
                parts.append("{" + str(argument_count) + "}")
                argument_count += 1
                i = end
                continue
            if s.startswith(escape, i):
                # Preserve the escape until after multiline indentation removal.
                end = i + len(escape) + 1
                parts.append(s[i:end])
                i = end
            else:
                parts.append(s[i])
                i += 1
        self.error(start, "unterminated string literal")

    def multiline_value(self, text: str, indent: str, start: int) -> str:
        if not text.startswith("\n"):
            self.error(start, "multiline literal must begin with a newline")
        text = text[1:]
        if not text.endswith(indent):
            self.error(start, "invalid multiline closing indentation")
        if indent:
            text = text[:-len(indent)]
        if not text.endswith("\n"):
            self.error(start, "multiline closing delimiter must follow a newline")
        text = text[:-1]
        lines = text.split("\n")
        for index, line in enumerate(lines):
            if line.startswith(indent):
                lines[index] = line[len(indent):]
            elif not line.strip():
                lines[index] = ""
            else:
                self.error(start, "multiline content has less indentation than its closing delimiter")
        return "\n".join(lines)

    def decode(self, text: str, escape: str, start: int) -> str:
        values = {"0": "\0", "n": "\n", "r": "\r", "t": "\t", '"': '"', "'": "'", "\\": "\\"}
        output, i = [], 0
        while i < len(text):
            if not text.startswith(escape, i):
                output.append(text[i])
                i += 1
                continue
            i += len(escape)
            if i >= len(text):
                self.error(start, "incomplete string escape")
            c = text[i]
            if c in values:
                output.append(values[c])
                i += 1
            elif c == "u" and text.startswith("u{", i):
                end = text.find("}", i + 2)
                digits = text[i + 2:end]
                if end < 0 or not re.fullmatch(r"[0-9A-Fa-f]{1,8}", digits):
                    self.error(start, "invalid Swift Unicode escape")
                value = int(digits, 16)
                if value > 0x10FFFF or 0xD800 <= value <= 0xDFFF:
                    self.error(start, "invalid Unicode scalar")
                output.append(chr(value))
                i = end + 1
            elif c == "\n":
                # Swift multiline line continuation consumes following indentation.
                i += 1
                while i < len(text) and text[i] in " \t":
                    i += 1
            else:
                self.error(start, f"unsupported string escape {escape + c!r}")
        return "".join(output)


def token_sequences(tokens: list[Token]):
    yield tokens
    for token in tokens:
        if token.children:
            yield from token_sequences(token.children)


def message_literals(tokens: list[Token]) -> list[Token]:
    result = []
    for sequence in token_sequences(tokens):
        values = [t.value for t in sequence]
        for index, token in enumerate(sequence):
            if token.kind == "identifier" and values[index:index + 4] == ["L10n", ".", "tr", "("]:
                if index + 4 < len(sequence) and sequence[index + 4].kind == "string":
                    result.append(sequence[index + 4])
            # A typed display dictionary: its keys are stable protocol values;
            # only the literal values are localization messages.
            signature = ["[", "String", ":", "L10n", ".", "Message", "]", "=", "["]
            if token.kind != "punctuation" or values[index:index + len(signature)] != signature:
                continue
            pos, depth = index + len(signature), 1
            while pos < len(sequence) and depth:
                current = sequence[pos]
                if current.value == "[" and current.kind != "string":
                    depth += 1
                elif current.value == "]" and current.kind != "string":
                    depth -= 1
                elif current.kind == "punctuation" and current.value == ":" and depth == 1:
                    if pos + 1 >= len(sequence) or sequence[pos + 1].kind != "string":
                        raise AuditError("typed L10n.Message dictionary has a nonliteral value; extend this audit explicitly")
                    result.append(sequence[pos + 1])
                pos += 1
            if depth:
                raise AuditError("unterminated typed L10n.Message dictionary")
    return result


def catalog_tables(tokens: list[Token]) -> list[str]:
    values = [t.value for t in tokens]
    for i in range(len(tokens)):
        if tokens[i].kind == "identifier" and values[i:i + 4] == ["let", "tables", "=", "["]:
            result = []
            for token in tokens[i + 4:]:
                if token.kind == "string":
                    result.append(token.value)
                elif token.value == "]":
                    return result
                elif token.value != ",":
                    raise AuditError("L10n.tables must remain a literal list for this audit")
    raise AuditError("cannot find L10n.tables")


def parse_catalog(path: Path) -> dict[str, str]:
    # Current catalogs deliberately use quoted .strings entries with JSON-compatible
    # escapes. Fail explicitly for other OpenStep syntax rather than guessing.
    text = path.read_text(encoding="utf-8-sig")
    decoder, values, i = json.JSONDecoder(), {}, 0
    def whitespace(offset):
        while offset < len(text):
            if text[offset].isspace():
                offset += 1
            elif text.startswith("//", offset):
                end = text.find("\n", offset)
                offset = len(text) if end < 0 else end + 1
            elif text.startswith("/*", offset):
                end = text.find("*/", offset + 2)
                if end < 0:
                    raise AuditError(f"{path}: unterminated catalog comment")
                offset = end + 2
            else:
                break
        return offset
    while (i := whitespace(i)) < len(text):
        line = text.count("\n", 0, i) + 1
        try:
            key, i = decoder.raw_decode(text, i)
            i = whitespace(i)
            if text[i:i + 1] != "=":
                raise ValueError("expected '='")
            i = whitespace(i + 1)
            value, i = decoder.raw_decode(text, i)
            i = whitespace(i)
            if text[i:i + 1] != ";":
                raise ValueError("expected ';'")
            i += 1
            if not isinstance(key, str) or not isinstance(value, str):
                raise ValueError("keys and values must be quoted strings")
            if key in values:
                raise ValueError(f"duplicate key {key!r}")
            values[key] = value
        except (ValueError, IndexError) as error:
            raise AuditError(f"{path}:{line}: {error}") from error
    return values


def audit(root: Path) -> tuple[list[str], str]:
    errors = []
    language_source = root / "src/services/AppLanguageService.swift"
    tables = catalog_tables(SwiftScanner(language_source.read_text()).scan())
    catalogs = {}
    for language in ("de", "en"):
        merged = {}
        for table in tables:
            path = root / "src/resources" / f"{language}.lproj" / f"{table}.strings"
            try:
                catalog = parse_catalog(path)
            except (AuditError, OSError) as error:
                errors.append(str(error))
                catalog = {}
            catalogs[(language, table)] = catalog
            for key, value in catalog.items():
                placeholders = lambda x: Counter(re.findall(r"\{[0-9]+\}", x))
                if placeholders(key) != placeholders(value):
                    errors.append(f"{language}/{table}: placeholder mismatch for {key!r}")
                if key in merged and merged[key] != value:
                    errors.append(f"{language}/{table}: inconsistent shared translation for {key!r}")
                merged[key] = value
        catalogs[language] = merged
    for table in tables:
        german, english = catalogs[("de", table)], catalogs[("en", table)]
        for key in sorted(set(german) ^ set(english)):
            missing = "en" if key in german else "de"
            errors.append(f"{missing}/{table}: missing key {key!r}")
    occurrences, source_keys, swift_files = 0, set(), 0
    for path in sorted((root / "src").rglob("*.swift")):
        # Templates are a different app's source, not Blitz's executable target.
        if "templates" in path.relative_to(root / "src").parts:
            continue
        source = path.read_text()
        swift_files += 1
        try:
            messages = message_literals(SwiftScanner(source).scan())
        except AuditError as error:
            errors.append(f"{path.relative_to(root)}: {error}")
            continue
        occurrences += len(messages)
        for token in messages:
            source_keys.add(token.value)
            for language in ("de", "en"):
                if token.value not in catalogs[language]:
                    line = source.count("\n", 0, token.start) + 1
                    errors.append(f"{path.relative_to(root)}:{line}: missing {language} catalog key {token.value!r}")
    summary = (f"{swift_files} Swift files; {occurrences} explicit localized messages; "
               f"{len(source_keys)} unique source keys; {len(catalogs['en'])} catalog keys; "
               f"{len(tables)} DE/EN table pairs")
    return sorted(set(errors)), summary


class ScannerTests(unittest.TestCase):
    def messages(self, source):
        return [t.value for t in message_literals(SwiftScanner(source).scan())]

    def test_nested_interpolation_and_escaped_quote(self):
        self.assertEqual(self.messages(r'L10n.tr("Hi \(name ?? L10n.tr("Gast")) \"\(count)\"")'),
                         ['Hi {0} "{1}"', 'Gast'])

    def test_comments_do_not_create_calls(self):
        self.assertEqual(self.messages('/* nested /* L10n.tr("No") */ x */\n// L10n.tr("No")\nL10n.tr("Ja")'), ['Ja'])

    def test_raw_strings_and_unicode(self):
        self.assertEqual(self.messages(r'L10n.tr(#"Raw \n \#(name)"#); L10n.tr("A\u{2026}")'),
                         ['Raw \\n {0}', 'A…'])

    def test_multiline_indentation_and_blank_lines(self):
        source = 'L10n.tr("""\n    Zeile 1\n      Zeile 2\n\n    Wert \\(value)\n    """)'
        self.assertEqual(self.messages(source), ['Zeile 1\n  Zeile 2\n\nWert {0}'])

    def test_typed_dictionary_only_localizes_values(self):
        self.assertEqual(self.messages('let a: [String: L10n.Message] = ["READY": "Bereit", "\u0057AIT": "Warten"]'),
                         ['Bereit', 'Warten'])

    def test_string_contents_are_not_code_tokens(self):
        self.assertEqual(self.messages('["L10n", ".", "tr", "(", "Not a call"]'), [])
        self.assertEqual(self.messages('let a: [String: L10n.Message] = ["PUNCTUATION": ":"]'), [':'])

    def test_catalog_rejects_duplicate_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Localizable.strings"
            path.write_text('"Save" = "Speichern"; "Save" = "Sichern";')
            with self.assertRaisesRegex(AuditError, "duplicate key"):
                parse_catalog(path)

    def test_catalog_preserves_quoted_comments_and_newlines(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Localizable.strings"
            path.write_text('// comment\n"URL" = "https://example.com"; /* comment */\n'
                            + json.dumps('Line\n{0}') + ' = ' + json.dumps('Zeile\n{0}') + ';')
            self.assertEqual(parse_catalog(path), {'URL': 'https://example.com', 'Line\n{0}': 'Zeile\n{0}'})

    def test_fail_on_unsupported_or_unterminated_input(self):
        for source in ['L10n.tr("unfinished)', r'L10n.tr("bad\q")', '/* unfinished']:
            with self.assertRaises(AuditError):
                self.messages(source)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--self-test", action="store_true", help="also run scanner regression tests")
    args = parser.parse_args()
    if args.self_test:
        result = unittest.TextTestRunner(verbosity=1).run(unittest.defaultTestLoader.loadTestsFromTestCase(ScannerTests))
        if not result.wasSuccessful():
            return 1
    try:
        errors, summary = audit(args.root.resolve())
    except (AuditError, OSError) as error:
        print(f"Localization audit failed: {error}", file=sys.stderr)
        return 1
    for error in errors:
        print(error, file=sys.stderr)
    print(f"Localization audit {'FAILED' if errors else 'passed'}: {summary}; {len(errors)} error(s).")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
