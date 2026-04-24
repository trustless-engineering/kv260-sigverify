from __future__ import annotations

import base64
import json
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path


TOOLS_DIR = Path(__file__).resolve().parents[1]
SCRIPT_PATH = TOOLS_DIR / "solana_sigverify_mvp.py"
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import solana_sigverify_mvp as mvp  # noqa: E402


def shortvec(value: int) -> bytes:
    return mvp.encode_compact_u16(value)


def build_legacy_transaction() -> tuple[bytes, bytes, bytes, bytes]:
    signature = bytes([0xA5]) * 64
    signer = bytes(range(32))
    program = bytes(range(32, 64))
    blockhash = bytes([0x11]) * 32

    message = bytearray()
    message.extend(b"\x01\x00\x01")
    message.extend(shortvec(2))
    message.extend(signer)
    message.extend(program)
    message.extend(blockhash)
    message.extend(shortvec(1))
    message.extend(b"\x01")
    message.extend(shortvec(1))
    message.extend(b"\x00")
    message.extend(shortvec(2))
    message.extend(b"\xCA\xFE")

    transaction = shortvec(1) + signature + bytes(message)
    return transaction, bytes(message), signer, signature


def build_v0_transaction() -> tuple[bytes, bytes, bytes, bytes]:
    signature = bytes([0x5A]) * 64
    signer = bytes(range(64, 96))
    writable = bytes(range(96, 128))
    blockhash = bytes([0x22]) * 32

    message = bytearray()
    message.extend(b"\x80")
    message.extend(b"\x01\x00\x00")
    message.extend(shortvec(2))
    message.extend(signer)
    message.extend(writable)
    message.extend(blockhash)
    message.extend(shortvec(0))
    message.extend(shortvec(0))

    transaction = shortvec(1) + signature + bytes(message)
    return transaction, bytes(message), signer, signature


class ParseTransactionTests(unittest.TestCase):
    def test_extracts_legacy_verification_job(self) -> None:
        transaction, message, signer, signature = build_legacy_transaction()
        parsed = mvp.parse_transaction(transaction)

        self.assertEqual(parsed.message_version, "legacy")
        self.assertEqual(parsed.message_bytes, message)
        self.assertEqual(parsed.num_required_signatures, 1)
        self.assertEqual(len(parsed.jobs), 1)
        self.assertEqual(parsed.jobs[0].pubkey, signer)
        self.assertEqual(parsed.jobs[0].signature, signature)

    def test_extracts_v0_verification_job(self) -> None:
        transaction, message, signer, signature = build_v0_transaction()
        parsed = mvp.parse_transaction(transaction)

        self.assertEqual(parsed.message_version, "v0")
        self.assertEqual(parsed.message_bytes, message)
        self.assertEqual(parsed.num_required_signatures, 1)
        self.assertEqual(len(parsed.jobs), 1)
        self.assertEqual(parsed.jobs[0].pubkey, signer)
        self.assertEqual(parsed.jobs[0].signature, signature)

    def test_rejects_signature_count_mismatch(self) -> None:
        transaction, _, _, _ = build_legacy_transaction()
        tampered = bytearray(transaction)
        message_offset = 1 + 64
        tampered[message_offset] = 2

        with self.assertRaisesRegex(mvp.ParseError, "signature count does not match"):
            mvp.parse_transaction(bytes(tampered))


class FramePackingTests(unittest.TestCase):
    def test_packed_frame_matches_documented_layout(self) -> None:
        transaction, message, signer, signature = build_legacy_transaction()
        parsed = mvp.parse_transaction(transaction)
        frame = mvp.pack_batch_frame(parsed)

        self.assertEqual(frame[:4], b"SIGV")
        self.assertEqual(frame[4], 1)
        self.assertEqual(frame[6], 1)
        self.assertEqual(int.from_bytes(frame[8:10], "little"), len(message))
        self.assertEqual(frame[12 : 12 + len(message)], message)

        job_offset = 12 + len(message)
        self.assertEqual(frame[job_offset : job_offset + 32], signer)
        self.assertEqual(frame[job_offset + 32 : job_offset + 96], signature)

        expected_crc = zlib.crc32(frame[:-4]) & 0xFFFFFFFF
        actual_crc = int.from_bytes(frame[-4:], "little")
        self.assertEqual(actual_crc, expected_crc)


class CliTests(unittest.TestCase):
    def test_extract_cli_emits_summary_json(self) -> None:
        transaction, message, signer, signature = build_legacy_transaction()
        completed = subprocess.run(
            [
                sys.executable,
                str(SCRIPT_PATH),
                "extract",
                base64.b64encode(transaction).decode("ascii"),
            ],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        payload = json.loads(completed.stdout)
        self.assertEqual(payload["message_hex"], message.hex())
        self.assertEqual(payload["jobs"][0]["pubkey_hex"], signer.hex())
        self.assertEqual(payload["jobs"][0]["signature_hex"], signature.hex())

    def test_frame_cli_writes_binary_frame(self) -> None:
        transaction, _, _, _ = build_legacy_transaction()
        with tempfile.TemporaryDirectory() as tmpdir:
            output_path = Path(tmpdir) / "frame.bin"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    "frame",
                    base64.b64encode(transaction).decode("ascii"),
                    "--output-file",
                    str(output_path),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            frame = output_path.read_bytes()
            self.assertEqual(frame[:4], b"SIGV")

    def test_invalid_cli_input_returns_parse_error(self) -> None:
        completed = subprocess.run(
            [
                sys.executable,
                str(SCRIPT_PATH),
                "extract",
                "not-base64!!",
            ],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(completed.returncode, 2)
        self.assertIn("invalid base64 input", completed.stderr)


if __name__ == "__main__":
    unittest.main()
