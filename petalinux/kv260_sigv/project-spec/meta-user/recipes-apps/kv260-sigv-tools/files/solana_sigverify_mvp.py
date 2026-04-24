#!/usr/bin/env python3
"""Reference extractor and framer for the KV260 sigverify pipeline."""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import struct
import sys
import zlib
from dataclasses import dataclass
from pathlib import Path


BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
BASE58_INDEX = {char: index for index, char in enumerate(BASE58_ALPHABET)}
FRAME_MAGIC = b"SIGV"
FRAME_VERSION = 1


class ParseError(ValueError):
    """Raised when a serialized Solana transaction is malformed."""


@dataclass(frozen=True)
class VerificationJob:
    index: int
    pubkey: bytes
    signature: bytes


@dataclass(frozen=True)
class ParsedTransaction:
    transaction_bytes: bytes
    message_bytes: bytes
    message_version: str
    num_required_signatures: int
    jobs: tuple[VerificationJob, ...]

    def to_summary(self) -> dict[str, object]:
        return {
            "transaction_size": len(self.transaction_bytes),
            "message_size": len(self.message_bytes),
            "message_version": self.message_version,
            "num_required_signatures": self.num_required_signatures,
            "message_hex": self.message_bytes.hex(),
            "jobs": [
                {
                    "index": job.index,
                    "pubkey_hex": job.pubkey.hex(),
                    "signature_hex": job.signature.hex(),
                }
                for job in self.jobs
            ],
        }


def decode_base58(value: str) -> bytes:
    number = 0
    for char in value.strip():
        if char not in BASE58_INDEX:
            raise ParseError(f"invalid base58 character: {char!r}")
        number = number * 58 + BASE58_INDEX[char]

    decoded = b"" if number == 0 else number.to_bytes((number.bit_length() + 7) // 8, "big")
    leading_zeros = len(value) - len(value.lstrip("1"))
    return b"\x00" * leading_zeros + decoded


def encode_compact_u16(value: int) -> bytes:
    if not 0 <= value <= 0xFFFF:
        raise ValueError("compact-u16 value out of range")

    encoded = bytearray()
    remaining = value
    while True:
        byte = remaining & 0x7F
        remaining >>= 7
        if remaining:
            encoded.append(byte | 0x80)
        else:
            encoded.append(byte)
            break
    return bytes(encoded)


def decode_compact_u16(data: bytes, offset: int) -> tuple[int, int]:
    value = 0
    shift = 0
    for _ in range(3):
        if offset >= len(data):
            raise ParseError("truncated compact-u16")
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        if byte & 0x80 == 0:
            if value > 0xFFFF:
                raise ParseError("compact-u16 overflow")
            return value, offset
        shift += 7
    raise ParseError("compact-u16 exceeds 3 bytes")


def _take(data: bytes, offset: int, size: int, label: str) -> tuple[bytes, int]:
    end = offset + size
    if end > len(data):
        raise ParseError(f"truncated {label}")
    return data[offset:end], end


def _skip_compiled_instructions(data: bytes, offset: int) -> tuple[int, int]:
    instruction_count, offset = decode_compact_u16(data, offset)
    for _ in range(instruction_count):
        _, offset = _take(data, offset, 1, "program_id_index")
        account_index_count, offset = decode_compact_u16(data, offset)
        _, offset = _take(data, offset, account_index_count, "instruction account indices")
        data_length, offset = decode_compact_u16(data, offset)
        _, offset = _take(data, offset, data_length, "instruction data")
    return instruction_count, offset


def _skip_address_table_lookups(data: bytes, offset: int) -> tuple[int, int]:
    lookup_count, offset = decode_compact_u16(data, offset)
    for _ in range(lookup_count):
        _, offset = _take(data, offset, 32, "lookup account key")
        writable_count, offset = decode_compact_u16(data, offset)
        _, offset = _take(data, offset, writable_count, "writable lookup indices")
        readonly_count, offset = decode_compact_u16(data, offset)
        _, offset = _take(data, offset, readonly_count, "readonly lookup indices")
    return lookup_count, offset


def parse_message(message_bytes: bytes) -> dict[str, object]:
    if not message_bytes:
        raise ParseError("transaction is missing message bytes")

    version_byte = message_bytes[0]
    if version_byte & 0x80:
        version = version_byte & 0x7F
        if version != 0:
            raise ParseError(f"unsupported message version: {version}")
        header_offset = 1
        message_version = "v0"
    else:
        header_offset = 0
        message_version = "legacy"

    if header_offset + 3 > len(message_bytes):
        raise ParseError("truncated message header")

    num_required_signatures = message_bytes[header_offset]
    num_readonly_signed = message_bytes[header_offset + 1]
    num_readonly_unsigned = message_bytes[header_offset + 2]
    offset = header_offset + 3

    account_key_count, offset = decode_compact_u16(message_bytes, offset)
    static_account_keys = []
    for _ in range(account_key_count):
        account_key, offset = _take(message_bytes, offset, 32, "account key")
        static_account_keys.append(account_key)

    _, offset = _take(message_bytes, offset, 32, "recent blockhash")
    instruction_count, offset = _skip_compiled_instructions(message_bytes, offset)

    lookup_count = 0
    if message_version == "v0":
        lookup_count, offset = _skip_address_table_lookups(message_bytes, offset)

    if offset != len(message_bytes):
        raise ParseError("trailing bytes remain after message parse")

    return {
        "message_version": message_version,
        "num_required_signatures": num_required_signatures,
        "num_readonly_signed": num_readonly_signed,
        "num_readonly_unsigned": num_readonly_unsigned,
        "static_account_keys": tuple(static_account_keys),
        "instruction_count": instruction_count,
        "lookup_count": lookup_count,
    }


def parse_transaction(transaction_bytes: bytes) -> ParsedTransaction:
    num_signatures, offset = decode_compact_u16(transaction_bytes, 0)

    signatures = []
    for _ in range(num_signatures):
        signature, offset = _take(transaction_bytes, offset, 64, "signature")
        signatures.append(signature)

    message_bytes = transaction_bytes[offset:]
    message_info = parse_message(message_bytes)
    static_account_keys = message_info["static_account_keys"]
    num_required_signatures = message_info["num_required_signatures"]

    if num_signatures != num_required_signatures:
        raise ParseError(
            "signature count does not match message header "
            f"({num_signatures} != {num_required_signatures})"
        )

    if len(static_account_keys) < num_required_signatures:
        raise ParseError("not enough static account keys for signer set")

    jobs = tuple(
        VerificationJob(index=index, pubkey=static_account_keys[index], signature=signatures[index])
        for index in range(num_required_signatures)
    )

    return ParsedTransaction(
        transaction_bytes=transaction_bytes,
        message_bytes=message_bytes,
        message_version=message_info["message_version"],
        num_required_signatures=num_required_signatures,
        jobs=jobs,
    )


def pack_batch_frame(parsed: ParsedTransaction) -> bytes:
    if not parsed.jobs:
        raise ValueError("batch must contain at least one verification job")
    if len(parsed.message_bytes) > 0xFFFF:
        raise ValueError("message is too large for the MVP frame")
    if len(parsed.jobs) > 0xFF:
        raise ValueError("too many verification jobs for the MVP frame")

    frame = bytearray()
    frame.extend(FRAME_MAGIC)
    frame.append(FRAME_VERSION)
    frame.append(0)
    frame.append(len(parsed.jobs))
    frame.append(0)
    frame.extend(struct.pack("<H", len(parsed.message_bytes)))
    frame.extend(b"\x00\x00")
    frame.extend(parsed.message_bytes)

    for job in parsed.jobs:
        frame.extend(job.pubkey)
        frame.extend(job.signature)

    frame.extend(struct.pack("<I", zlib.crc32(frame) & 0xFFFFFFFF))
    return bytes(frame)


def _load_blob(args: argparse.Namespace) -> bytes:
    if args.input_file:
        if args.input_file == "-":
            raw = sys.stdin.buffer.read() if args.encoding == "binary" else sys.stdin.read()
        else:
            path = Path(args.input_file)
            raw = path.read_bytes() if args.encoding == "binary" else path.read_text(encoding="utf-8")
    else:
        if args.input is None:
            raise SystemExit("either INPUT or --input-file must be provided")
        raw = args.input

    if args.encoding == "binary":
        if isinstance(raw, str):
            raise SystemExit("binary input requires --input-file or stdin")
        return raw

    text = raw.strip() if isinstance(raw, str) else raw.decode("utf-8").strip()
    if args.encoding == "base64":
        try:
            return base64.b64decode(text, validate=True)
        except binascii.Error as exc:
            raise ParseError(f"invalid base64 input: {exc}") from exc
    if args.encoding == "base58":
        return decode_base58(text)
    if args.encoding == "hex":
        try:
            return bytes.fromhex(text)
        except ValueError as exc:
            raise ParseError(f"invalid hex input: {exc}") from exc
    raise AssertionError(f"unexpected encoding: {args.encoding}")


def _write_output(path: str, payload: bytes) -> None:
    if path == "-":
        sys.stdout.buffer.write(payload)
        return
    Path(path).write_bytes(payload)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    def add_input_args(command: argparse.ArgumentParser) -> None:
        command.add_argument("input", nargs="?", help="serialized transaction in the selected encoding")
        command.add_argument(
            "--input-file",
            help="read transaction bytes from a file; use - to read from stdin",
        )
        command.add_argument(
            "--encoding",
            choices=("base64", "base58", "hex", "binary"),
            default="base64",
            help="encoding of the provided transaction blob",
        )

    extract = subparsers.add_parser("extract", help="extract Solana sigverify jobs from a serialized transaction")
    add_input_args(extract)

    frame = subparsers.add_parser("frame", help="emit a SIGV batch frame")
    add_input_args(frame)
    frame.add_argument(
        "-o",
        "--output-file",
        required=True,
        help="write the binary frame to this path, or - for stdout",
    )

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        transaction_bytes = _load_blob(args)
        parsed = parse_transaction(transaction_bytes)
    except ParseError as exc:
        parser.exit(2, f"error: {exc}\n")

    if args.command == "extract":
        print(json.dumps(parsed.to_summary(), indent=2))
        return 0

    frame_bytes = pack_batch_frame(parsed)
    _write_output(args.output_file, frame_bytes)
    if args.output_file != "-":
        print(
            json.dumps(
                {
                    "output_file": args.output_file,
                    "frame_size": len(frame_bytes),
                    "job_count": len(parsed.jobs),
                    "message_size": len(parsed.message_bytes),
                },
                indent=2,
            )
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
